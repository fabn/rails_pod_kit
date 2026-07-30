# frozen_string_literal: true

require 'anyway_config'

require 'rails_pod_kit/version'

# Configuration core, shared by every entry point. The sub-entry points
# (rails_pod_kit/puma, rails_pod_kit/global_exporter, …) require this file —
# not the gem's main file — so they can run in Rails-free processes without
# pulling in railties.
module RailsPodKit
  class Error < StandardError; end

  DEFAULT_PORT = 9394

  # Backed by anyway_config: every attribute can also come from RAILS_POD_KIT_*
  # env vars or an optional config/rails_pod_kit.yml in the host, with the
  # `RailsPodKit.configure` block (running last, from an initializer) winning
  # over both. A single instance is memoized on the module.
  class Config < Anyway::Config
    config_name :rails_pod_kit
    env_prefix 'RAILS_POD_KIT'

    # enabled: master switch — when false the gem is a complete no-op: no
    #   exporter server is started and no port is bound. Defaults to off in the
    #   `test` environment so specs and CI never try to bind port 9394.
    #
    # port: TCP port the in-process exporter binds for both Puma and Sidekiq.
    #   Defaults to PROMETHEUS_EXPORTER_PORT (the yabeda-native env var) or 9394.
    #
    # sidekiq_global_metrics: policy for Sidekiq global (Redis-wide) queue
    #   metrics — queue latency, jobs waiting, etc. These are read from Redis
    #   and are identical across processes, so exporting them from every worker
    #   just duplicates series downstream.
    #     :web (default) -> collect them only in the always-on web (Puma)
    #                       process; workers export only their per-process job
    #                       metrics. One source, no per-worker duplication.
    #     :all           -> every worker pod exports them (legacy). Aggregate
    #                       with `max ... by {queue}` downstream, never `sum`.
    #     :off           -> nobody collects them (per-process metrics
    #                       unaffected). Pair with the dedicated global exporter
    #                       (GlobalExporter) so the gauges still come from
    #                       somewhere — exactly once.
    #
    # puma_control_url: Puma control-app URL. yabeda-puma-plugin reads the Puma
    #   thread-pool stats through the control app, so `Puma.activate` makes sure
    #   one is running. Defaults to PUMA_CONTROL_URL or a localhost-only TCP
    #   socket (not network-exposed in the pod).
    #
    # retries_segmented_by_queue: when true, the Sidekiq global retry gauge
    #   (`sidekiq_jobs_retry_count`) is broken down with a `queue` tag instead
    #   of a single global scalar. Maps to yabeda-sidekiq's setting of the same
    #   name. Off by default: per-queue retries multiply series cardinality, and
    #   the global scalar is enough for a failing-jobs anomaly monitor.
    #
    # silence_exporter_access_log: when true (default), the in-process /metrics
    #   exporter emits NO access log line per scrape. The endpoint is
    #   pod-internal and scraped on a fixed interval by the metrics agent, so a
    #   `GET /metrics` line per scrape per pod is pure noise. Silenced at both
    #   transports — the Puma plugin's exporter (`prometheus_silence_logger`)
    #   and the WEBrick exporter used by Sidekiq / the dedicated global exporter
    #   (`Rack::CommonLogger`). Flip to false only to debug the exporter itself.
    # scheduler_enabled: kill switch for the hosted schedulers (the sidekiq-cron
    #   poller and the SolidQueue scheduler thread). Separate from `enabled`,
    #   which owns the metrics exporter: an app may well want one without the
    #   other, and the scheduler is the piece you may need to turn off in a
    #   hurry — it is a single point of failure for the whole schedule, and
    #   `RAILS_POD_KIT_SCHEDULER_ENABLED=false` + a restart beats a deploy at
    #   3am. Defaults to on *including* in the test env, unlike `enabled`:
    #   nothing starts a scheduler implicitly (it takes an explicit call from an
    #   entry point), so there is no port to protect, and a flag that fails
    #   closed on a typo would silently stop a schedule.
    attr_config :enabled,
                :port,
                :puma_control_url,
                sidekiq_global_metrics: :web,
                retries_segmented_by_queue: false,
                silence_exporter_access_log: true,
                scheduler_enabled: true

    coerce_types port: :integer,
                 enabled: :boolean,
                 retries_segmented_by_queue: :boolean,
                 silence_exporter_access_log: :boolean,
                 scheduler_enabled: :boolean

    def initialize(overrides = nil)
      super

      # Env/YAML sources deliver the policy as a string; the API is symbols.
      self.sidekiq_global_metrics = sidekiq_global_metrics.to_sym if sidekiq_global_metrics
      # Dynamic defaults anyway_config can't express statically.
      self.enabled = self.class.default_enabled? if enabled.nil?
      self.port ||= Integer(ENV.fetch('PROMETHEUS_EXPORTER_PORT', DEFAULT_PORT))
      self.puma_control_url ||= ENV.fetch('PUMA_CONTROL_URL', 'tcp://127.0.0.1:9293')
    end

    def enabled?
      !!enabled
    end

    def scheduler_enabled?
      !!scheduler_enabled
    end

    # True unless we're clearly in a test environment. Kept independent of
    # Rails so the gem's own specs (which don't load the host app) get a safe
    # default and never bind a socket.
    def self.default_enabled?
      env = ENV['RAILS_ENV'] || ENV['RACK_ENV']
      env != 'test'
    end
  end

  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield config if block_given?
      config
    end

    # Test/reset hook — drops the memoized config so a fresh one is built.
    def reset_config!
      @config = nil
    end

    def enabled?
      config.enabled?
    end

    # Gate shared by both hosted schedulers. Says so out loud when it turns one
    # off: a process that starts, stays up and quietly schedules nothing is the
    # one failure this whole feature exists to avoid.
    def scheduler_enabled?(what = 'scheduler')
      return true if config.scheduler_enabled?

      warn "[rails_pod_kit] scheduler_enabled=false — #{what} not started"
      false
    end
  end
end
