# frozen_string_literal: true

require 'rails_pod_kit/config'
require 'rails_pod_kit/error_reporter'

module RailsPodKit
  module SolidQueue
    # DB-backed queue gauges for SolidQueue, in the shape yabeda-sidekiq exposes
    # for Redis: SolidQueue ships no metrics endpoint and there is no
    # `yabeda-solid_queue`.
    #
    # Two series, both per `queue`, both computed at scrape time from a yabeda
    # `collect` block — no background thread, no cached snapshot:
    #
    #   solid_queue_backlog          how many jobs could be claimed right now
    #   solid_queue_latency_seconds  how long the oldest of them has been waiting
    #
    # "Claimable right now" is ready executions plus scheduled ones whose time
    # has come (the dispatcher has yet to move them across). Backlog alone misses
    # a small-but-stalled queue and latency alone misses a large-but-moving one,
    # so the pair is what dashboards, alerts and an HPA feed actually need.
    #
    # `::SolidQueue` is the host's — the gem declares no dependency on it and
    # nothing here loads until the host calls `install!`.
    module Metrics
      SOURCE = 'rails_pod_kit.solid_queue_metrics'

      module_function

      # Declares the gauges and registers the scrape-time collector. Safe before
      # or after `Yabeda.configure!` (yabeda replays configurators either way).
      #
      # `queues:` pins the zero baseline (see #baseline_queues) instead of
      # discovering it. `fail_scrape_on_error:` makes a collection failure fail
      # the whole response rather than serve the last reading — right when this
      # collector owns the endpoint, wrong when it shares one (see #collect!).
      #
      # Declaration is one-shot but the options are not: the dedicated pod boots
      # the host's initializers before `run_exporter!` runs, so by the time the
      # pod asks for `fail_scrape_on_error` the app's own `install_metrics!` has
      # normally already declared the gauges. An option given here always wins;
      # one left out keeps whatever an earlier call set.
      def install!(queues: nil, fail_scrape_on_error: nil)
        @baseline_queues = queues unless queues.nil?
        @fail_scrape_on_error = fail_scrape_on_error unless fail_scrape_on_error.nil?

        return false if @installed

        require 'yabeda'
        declare!
        @installed = true
      end

      def declare!
        Yabeda.configure do
          group :solid_queue do
            gauge :backlog,
                  tags: %i[queue],
                  comment: 'Jobs claimable right now: ready executions plus scheduled ones whose time has come'
            gauge :latency,
                  unit: :seconds,
                  tags: %i[queue],
                  comment: 'How long the oldest claimable job has been waiting'

            collect { RailsPodKit::SolidQueue::Metrics.collect! }
          end
        end
      end

      # Called by yabeda on every scrape.
      #
      # An error is always reported, and then either swallowed or re-raised
      # depending on who owns the endpoint. Swallowing keeps a transient DB
      # failure from taking the Puma series down with it on a shared endpoint —
      # at the cost of serving the last reading, which a consumer cannot tell
      # apart from a live one. On the dedicated pod (`run_exporter!`) there is
      # nothing else to protect, so failing the scrape is the honest answer: the
      # gauges go to no-data and the scraper's own `up` series carries the
      # failure.
      def collect!
        now = ::Time.now.utc
        with_connection { publish_all(claimable_by_queue(now), now) }
      rescue StandardError => e
        ErrorReporter.report(e, source: SOURCE)
        raise if @fail_scrape_on_error
      end

      # Collection runs on the exporter's HTTP thread, which would otherwise
      # check out a connection and pin it there for the life of the process.
      def with_connection(&)
        ::ActiveRecord::Base.connection_pool.with_connection(&)
      end

      # => { "default" => { backlog: 12, waiting_since: <Time> }, … }
      def claimable_by_queue(now)
        merge(ready_rows, due_rows(now))
      end

      def ready_rows
        rows(::SolidQueue::ReadyExecution.all, :created_at)
      end

      # A scheduled execution whose time has come is claimable too. Its wait
      # started at `scheduled_at`, not `created_at` — a job enqueued a week ahead
      # of its slot is not a week late.
      def due_rows(now)
        rows(::SolidQueue::ScheduledExecution.where(scheduled_at: ..now), :scheduled_at)
      end

      # Two grouped aggregates over an indexed, normally-small table. Both go
      # through ActiveRecord's calculations so the timestamp comes back
      # type-cast on every adapter.
      def rows(relation, waiting_since_column)
        counts = relation.group(:queue_name).count
        oldest = relation.group(:queue_name).minimum(waiting_since_column)

        counts.map { |queue, count| [queue, count, oldest[queue]] }
      end

      def merge(*row_sets)
        row_sets.flatten(1).each_with_object({}) do |(queue, count, waiting_since), acc|
          entry = acc[queue] ||= { backlog: 0, waiting_since: nil }
          entry[:backlog] += count
          entry[:waiting_since] = [entry[:waiting_since], waiting_since].compact.min
        end
      end

      def publish_all(queues, now)
        queues.each do |queue, entry|
          publish(queue, backlog: entry[:backlog], latency: age_in_seconds(entry[:waiting_since], now))
        end

        zero_drained_queues(queues.keys)
      end

      def publish(queue, backlog:, latency:)
        Yabeda.solid_queue.backlog.set({ queue: queue }, backlog)
        Yabeda.solid_queue.latency.set({ queue: queue }, latency)
      end

      # A gauge keeps its last value per label set, so a queue that just drained
      # would stay pinned at its final backlog forever — the exact reading that
      # would keep an alert firing on an idle system. Track the label sets this
      # process has published and zero the ones missing from this round.
      def zero_drained_queues(current)
        seen = seen_queues
        (seen - current).each { |queue| publish(queue, backlog: 0, latency: 0) }
        @seen_queues = seen | current
      end

      # Seeded with the baseline, so the zeroing above also covers queues this
      # process has never seen busy. A gauge only exists once it has been set:
      # without the seed an exporter that boots while the queue is empty — the
      # steady state of a scale-to-zero deployment — publishes no series at all,
      # and every consumer reads no-data where it should read 0.
      def seen_queues
        @seen_queues ||= baseline_queues
      end

      # The queues the app is known to use, pinned by the host or discovered
      # once per process from the jobs table (one index scan, never repeated).
      # Discovery is best-effort by construction: that table is bounded by
      # `clear_finished_jobs_after`, so a queue idle for longer than the
      # retention window leaves no trace. Pin `queues:` where the zero has to be
      # guaranteed.
      def baseline_queues
        @baseline_queues || ::SolidQueue::Job.distinct.pluck(:queue_name).compact
      end

      def age_in_seconds(waiting_since, now)
        return 0 if waiting_since.nil?

        [(now - waiting_since).to_f, 0].max
      end

      # Test/reset hook — drops the published-label-set memo and the install
      # options.
      def reset!
        @seen_queues = nil
        @baseline_queues = nil
        @fail_scrape_on_error = false
        @installed = false
      end
    end
  end
end
