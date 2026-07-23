# frozen_string_literal: true

require 'rails_pod_kit/version'
require 'rails_pod_kit/config'

# RailsPodKit packages the operational endpoints a Rails pod needs to be a good
# Kubernetes citizen behind a single, opinionated entry point:
#
# - Prometheus metrics: Puma and Sidekiq runtime metrics in Prometheus text
#   format on an in-process /metrics endpoint (default port 9394) — no sidecar,
#   no separate collector process. A thin wrapper around the yabeda ecosystem.
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
# plus, only when running the dedicated global exporter, a host-owned
# entrypoint (e.g. bin/pod-exporter) calling GlobalExporter.run!(redis: ...).
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
require 'rails_pod_kit/sidekiq'
require 'rails_pod_kit/health'
require 'rails_pod_kit/railtie'
