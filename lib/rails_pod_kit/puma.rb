# frozen_string_literal: true

require 'rails_pod_kit/config'

module RailsPodKit
  # Puma integration. Encapsulates the Puma plugins the yabeda stack needs so
  # that `config/puma.rb` stays a one-liner:
  #
  #   require 'rails_pod_kit/puma'
  #   RailsPodKit::Puma.activate(self)
  #
  # - control app             yabeda-puma-plugin reads the Puma thread-pool
  #                           stats through Puma's control app, so we activate
  #                           one (localhost-only, no token) if the app hasn't.
  # - `plugin :yabeda`        (yabeda-puma-plugin) registers a Yabeda collector
  #                           for Puma thread-pool / worker stats.
  # - `plugin :yabeda_prometheus` (yabeda-puma-plugin) starts the in-process
  #                           HTTP server that serves /metrics, fork-safe under
  #                           `preload_app!` + clustered workers.
  #
  # No-op when disabled or in the test env so the suite never binds the port.
  module Puma
    module_function

    def activate(puma_config)
      return unless RailsPodKit.enabled?

      ENV['PROMETHEUS_EXPORTER_PORT'] ||= RailsPodKit.config.port.to_s

      # The Puma plugin only pulls in the exporter class; we must also load the
      # full mmap module so `Yabeda::Prometheus::Mmap.registry` exists and the
      # mmap adapter is registered (it's a transitive dep, so Bundler.require in
      # the host app doesn't auto-require it).
      require 'yabeda/prometheus/mmap'

      # The control app exposes Puma's /stats over a localhost-only socket that
      # the yabeda collector queries. `no_token: true` is safe because the
      # socket is never exposed outside the pod.
      puma_config.activate_control_app(RailsPodKit.config.puma_control_url, no_token: true)

      puma_config.plugin :yabeda
      puma_config.plugin :yabeda_prometheus

      # Silence the exporter's per-scrape access log. The `prometheus_silence_logger`
      # DSL method is defined by the :yabeda_prometheus plugin, so this must run
      # after the plugin is loaded above. See Config#silence_exporter_access_log.
      puma_config.prometheus_silence_logger(true) if RailsPodKit.config.silence_exporter_access_log

      # `config/puma.rb` is evaluated before Rails is loaded, so requiring this
      # gem here loads yabeda *before* `defined?(Rails)`, and yabeda's Railtie
      # (which would call `Yabeda.configure!` at after_initialize) never
      # registers. So we drive configuration ourselves from the exporter-boot
      # hook, which runs after Rails has booted and after the Puma plugin has
      # registered its collector.
      puma_config.on_prometheus_exporter_boot do
        # Under the :web policy the always-on web process is the single source of
        # Sidekiq global (Redis-wide) queue metrics, so workers don't duplicate
        # them. Done here (not in activate) because requiring yabeda-sidekiq —
        # which pulls in Sidekiq — before Rails boots corrupts Sidekiq's
        # ActiveJob adapter load order. By exporter-boot, Rails has loaded
        # Sidekiq properly and the web's Sidekiq client (Redis) is configured.
        if RailsPodKit.config.sidekiq_global_metrics == :web
          require 'rails_pod_kit/sidekiq'
          RailsPodKit::Sidekiq.enable_global_collection!
        end

        require 'yabeda'
        Yabeda.configure! unless Yabeda.already_configured?
      end
    end
  end
end
