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
      # mmap adapter is registered. The gem's main entry (lib/rails_pod_kit.rb)
      # already loaded it at Bundler.require, so this is normally a no-op — it
      # matters only under `puma -C config/puma.rb`, where config/puma.rb runs
      # before Rails and thus before the main entry, so this is the first require.
      require 'yabeda/prometheus/mmap'

      # The control app exposes Puma's /stats over a localhost-only socket that
      # the yabeda collector queries. `no_token: true` is safe because the
      # socket is never exposed outside the pod.
      puma_config.activate_control_app(RailsPodKit.config.puma_control_url, no_token: true)

      puma_config.plugin :yabeda
      puma_config.plugin :yabeda_prometheus

      # Drop the exporter's per-scrape access log the same way the WEBrick path
      # does (see RailsPodKit::Exporter.start!): the log line comes from the
      # Rack::CommonLogger the exporter's rack app mounts unless this is exactly
      # 'false'. See Config#silence_exporter_access_log.
      #
      # Deliberately not `prometheus_silence_logger(true)`, which is the plugin's
      # own knob: it swaps Puma's whole log writer for LogWriter.null, and that
      # writer also carries the exporter's errors — so a /metrics that raises on
      # every scrape would fail completely silently.
      ENV['PROMETHEUS_EXPORTER_LOG_REQUESTS'] = 'false' if RailsPodKit.config.silence_exporter_access_log

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
