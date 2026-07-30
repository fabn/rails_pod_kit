# frozen_string_literal: true

require 'active_support/configuration_file'
require 'active_support/core_ext/hash/keys'

require 'rails_pod_kit/config'
require 'rails_pod_kit/supervisor'

module RailsPodKit
  module SolidQueue
    # Runs a SolidQueue *scheduler* — and only the scheduler — as a supervised
    # background thread, so the process running jobs can scale to zero.
    #
    # Scaling the executor to zero is otherwise a chicken-and-egg problem: with
    # no executor there is no scheduler, so nothing enqueues the recurring or
    # scheduled jobs that would wake one. A k8s CronJob can't take over either,
    # because it can't own *dynamic* recurring tasks (created and updated at
    # runtime through `SolidQueue.schedule_recurring_task`). Moving just the
    # scheduler onto an always-on process — the web, or the exporter pod —
    # breaks the cycle: it keeps evaluating the crons and enqueueing, and the
    # queue depth wakes the executor.
    #
    # Deliberately *not* the full supervisor (`plugin :solid_queue`): that one
    # forks, and its Puma watchdog takes the host process down when the
    # supervisor exits — which a transient Postgres disconnect is enough to
    # cause (rails/solid_queue#512). Here a DB blip at worst kills the scheduler
    # thread; the supervising timer notices on its next tick and starts a fresh
    # one, and the host process never notices.
    #
    # Running it on every replica is safe: enqueues stay exactly-once via the
    # unique index on `solid_queue_recurring_executions (task_key, run_at)`.
    class SchedulerRunner
      # How often the scheduler re-reads the dynamic tasks from the DB.
      DEFAULT_POLLING_INTERVAL = 5
      # How often we check that the scheduler thread is still alive.
      DEFAULT_SUPERVISION_INTERVAL = 5

      SOURCE = 'rails_pod_kit.solid_queue_scheduler'

      def initialize(polling_interval: DEFAULT_POLLING_INTERVAL,
                     supervision_interval: DEFAULT_SUPERVISION_INTERVAL,
                     recurring_schedule_file: nil)
        @polling_interval = polling_interval
        @supervision_interval = supervision_interval
        @recurring_schedule_file = recurring_schedule_file
      end

      # Starts the supervisor, which starts the scheduler on its first (immediate)
      # tick and returns without blocking.
      def start
        @supervisor = build_supervisor.start
        self
      end

      # Graceful stop: the supervisor drops its timer before winding the
      # scheduler down (unschedule its timers and deregister the process,
      # instead of leaving a row to expire).
      def stop
        @supervisor&.stop
        @supervisor = nil
      end

      def running?
        !!@supervisor&.running?
      end

      private

      def build_supervisor
        Supervisor.new(
          source: SOURCE,
          interval: @supervision_interval,
          start: -> { build_scheduler },
          alive: :alive?,
          stop: :stop
        )
      end

      def build_scheduler
        scheduler = ::SolidQueue::Scheduler.new(
          recurring_tasks: static_recurring_tasks,
          dynamic_tasks_enabled: true,
          polling_interval: @polling_interval
        )
        scheduler.mode = :async
        scheduler.start # spawns the scheduler's own thread and returns
        scheduler
      end

      # The static tasks from config/recurring.yml; the dynamic ones come from
      # the DB via `dynamic_tasks_enabled`. `SolidQueue::Configuration#recurring_tasks`
      # is private, so parse the file with the same public helper it uses.
      def static_recurring_tasks
        path = recurring_schedule_file
        return [] unless path && ::File.exist?(path)

        config = ::ActiveSupport::ConfigurationFile.parse(path).deep_symbolize_keys
        config.fetch(environment.to_sym, {}).filter_map do |key, options|
          ::SolidQueue::RecurringTask.from_configuration(key, **options) if options&.key?(:schedule)
        end
      end

      # Same resolution order SolidQueue's own CLI uses.
      def recurring_schedule_file
        return @recurring_schedule_file if @recurring_schedule_file
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root

        ::Rails.root.join(ENV.fetch('SOLID_QUEUE_RECURRING_SCHEDULE', 'config/recurring.yml'))
      end

      def environment
        return ::Rails.env if defined?(::Rails) && ::Rails.respond_to?(:env)

        ENV.fetch('RAILS_ENV', 'development')
      end
    end
  end
end
