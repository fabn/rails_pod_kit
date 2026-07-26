# frozen_string_literal: true

require 'rails_pod_kit/config'

module RailsPodKit
  # The in-process WEBrick /metrics server, shared by every non-Puma entry
  # point: the Sidekiq worker, the Rails-free global exporter and the SolidQueue
  # exporter. Under Puma the exporter comes from the `:yabeda_prometheus` plugin
  # instead (see RailsPodKit::Puma), so this is never used there.
  module Exporter
    module_function

    # Starts the background exporter and returns whether it did. Idempotent: the
    # latch keeps a re-entrant boot from double-binding the port.
    def start!
      return false unless RailsPodKit.enabled?
      return false if @started

      require 'yabeda/prometheus/mmap'

      # `start_metrics_server!` reads the bind port from the env, so publish the
      # configured one first.
      ENV['PROMETHEUS_EXPORTER_PORT'] ||= RailsPodKit.config.port.to_s
      # Drop the exporter's per-scrape access log (Rack::CommonLogger, which the
      # mmap exporter mounts unless this is exactly 'false'). See
      # Config#silence_exporter_access_log.
      ENV['PROMETHEUS_EXPORTER_LOG_REQUESTS'] = 'false' if RailsPodKit.config.silence_exporter_access_log

      Yabeda::Prometheus::Exporter.start_metrics_server!
      @started = true
    end

    def started?
      !!@started
    end

    # Test/reset hook — drops the "already started" latch.
    def reset!
      @started = false
    end
  end
end
