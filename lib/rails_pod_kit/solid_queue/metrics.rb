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
      # or after `Yabeda.configure!` (yabeda replays configurators either way),
      # and a no-op on a second call.
      def install!
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
      # Errors are reported and swallowed: this collector shares the endpoint
      # with the other groups, and letting a transient DB failure raise here
      # would fail the whole /metrics response — losing the Puma series too, in
      # the one process most likely to still be healthy.
      def collect!
        now = ::Time.now.utc
        with_connection { publish_all(claimable_by_queue(now), now) }
      rescue StandardError => e
        ErrorReporter.report(e, source: SOURCE)
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
        seen = (@seen_queues ||= [])
        (seen - current).each { |queue| publish(queue, backlog: 0, latency: 0) }
        @seen_queues = seen | current
      end

      def age_in_seconds(waiting_since, now)
        return 0 if waiting_since.nil?

        [(now - waiting_since).to_f, 0].max
      end

      # Test/reset hook — drops the published-label-set memo.
      def reset!
        @seen_queues = nil
        @installed = false
      end
    end
  end
end
