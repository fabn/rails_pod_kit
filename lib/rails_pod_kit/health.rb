# frozen_string_literal: true

require 'rails_pod_kit/config'

# health-monitor-rails subclasses ::Rails::Engine and its provider registry
# leans on ActiveSupport core extensions without requiring either itself;
# `rails` (railties' entry file, not the full framework) sets both up in the
# right order.
require 'rails'
require 'active_support/core_ext/string'
require 'rails/engine'
require 'health-monitor-rails'

module RailsPodKit
  # Opinionated health-monitor-rails configuration for a Rails pod's probe
  # endpoint. One call from an initializer:
  #
  #   RailsPodKit::Health.install!(
  #     redis:   { url: ENV['REDIS_URL'] },
  #     sidekiq: { queue_size: 200, latency: 10.minutes }
  #   )
  #
  # gives the app a /healthz endpoint checking database (health_monitor's
  # default), cache and (optionally) Redis and Sidekiq — suitable as a k8s startup
  # probe. For liveness/readiness, probe `/healthz?providers[]=none` to
  # short-circuit the dependency checks once the pod is live, so a transient
  # Redis hiccup doesn't restart the app. Same trick for a manual basic check:
  #
  #   curl '/healthz?providers[]=none' -H 'Accept: application/json'
  #
  # The Redis connection is injected by the host — the gem never reads
  # REDIS_URL or makes TLS decisions.
  module Health
    module_function

    # Configures HealthMonitor with the kit's defaults.
    #
    # redis:   optional Redis connection options hash (same shape the host
    #          passes to Sidekiq) or a ready connection object (Redis /
    #          ConnectionPool); when given the Redis provider is added. Omit
    #          entirely (or pass nil) on hosts with no Redis dependency to get
    #          a database + cache only endpoint.
    # path:    mount-relative endpoint path (default :healthz).
    # sidekiq: optional thresholds hash; when given the Sidekiq provider is
    #          added with the provided `queue_size:` / `latency:` overrides
    #          (health_monitor defaults apply for missing keys). Omit entirely
    #          on hosts without Sidekiq.
    # silence_controller_log: drop the per-probe INFO request logging (default
    #          true) — kubelet probes hit the endpoint every few seconds and
    #          would drown real request logs.
    # mount:   when true (default) the gem's Railtie mounts
    #          HealthMonitor::Engine at '/' automatically; pass false to keep
    #          route ownership and mount it yourself in config/routes.rb.
    #
    # Any further host-specific tuning (extra providers, error callback, …) can
    # be done in the block, which receives the HealthMonitor configuration.
    def install!(redis: nil, path: :healthz, sidekiq: nil, silence_controller_log: true, mount: true)
      @auto_mount = mount

      HealthMonitor.configure do |config|
        config.path = path
        config.cache

        if redis
          config.redis.configure do |redis_config|
            redis_config.connection = build_connection(redis)
          end
        end

        if sidekiq
          config.sidekiq.configure do |sidekiq_config|
            sidekiq_config.queue_size = sidekiq[:queue_size] if sidekiq[:queue_size]
            sidekiq_config.latency    = sidekiq[:latency]    if sidekiq[:latency]
          end
        end

        yield config if block_given?
      end

      silence_controller_log! if silence_controller_log
    end

    # Read by the Railtie's deferred routes block: true only once install! ran
    # (initializers run before the route set is drawn) and mount wasn't opted
    # out.
    def auto_mount?
      !!@auto_mount
    end

    def build_connection(redis)
      return redis unless redis.is_a?(Hash)

      require 'redis'
      ::Redis.new(**redis)
    end

    # Quiet the engine controller so kubelet probes don't emit an INFO line per
    # hit. Deferred to to_prepare because the engine controller is autoloaded.
    def silence_controller_log!
      return unless defined?(Rails.application) && Rails.application

      Rails.application.reloader.to_prepare do
        HealthMonitor::HealthController.logger.level = :warn
      end
    end
  end
end
