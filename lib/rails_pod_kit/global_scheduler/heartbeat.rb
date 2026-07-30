# frozen_string_literal: true

module RailsPodKit
  module GlobalScheduler
    # The one failure the rest of the machinery cannot see.
    #
    # A poller thread that dies is restarted by the Supervisor, and a process
    # that stops serving is caught by the exporter's own probe. But a poller
    # that is *running and no longer enqueueing* is indistinguishable from an
    # idle one from the outside: every gauge stays fresh, /metrics answers 200,
    # the pod is Running and Ready. On the only process carrying the schedule
    # that is a silently stopped schedule — exactly the failure hosting the
    # poller here was meant to eliminate, coming back through another door.
    #
    # So publish the age of the last completed tick, as
    # `sidekiq_cron_poll_age_seconds`. It measures the loop turning, which means
    # it stays flat on a healthy but idle schedule and climbs the moment ticks
    # stop — the one shape an alert can be written against.
    #
    # Deliberately *not* "time since last enqueue": that climbs on any quiet
    # schedule, so it would alert on nothing happening. Answering "should this
    # job have run by now?" needs a per-job check against the cron expression,
    # not a gauge.
    module Heartbeat
      module_function

      # Declares the gauge. One-shot, and safe either side of
      # `Yabeda.configure!` — a metric declared after it is registered with the
      # adapters immediately.
      def install!
        return false if @installed

        require 'yabeda'
        declare!
        @installed = true
      end

      def declare!
        Yabeda.configure do
          group :sidekiq do
            gauge :cron_poll_age,
                  unit: :seconds,
                  tags: [],
                  aggregation: :most_recent,
                  comment: 'Seconds since the sidekiq-cron poller last completed a tick'

            collect do
              age = RailsPodKit::GlobalScheduler::Heartbeat.age
              Yabeda.sidekiq.cron_poll_age.set({}, age) if age
            end
          end
        end
      end

      # Begins measuring, from before the first tick — so a poller that never
      # manages one reads as climbing rather than as no-data.
      def start!
        @started_at = monotonic_now
        @last_poll_at = nil
      end

      # Drops the series with the poller: a stopped scheduler should read as
      # no-data, not as an age climbing forever.
      def stop!
        @started_at = nil
        @last_poll_at = nil
      end

      def record!
        @last_poll_at = monotonic_now
      end

      # nil until started, which is what keeps the series off any process that
      # hosts no poller.
      def age
        reference = @last_poll_at || @started_at
        return nil unless reference

        monotonic_now - reference
      end

      # Monotonic: this is a duration, and a wall-clock step (NTP, a node coming
      # back from suspend) must not read as the schedule having stalled.
      def monotonic_now
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
