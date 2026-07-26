# frozen_string_literal: true

require 'rails_pod_kit/version'
require 'rails_pod_kit/config'

# RailsPodKit packages the operational endpoints a Rails pod needs to be a good
# Kubernetes citizen behind a single, opinionated entry point:
#
# - Prometheus metrics: Puma, Sidekiq and SolidQueue runtime metrics in
#   Prometheus text format on an in-process /metrics endpoint (default port
#   9394) — no sidecar, no separate collector process. A thin wrapper around the
#   yabeda ecosystem, plus the SolidQueue queue gauges yabeda has no plugin for.
# - Health checks: an opinionated health-monitor-rails configuration serving
#   liveness/readiness/startup probes on /healthz (see RailsPodKit::Health),
#   auto-mounted by the gem's Railtie.
#
# Metric series are intentionally left untagged here: a scraping agent (e.g.
# the Datadog Agent) adds service/env/version and kube_* tags at scrape time,
# so the gem doesn't duplicate them.
#
# Wiring (see README) is three one-liners:
#   - config/puma.rb                          -> RailsPodKit::Puma.activate(self)
#   - config/initializers/sidekiq.rb          -> RailsPodKit::Sidekiq.install!(config)
#   - config/initializers/rails_pod_kit.rb    -> RailsPodKit.configure { ... }
#                                                RailsPodKit::Health.install!(redis: ...)
# plus, only when running a dedicated always-on exporter, a host-owned
# entrypoint calling GlobalExporter.run!(redis: ...) (Sidekiq, Rails-free) or
# SolidQueue.run_exporter! (SolidQueue, needs the app's ActiveRecord models).
#
# The gem is deliberately connection-agnostic: it never reads REDIS_URL or
# makes TLS decisions. The host injects its Redis options where needed
# (GlobalExporter.run!, Health.install!).

# This is the Rails-app entry point: it loads every integration
# unconditionally (each file requires what it needs, so nothing here depends
# on Gemfile declaration order or on which constants happen to be defined
# yet). The Sidekiq integration is inert until install! is called and pulls in
# yabeda-sidekiq only then; health + railtie load the health-monitor-rails
# engine and railties.
#
# The sub-entry points deliberately require only rails_pod_kit/config instead
# of this file, with two effects:
#   - a Rails-free process (bin/pod-exporter requiring
#     rails_pod_kit/global_exporter) never pulls in railties or Sidekiq;
#   - under `puma -C config/puma.rb` — where Puma evaluates config/puma.rb
#     (and thus rails_pod_kit/puma) before Rails exists — this file is still
#     fresh for Bundler.require, so the integrations load once Rails is up.

# Load the mmap adapter here — at Bundler.require, before any host initializer
# runs — so its self-registration (`Yabeda.register_adapter` at require time)
# happens while no Yabeda metric exists yet, making it a no-op. The adapter's
# own `mmap.rb` requires the adapter *before* defining
# `Yabeda::Prometheus::Mmap.registry`; if a metric is already declared when the
# adapter loads, registration eagerly reaches for that not-yet-defined method
# and boots crash with a NoMethodError. Under `bin/rails server` Rails boots
# (and its initializers may declare metrics) before config/puma.rb requires the
# adapter, so loading it here is what makes the order-of-boot irrelevant. The
# lazy require in RailsPodKit::Puma.activate then degrades to a cheap no-op.
require 'yabeda/prometheus/mmap'

require 'rails_pod_kit/sidekiq'
require 'rails_pod_kit/solid_queue'
require 'rails_pod_kit/health'
require 'rails_pod_kit/railtie'
