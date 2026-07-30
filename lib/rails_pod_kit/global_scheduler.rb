# frozen_string_literal: true

require 'concurrent'

require 'rails_pod_kit/config'
require 'rails_pod_kit/error_reporter'

module RailsPodKit
  # Runs the sidekiq-cron poller in a process that is *not* a Sidekiq server, so
  # a Sidekiq deployment can be autoscaled to zero without losing its schedule.
  #
  # sidekiq-cron installs its poller from inside `Sidekiq.configure_server`, so
  # the schedule exists only while a Sidekiq server is alive. At zero replicas
  # nothing polls, nothing is enqueued, and nothing ever raises the queue depth
  # that would wake a worker back up — a closed loop that forces a permanent
  # floor of one replica just to keep a poller alive. Recurring jobs are not
  # caught up afterwards either: `reschedule_grace_period` (60s by default)
  # discards any run older than itself, so a worker started later skips it.
  #
  # The poller has no such requirement of its own. `Sidekiq::Cron::Poller` is a
  # Redis-polling thread and runs in any process holding a Sidekiq config, so
  # hosting it on an always-on singleton — the dedicated exporter pod, see
  # GlobalExporter — breaks the cycle and leaves the workers free to scale to
  # zero.
  #
  # Deliberately Rails-free, like the exporter it sits beside: enqueueing does
  # not need the job classes. When `Job#enqueue!` cannot resolve the class it
  # pushes a plain Sidekiq message naming the ActiveJob wrapper with the job
  # class as a *string*, and the worker — which does have Rails — resolves it.
  # That fallback is only correct for entries declaring `active_job: true`, so
  # `start!` warns about any that would instead be pushed as bare Sidekiq jobs.
  #
  # The poller runs under a `Concurrent::TimerTask` supervisor. Its own loop
  # swallows StandardError (`Poller#enqueue` and `#wait` both do), so a Redis
  # blip costs one skipped tick — but anything it does not catch takes the
  # thread down and, since this process is the only scheduler, the schedule with
  # it, silently. The supervisor turns that into a skipped tick too.
  module GlobalScheduler
    # How often we check that the poller thread is still alive.
    DEFAULT_SUPERVISION_INTERVAL = 30

    SOURCE = 'rails_pod_kit.global_scheduler'

    module_function

    # Loads the schedule and starts the supervisor, which starts the poller on
    # its first (immediate) tick, then returns without blocking. Idempotent: a
    # second call is a no-op rather than a second poller in the same process.
    #
    # `schedule_file:` and `poll_interval:` override sidekiq-cron's own defaults
    # (`config/schedule.yml`, resolved against the working directory, polled
    # every 30s).
    def start!(schedule_file: nil, poll_interval: nil, supervision_interval: DEFAULT_SUPERVISION_INTERVAL)
      return @supervisor if @supervisor

      require 'sidekiq'
      require 'sidekiq-cron'
      # sidekiq-cron renders the schedule file through ERB without requiring it:
      # under Rails it is always already loaded, here it is not.
      require 'erb'

      configure!(schedule_file: schedule_file, poll_interval: poll_interval)
      load_schedule!

      @stopping = false
      @supervisor = ::Concurrent::TimerTask.new(execution_interval: supervision_interval, run_now: true) { supervise }
      @supervisor.execute
      @supervisor
    end

    # Graceful stop: drop the supervisor first so it can't resurrect the poller,
    # then let an in-flight tick finish instead of being cut off mid-enqueue.
    def stop!
      @stopping = true
      @supervisor&.shutdown
      @supervisor = nil
      @poller&.terminate
      @poller = nil
    end

    def poller
      @poller
    end

    # Concurrent::TimerTask silently drops a raising block, so report here and
    # let the next tick retry.
    def supervise
      ensure_poller_running
    rescue StandardError => e
      ErrorReporter.report(e, source: SOURCE)
    end

    def ensure_poller_running
      return if @stopping || poller_alive?

      @poller = build_poller
      @poller.start
    end

    # `Sidekiq::Scheduled::Poller` keeps its thread in `@thread` and `start` is a
    # no-op once that is set, so there is no public way to ask whether the poller
    # is still running, nor to revive it. Reading the ivar lets the supervisor
    # replace a dead poller wholesale — schedule state lives in Redis, so a fresh
    # one picks up exactly where the old one stopped. An unrecognised shape reads
    # as alive, so an upstream rename costs the supervision, never a restart loop.
    def poller_alive?
      return false unless @poller
      return true unless @poller.instance_variable_defined?(:@thread)

      !!@poller.instance_variable_get(:@thread)&.alive?
    end

    def configure!(schedule_file: nil, poll_interval: nil)
      ::Sidekiq::Cron.configure do |cron|
        cron.cron_schedule_file = schedule_file if schedule_file
        cron.cron_poll_interval = poll_interval if poll_interval
      end
    end

    # sidekiq-cron reads the schedule file from a Sidekiq server's `:startup`
    # lifecycle event, which never fires here, so load it explicitly.
    def load_schedule!
      return unless ::Sidekiq::Cron.configuration.enabled

      loader = ::Sidekiq::Cron::ScheduleLoader.new
      return unless loader.has_schedule_file?

      loader.load_schedule
      warn_unresolvable_entries!
    end

    # sidekiq-cron's own Launcher publishes these two into the Sidekiq config
    # before instantiating the poller, which reads them straight back out.
    # Pinning the process count keeps the poll interval at the configured value:
    # the inherited default counts *live Sidekiq servers*, which here is a count
    # of anything but cron pollers — and is zero while the workers are scaled in.
    def build_poller
      config = ::Sidekiq.default_configuration
      config[:cron_poll_interval] = ::Sidekiq::Cron.configuration.cron_poll_interval.to_i
      config[:cron_poll_process_count] = ::Sidekiq::Cron.configuration.cron_poll_process_count || 1

      ::Sidekiq::Cron::Poller.new(config)
    end

    # An entry whose class this process cannot load and which does not declare
    # `active_job: true` is pushed as a bare Sidekiq job message, so the worker
    # runs `perform` outside ActiveJob — no callbacks, no argument
    # deserialization, no retry bookkeeping.
    def warn_unresolvable_entries!
      names = ::Sidekiq::Cron::Job.all('*').reject { |job| enqueueable_without_class?(job) }.map(&:name)
      return if names.empty?

      ::Sidekiq.logger.warn do
        "[rails_pod_kit] cron entries #{names.join(', ')} name a class this Rails-free process cannot load and " \
          'are not marked `active_job: true`; they would be enqueued as plain Sidekiq jobs.'
      end
    end

    def enqueueable_without_class?(job)
      job.to_hash[:active_job] == '1' || !::Sidekiq::Cron::Support.safe_constantize(job.klass.to_s).nil?
    end
  end
end
