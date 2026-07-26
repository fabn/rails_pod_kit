# frozen_string_literal: true

require 'rails_pod_kit/config'
require 'rails_pod_kit/exporter'

module RailsPodKit
  # Sidekiq integration. Called from inside `Sidekiq.configure_server`:
  #
  #   RailsPodKit::Sidekiq.install!(config)
  #
  # It:
  #   - requires yabeda-sidekiq (registers the server middleware + metrics),
  #   - applies the global-metrics policy (see Config#sidekiq_global_metrics),
  #   - starts the in-process Prometheus exporter (WEBrick) bound to the
  #     configured port so the worker pod serves /metrics itself.
  #
  # No-op when disabled or in the test env so specs never bind the port.
  module Sidekiq
    module_function

    def install!(sidekiq_config = nil)
      return unless RailsPodKit.enabled?

      require 'yabeda/sidekiq'
      require 'yabeda/prometheus/mmap'

      # Must run before Yabeda.configure! so the cluster-metric gauges are gated
      # correctly (they are only declared when the policy leaves them enabled).
      apply_global_metrics_policy!

      # We can't rely on yabeda's Railtie to call Yabeda.configure!: depending on
      # boot order it may never register. Drive it from Sidekiq's :startup
      # lifecycle event, which fires after every initializer (so the sidekiq
      # collector is registered) but before any job runs.
      install_configure_hook(sidekiq_config)

      start_metrics_server!
    end

    # Registers the Yabeda.configure! driver on Sidekiq's :startup event. The
    # real app always passes a Sidekiq config that responds to :on; when it
    # doesn't (e.g. unit specs that pass nil) we skip, so the global Yabeda
    # singleton isn't configured as a test side effect.
    def install_configure_hook(sidekiq_config)
      return unless sidekiq_config.respond_to?(:on)

      sidekiq_config.on(:startup) do
        require 'yabeda'
        Yabeda.configure! unless Yabeda.already_configured?
      end
    end

    # Decide whether this Sidekiq worker collects the global (Redis-wide) queue
    # metrics. Only the :all policy keeps every worker collecting them; under
    # :web they come from the web process instead, and under :off nobody does.
    # Either way per-process job metrics are unaffected.
    def apply_global_metrics_policy!
      collect = RailsPodKit.config.sidekiq_global_metrics == :all
      Yabeda::Sidekiq.config.collect_cluster_metrics = collect
      apply_retries_segmentation!
    end

    # Mirror the gem's `retries_segmented_by_queue` flag onto yabeda-sidekiq. Must
    # run before Yabeda.configure! so the retry gauge is declared with (or without)
    # the `queue` tag. Off by default — see RailsPodKit::Config.
    def apply_retries_segmentation!
      Yabeda::Sidekiq.config.retries_segmented_by_queue =
        RailsPodKit.config.retries_segmented_by_queue
    end

    # Enables global queue-metric collection in a process that is NOT a Sidekiq
    # server — i.e. the web (Puma) process under the :web policy. The web has the
    # Sidekiq client configured (Redis access), so yabeda-sidekiq can read the
    # cluster stats there. We force `collect_cluster_metrics` on and keep
    # `declare_process_metrics` off (the web runs no jobs). Must run before
    # Yabeda.configure! so the gauges are declared.
    def enable_global_collection!
      require 'yabeda/sidekiq'

      Yabeda::Sidekiq.config.collect_cluster_metrics = true
      Yabeda::Sidekiq.config.declare_process_metrics = false
      apply_retries_segmentation!
    end

    # Starts the background WEBrick exporter shared with the other non-Puma
    # entry points; guarded there so a re-entrant Sidekiq boot can't double-bind
    # the port.
    def start_metrics_server!
      RailsPodKit::Exporter.start!
    end
  end
end
