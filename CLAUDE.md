# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`rails_pod_kit` is a Ruby gem that packages the operational endpoints a Rails
application needs to be a good Kubernetes citizen behind a single, opinionated
entry point:

- **Prometheus metrics** for Puma and Sidekiq, served **in-process** on a single
  `/metrics` endpoint (default port `9394`) — a thin wrapper around the
  [yabeda](https://github.com/yabeda-rb) ecosystem (`yabeda`, `yabeda-puma-plugin`,
  `yabeda-sidekiq`, `yabeda-prometheus-mmap`). No sidecar, no separate collector.
- **Health checks** on `/healthz` for startup/liveness/readiness probes — a thin
  wrapper around [health-monitor-rails](https://github.com/lbeder/health-monitor-rails).

The gem is deliberately **connection-agnostic**: it never reads `REDIS_URL` and
makes no TLS decisions. Where a Redis connection is needed the host injects its
own options. See `README.md` for the full user-facing documentation.

**This is a public repository.** Keep it self-contained: no references to private
applications, internal infrastructure, deployment targets, or any specific
adopter. Document the gem generically.

## Contribution Conventions

- **English everywhere** — code, comments, commit messages, issues, PRs.
- **No narrative in code comments** — comment only the non-obvious *why*, not a
  play-by-play of *what*. Keep design rationale in the PR description.
- **PRs:** keep the description coherent with what was actually implemented
  (update it if the diff changes). PRs are labelled by
  [release-drafter](https://github.com/release-drafter/release-drafter)'s
  autolabeler; the label drives the changelog category and the version bump
  (see Releasing below).

## Commands

```bash
bundle exec rspec                        # Run the full test suite
bundle exec rspec spec/path/to/spec.rb   # Run a single spec file
bundle exec rspec spec/path:42           # Run a specific example by line number
bundle exec rubocop                      # Lint
bundle exec rubocop -a                   # Lint with safe auto-correct
bundle exec rake                         # Run both rspec and rubocop (default task)
```

The specs run **in isolation** — they do not boot a host Rails app. Every
metrics hook is a complete no-op when the exporter is disabled or in the `test`
environment, so the suite never binds port `9394`.

### CI Matrix

Tests run against a reduced matrix of Ruby x Rails/Rack via
[Appraisal](https://github.com/thoughtbot/appraisal). The gem requires Ruby
`>= 3.3`. The interesting axis besides Rails is **Rack**: the
`yabeda-prometheus-mmap` exporter mounts a WEBrick Rack handler that lives in
`webrick` under Rack 2.x but was extracted into the `rackup` gem under Rack 3+.
Rails 7.1/7.2 are exercised against Rack 2.2, Rails 8.x against Rack 3.

Variants are declared in the `Appraisals` file. The generated
`gemfiles/*.gemfile` are committed; regenerate them with
`bundle exec appraisal generate` after changing the `Gemfile` or `Appraisals`.

```bash
bundle exec appraisal install                 # Bundle every variant (once, or after dependency changes)
bundle exec appraisal rails-8.1 rspec         # Run the suite against a specific variant
BUNDLE_GEMFILE=gemfiles/rails_8.1.gemfile bundle exec rspec   # Equivalent, as used in CI
```

`.github/workflows/ci.yml` runs RSpec across the matrix and
`.github/workflows/rubocop.yml` runs RuboCop, both on push to `main` and on PRs.
`.github/workflows/actionlint.yml` lints the workflow files themselves.

## Architecture

### Entry points

There are two distinct entry points, by design:

- **`require 'rails_pod_kit'`** (what `Bundler.require` loads in a Rails app)
  pulls in every integration unconditionally, including the health-monitor-rails
  engine and its railties foundation, regardless of Gemfile declaration order.
- **The sub-entry points** (`rails_pod_kit/puma`, `rails_pod_kit/global_exporter`)
  require only the config core (`rails_pod_kit/config`), so a Rails-free process
  (the dedicated global exporter) stays railties-free, and a
  `puma -C config/puma.rb` boot — which evaluates `config/puma.rb` before Rails
  exists — still gets the integrations once `Bundler.require` runs.

### Key Components

- **`RailsPodKit::Config`** (`lib/rails_pod_kit/config.rb`) — an
  [anyway_config](https://github.com/palkan/anyway_config) config shared by every
  entry point. Reads `RAILS_POD_KIT_*` env vars and an optional
  `config/rails_pod_kit.yml`, with the `RailsPodKit.configure` block winning.
  Memoized on the module; `reset_config!` is the test hook.
- **`RailsPodKit::Puma`** (`lib/rails_pod_kit/puma.rb`) — activates the Puma
  control app + the `:yabeda` / `:yabeda_prometheus` plugins from a one-line
  `config/puma.rb`. Drives `Yabeda.configure!` from the exporter-boot hook,
  because `config/puma.rb` is evaluated before Rails and yabeda's own Railtie may
  never register.
- **`RailsPodKit::Sidekiq`** (`lib/rails_pod_kit/sidekiq.rb`) — called from
  inside `Sidekiq.configure_server`; requires yabeda-sidekiq, applies the
  global-metrics policy, and starts the in-process WEBrick exporter. Drives
  `Yabeda.configure!` from Sidekiq's `:startup` lifecycle event.
- **`RailsPodKit::Health`** (`lib/rails_pod_kit/health.rb`) — opinionated
  health-monitor-rails configuration (database/cache/Redis/optionally Sidekiq).
  The Redis connection is injected by the host.
- **`RailsPodKit::Railtie`** (`lib/rails_pod_kit/railtie.rb`) — mounts
  `HealthMonitor::Engine` automatically (unless `Health.install!(mount: false)`),
  so the host doesn't have to touch `config/routes.rb`.
- **`RailsPodKit::GlobalExporter`** (`lib/rails_pod_kit/global_exporter.rb`) — a
  standalone, **Rails-free** exporter for the Sidekiq global (Redis-wide) queue
  metrics, meant to run as its own 1-replica Deployment so those series come from
  a single source, decoupled from web/worker autoscaling. The host owns the
  entrypoint (the gem ships no executable) so the Redis connection config stays
  a host decision.

### The metrics invariant

`spec/rails_pod_kit/metrics_invariant_spec.rb` guards that the `/metrics`
endpoint stays **prefix-pure** — only yabeda-registered `puma_*` / `sidekiq_*`
series may appear on it. The Datadog OpenMetrics check uses `metrics: [".*"]`
with `raw_metric_prefix`, which only *strips* the prefix, it does not filter, so
any unprefixed series leaking onto the endpoint would be ingested un-stripped
under the namespace. Do not add cross-cutting metrics (process, runtime, HTTP
request) to this exporter. See the README "Invariant" section.

## Versioning & Releasing

The version lives in the root `VERSION` file; `lib/rails_pod_kit/version.rb`
reads it, and the gemspec reads that. The release flow is fully automated:

1. **`release-drafter`** (`.github/workflows/release-drafter.yml`) keeps a draft
   GitHub release up to date on every push to `main`, computing the next version
   from merged-PR labels (`major` / `minor` / `patch`, default `patch`) and
   categorising the changelog. Config: `.github/release-drafter.yml`. The
   autolabeler (`.github/workflows/autolabeler.yml`) applies labels to PRs.
2. The same workflow then **writes the resolved version into the `VERSION`
   file** and commits it back to `main` (authenticated as the `bot-fabn` GitHub
   App, whose `BOT_APP_ID` variable and `BOT_APP_PRIVATE_KEY` secret are provided
   at the repo level; the default-branch ruleset lets the App bypass the PR
   requirement for that single commit).
3. **Publishing the draft release** triggers `.github/workflows/release.yml`,
   which pushes the gem to RubyGems via `rubygems/release-gem` using **OIDC
   trusted publishing** (`id-token: write`, `environment: release`) — no
   RubyGems API key is stored in the repo. The gem must be registered as a
   trusted publisher on rubygems.org for this to succeed.

## Repository Structure

```
lib/rails_pod_kit/         # the gem
spec/rails_pod_kit/        # isolated unit specs + the metrics invariant spec
Appraisals                 # Rails/Rack test matrix definitions
gemfiles/                  # generated, committed appraisal gemfiles
VERSION                    # single source of truth for the version
.github/workflows/         # ci, rubocop, actionlint, release-drafter, autolabeler, release
.github/release-drafter.yml, dependabot.yml
```

## Dependencies

- **Runtime:** the yabeda stack (`yabeda`, `yabeda-sidekiq`, `yabeda-puma-plugin`,
  `yabeda-prometheus-mmap`), `webrick`, `anyway_config`, `health-monitor-rails`,
  `redis`. Declared in `rails_pod_kit.gemspec`.
- **Host-provided (test only):** `puma`, `sidekiq`, `rack` and — under Rack 3 —
  `rackup`. Declared in the `Gemfile` / `Appraisals`, not the gemspec, because in
  a real app they are the host's dependencies.
- Dependabot (`.github/dependabot.yml`) opens weekly bundler + github-actions
  update PRs.
