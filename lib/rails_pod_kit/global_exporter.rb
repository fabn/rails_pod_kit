# frozen_string_literal: true

require 'rails_pod_kit/config'

module RailsPodKit
  # Standalone, always-on exporter for the Sidekiq global (Redis-wide) queue
  # metrics (queue latency, jobs waiting, scheduled/retry/dead counts, …).
  #
  # Runs as its own 1-replica Deployment so those series come from a single
  # source, fully decoupled from web/worker autoscaling: KEDA can scale the web
  # and worker pods (even to zero) without the queue metrics disappearing or
  # being duplicated per pod. It is NOT a Sidekiq server and serves no web
  # traffic — it just reads the cluster stats from Redis and exposes them on the
  # exporter port.
  #
  # Deliberately Rails-free. The whole job is reading a handful of counters from
  # Redis, so booting the host app (every gem, every initializer) just to
  # inherit the connection config would cost hundreds of Mi RSS for nothing.
  # Instead the host injects its Redis options into `run!`, which configures the
  # Sidekiq client itself — the process sits at ~60Mi.
  #
  # Entry point: a thin, host-owned executable (the gem ships none, so the host
  # keeps full ownership of its connection config), e.g. `bin/pod-exporter`:
  #
  #   #!/usr/bin/env ruby
  #   require 'bundler/setup'
  #   require 'rails_pod_kit/global_exporter'
  #   RailsPodKit::GlobalExporter.run!(redis: { url: ENV['REDIS_URL'] })
  module GlobalExporter
    module_function

    # Force-enable cluster collection so yabeda declares the global gauges when
    # it configures. Force-on regardless of the host's `sidekiq_global_metrics`
    # policy — collecting them is this process's whole job; the web/worker pods
    # stay :off so they don't duplicate it.
    def install!
      require 'rails_pod_kit/sidekiq'
      require 'yabeda/prometheus/mmap'
      RailsPodKit::Sidekiq.enable_global_collection!
    end

    # Boots the exporter and blocks. Self-sufficient: no Rails environment is
    # required — it wires the Sidekiq client's Redis connection from the
    # host-injected options, declares and configures the gauges, starts the
    # metrics server, then sleeps.
    #
    # `redis:` takes the same options hash the host passes to its own
    # `Sidekiq.configure_*` blocks (`url:`, `ssl_params:`, …), so the connection
    # config stays a host decision with a single source of truth.
    def run!(redis:)
      unless RailsPodKit.enabled?
        warn '[rails_pod_kit] disabled — global exporter not started'
        return
      end

      configure_redis!(redis)
      install!
      RailsPodKit::Sidekiq.start_metrics_server!

      require 'yabeda'
      Yabeda.configure! unless Yabeda.already_configured?

      # The exporter serves from a background thread; block the main thread so
      # the process stays up until the kubelet sends SIGTERM.
      sleep
    end

    # Configure the Sidekiq client's Redis connection so this Rails-free process
    # can read the cluster stats.
    def configure_redis!(redis_options)
      require 'sidekiq'
      ::Sidekiq.configure_client do |config|
        config.redis = redis_options
      end
    end
  end
end
