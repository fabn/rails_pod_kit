# frozen_string_literal: true

require 'concurrent'

require 'rails_pod_kit/error_reporter'

module RailsPodKit
  # Keeps a background worker alive on a process that must not lose it.
  #
  # Both schedulers the gem hosts (SolidQueue's, and sidekiq-cron's) run on
  # their own thread inside an always-on process, and both share the same
  # failure mode: the thread dies, the host process notices nothing, and the
  # schedule stops silently. This is that supervision, once — a timer that
  # rebuilds the worker as soon as it stops being alive.
  #
  # The three things that genuinely differ between workers are injected: how to
  # build and start one, how to ask whether it is still alive, and how to wind
  # it down. Everything else — the immediate first tick, the stop latch that
  # keeps a shutdown from being undone by a tick already in flight, reporting
  # instead of dying — is identical and lives here.
  #
  # Deliberately free of Rails: the sidekiq-cron scheduler runs in a Rails-free
  # process, and ErrorReporter degrades to a warning where there is no Rails
  # error reporter to hand the failure to.
  class Supervisor
    DEFAULT_INTERVAL = 30

    attr_reader :subject

    # `start:` is a callable returning the started worker. `alive:` and `stop:`
    # take either a method name to send to that worker or a callable receiving
    # it, so the common case stays declarative and a liveness check the worker
    # does not expose itself is still expressible. `stop:` is optional — a
    # worker with no teardown is simply dropped.
    def initialize(source:, start:, alive:, stop: nil, interval: DEFAULT_INTERVAL)
      @source = source
      @start = start
      @alive = alive
      @stop = stop
      @interval = interval
      @stopping = false
    end

    # Starts the timer, which starts the worker on its first (immediate) tick,
    # and returns without blocking.
    def start
      @stopping = false
      @timer = ::Concurrent::TimerTask.new(execution_interval: @interval, run_now: true) { supervise }
      @timer.execute
      self
    end

    # Graceful stop: drop the timer first so it cannot resurrect the worker,
    # then wind the worker down rather than leaving it to be cut off.
    def stop
      @stopping = true
      @timer&.shutdown
      @timer = nil
      invoke(@stop, @subject) if @subject && @stop
      @subject = nil
    end

    def running?
      !!@subject && invoke(@alive, @subject)
    end

    private

    def invoke(hook, worker)
      hook.is_a?(::Symbol) ? worker.public_send(hook) : hook.call(worker)
    end

    # Concurrent::TimerTask silently drops a raising block, so report here and
    # let the next tick retry — a worker that cannot start because its backing
    # store is down must keep trying.
    def supervise
      ensure_running
    rescue StandardError => e
      ErrorReporter.report(e, source: @source)
    end

    # Idempotent: starts the worker on the first tick, and replaces it only once
    # it has actually stopped being alive.
    def ensure_running
      return if @stopping || running?

      @subject = @start.call
    end
  end
end
