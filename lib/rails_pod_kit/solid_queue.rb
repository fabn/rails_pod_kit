# frozen_string_literal: true

require 'rails_pod_kit/config'
require 'rails_pod_kit/exporter'
require 'rails_pod_kit/solid_queue/metrics'
require 'rails_pod_kit/solid_queue/scheduler_runner'

module RailsPodKit
  # SolidQueue integration — the pieces a Rails 8 app needs to run its job
  # executor with scale-to-zero autoscaling (KEDA/HPA). All three are opt-in;
  # requiring this file only defines them.
  #
  #   install_metrics!    the `solid_queue_backlog` / `solid_queue_latency_seconds`
  #                       gauges on /metrics (see Metrics)
  #   start_scheduler!    the SolidQueue scheduler as a supervised background
  #                       thread on an always-on process (see SchedulerRunner)
  #   run_exporter!       both of the above in a dedicated always-on pod, with
  #                       the /metrics server, blocking until SIGTERM
  #
  # Nothing here loads `solid_queue` itself: it is the host's dependency, the
  # same way Puma and Sidekiq are.
  #
  # Wiring the two halves separately, when the always-on process is the web:
  #
  #   # config/initializers/rails_pod_kit.rb
  #   RailsPodKit::SolidQueue.install_metrics!
  #
  #   # config/puma.rb — after_booted only runs in the real Puma process,
  #   # never in a console, a rake task or the test suite.
  #   after_booted { RailsPodKit::SolidQueue.start_scheduler! }
  #   at_exit      { RailsPodKit::SolidQueue.stop_scheduler! }
  module SolidQueue
    module_function

    # Declares the queue gauges. Call from an initializer, in whichever process
    # should publish them — see the README on keeping one source per series.
    #
    # Options are Metrics.install!'s: `queues:` to pin the zero baseline,
    # `fail_scrape_on_error:` to fail the scrape instead of serving the last
    # reading when the DB is unreachable (the default only holds on an endpoint
    # this collector shares with another group).
    def install_metrics!(**)
      Metrics.install!(**)
    end

    # Starts the supervised scheduler thread and returns the runner. Idempotent:
    # a second call returns the running one rather than starting a second
    # scheduler in the same process.
    #
    # Not gated on `RailsPodKit.enabled?` — that switch owns the metrics
    # exporter, and an app may well want the scheduler with metrics turned off.
    # The guard against starting one in a console or in specs is *where* you
    # call this from (`after_booted`, or the exporter entrypoint).
    def start_scheduler!(**)
      return scheduler_runner if scheduler_runner

      @scheduler_runner = SchedulerRunner.new(**).start
    end

    def stop_scheduler!
      @scheduler_runner&.stop
      @scheduler_runner = nil
    end

    def scheduler_runner
      @scheduler_runner
    end

    # Runs the dedicated always-on SolidQueue pod and blocks until SIGTERM:
    # the queue gauges, the scheduler thread and the /metrics server in one
    # 1-replica Deployment, so both survive the web and the executor scaling to
    # zero and each series has exactly one source.
    #
    # Unlike GlobalExporter this one is *not* Rails-free — SolidQueue is
    # ActiveRecord-backed and reads the app's own tables — so the host's
    # entrypoint boots the environment first, e.g. `bin/solid-queue-pod`:
    #
    #   #!/usr/bin/env ruby
    #   require_relative '../config/environment'
    #   RailsPodKit::SolidQueue.run_exporter!
    #
    # Pass `scheduler: false` to serve the gauges only (an app whose web process
    # already hosts the scheduler), and `metrics:` to override the gauge options
    # — this endpoint is the collector's own, so a collection failure fails the
    # scrape here rather than serving the last reading.
    def run_exporter!(scheduler: true, metrics: {}, **scheduler_options)
      install_metrics!(fail_scrape_on_error: true, **metrics)
      start_scheduler!(**scheduler_options) if scheduler

      warn '[rails_pod_kit] disabled — /metrics not served by the SolidQueue exporter' unless Exporter.start!

      require 'yabeda'
      Yabeda.configure! unless Yabeda.already_configured?

      await_shutdown
      stop_scheduler!
    end

    # Blocks the main thread (the exporter and the scheduler both run on their
    # own) until the kubelet signals. A self-pipe rather than a Queue or a
    # Mutex: writing to an IO is one of the few things safe to do from a trap
    # handler.
    def await_shutdown
      reader, writer = IO.pipe
      %w[INT TERM].each { |signal| Signal.trap(signal) { writer.puts(signal) } }
      reader.gets
    end
  end
end
