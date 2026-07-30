# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`rails_pod_kit` is a Ruby gem that packages the operational endpoints a Rails
application needs to be a good Kubernetes citizen behind a single, opinionated
entry point:

- **Prometheus metrics** for Puma, Sidekiq and SolidQueue, served **in-process**
  on a single `/metrics` endpoint (default port `9394`) — a thin wrapper around the
  [yabeda](https://github.com/yabeda-rb) ecosystem (`yabeda`, `yabeda-puma-plugin`,
  `yabeda-sidekiq`, `yabeda-prometheus-mmap`). No sidecar, no separate collector.
  The SolidQueue queue gauges are the gem's own — yabeda has no plugin for it.
- **Health checks** on `/healthz` for startup/liveness/readiness probes — a thin
  wrapper around [health-monitor-rails](https://github.com/lbeder/health-monitor-rails).
- **Scheduler hosting for scale-to-zero**, so a job executor can be autoscaled to
  zero without stranding recurring/scheduled jobs: a supervised SolidQueue
  scheduler thread, and a supervised sidekiq-cron poller for Sidekiq.

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

The specs run **in isolation** — they do not boot a host Rails app, and there is
no database. Every metrics hook is a complete no-op when the exporter is disabled
or in the `test` environment, so the suite never binds port `9394`.

The two schedulers are not gated on that switch (they are not exporters —
`scheduler_enabled` is theirs, and it stays on in `test`). What keeps them
harmless in the suite is that neither spawns a real thread there: the specs stub
`Concurrent::TimerTask.new` and drive the supervisor tick by hand, so nothing
ever polls Redis or touches a database.

### CI Matrix

Tests run against a reduced matrix of Ruby x Rails/Rack via
[Appraisal](https://github.com/thoughtbot/appraisal). The gem requires Ruby
`>= 3.3`. The interesting axis besides Rails is **Rack**: the
`yabeda-prometheus-mmap` exporter mounts a WEBrick Rack handler that lives in
`webrick` under Rack 2.x but was extracted into the `rackup` gem under Rack 3+.
Rails 7.2 is exercised against Rack 2.2, Rails 8.x against Rack 3.

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
- **`RailsPodKit::Exporter`** (`lib/rails_pod_kit/exporter.rb`) — the in-process
  WEBrick `/metrics` server shared by every **non-Puma** entry point (Sidekiq,
  the global exporter, the SolidQueue pod). One latch per process, so no entry
  point can double-bind the port. Under Puma the exporter comes from the
  `:yabeda_prometheus` plugin instead.
- **`RailsPodKit::Sidekiq`** (`lib/rails_pod_kit/sidekiq.rb`) — called from
  inside `Sidekiq.configure_server`; requires yabeda-sidekiq, applies the
  global-metrics policy, and starts the in-process exporter. Drives
  `Yabeda.configure!` from Sidekiq's `:startup` lifecycle event.
- **`RailsPodKit::SolidQueue`** (`lib/rails_pod_kit/solid_queue.rb` +
  `solid_queue/`) — the scale-to-zero support, all opt-in and inert until
  called. `Metrics` declares the `solid_queue_backlog` /
  `solid_queue_latency_seconds` gauges and computes them from the SolidQueue
  tables at scrape time (yabeda `collect`, no background thread). Zeroing starts
  from a baseline of the queues the app uses, so an idle process reads 0 instead
  of publishing nothing at all; a DB error is always reported and, by default,
  swallowed so one group can't fail an endpoint it shares —
  `fail_scrape_on_error: true` (what `run_exporter!` passes on its own pod)
  turns it into a failed scrape, i.e. honest no-data.
  `SchedulerRunner` runs a scheduler-only `SolidQueue::Scheduler` in a thread
  supervised by the shared `Supervisor` — deliberately *not* the full
  supervisor, whose Puma watchdog takes the host process down on a DB blip
  (rails/solid_queue#512). `run_exporter!` combines both into the always-on
  1-replica pod; unlike GlobalExporter it needs the host's ActiveRecord models,
  so the entrypoint boots Rails first.
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
  a host decision. `scheduler: true` adds GlobalScheduler to the same process.
- **`RailsPodKit::GlobalScheduler`** (`lib/rails_pod_kit/global_scheduler.rb`) —
  the Sidekiq counterpart of SolidQueue's `SchedulerRunner`: the sidekiq-cron
  poller in a process that is *not* a Sidekiq server, so the worker fleet can
  scale to zero without losing the schedule. Rails-free, which is only possible
  because `Job#enqueue!` falls back to pushing an ActiveJob wrapper message
  naming the class as a string when it cannot resolve it — hence the
  `active_job: true` requirement on every entry, which `start!` warns about. It
  also loads the schedule file itself (sidekiq-cron does that from a Sidekiq
  server's `:startup` event) and requires `erb`, which sidekiq-cron uses without
  requiring. Supervised by the shared `Supervisor`, because a dead poller on the
  only scheduling process is a silently stopped schedule.
- **`RailsPodKit::GlobalScheduler::Heartbeat`**
  (`lib/rails_pod_kit/global_scheduler/heartbeat.rb`) — publishes
  `sidekiq_cron_poll_age_seconds`, the age of the last completed poller tick,
  recorded by a `Sidekiq::Cron::Poller` subclass `build_poller` instantiates (a
  subclass, not a prepended module, so a host that also runs a Sidekiq server
  keeps sidekiq-cron's own poller untouched). Covers the one failure the
  Supervisor and the probe both miss: a poller running but no longer
  enqueueing, which from outside looks exactly like an idle one. Monotonic, and
  measured from `start!` until the first tick so a poller that never ran reads
  as climbing rather than as no-data.
- **`RailsPodKit::Supervisor`** (`lib/rails_pod_kit/supervisor.rb`) — the
  keep-the-background-thread-alive timer both schedulers run under: immediate
  first tick, a `@stopping` latch so a shutdown cannot be undone by a tick
  already in flight, and `ErrorReporter` instead of dying (a
  `Concurrent::TimerTask` silently drops a raising block). The three things that
  differ per worker are injected — `start:` (a callable returning the started
  worker), `alive:` and `stop:` (a method name to send the worker, or a callable
  taking it). `alive:` accepts a callable precisely for `GlobalScheduler`:
  `Sidekiq::Scheduled::Poller` exposes no liveness of its own, so the check has
  to peek at `@thread`. Railties-free, since one of its two users is.
- **`RailsPodKit::Shutdown`** (`lib/rails_pod_kit/shutdown.rb`) — the
  block-until-SIGTERM self-pipe shared by the always-on entry points.

### The metrics invariant

`spec/rails_pod_kit/metrics_invariant_spec.rb` guards that every series on the
`/metrics` endpoint carries one of the kit's group prefixes — only
yabeda-registered `puma_*` / `sidekiq_*` / `solid_queue_*` may appear. The
Datadog OpenMetrics check uses `metrics: [".*"]` with `raw_metric_prefix`, which
only *strips* the prefix, it does not filter, so any unprefixed series leaking
onto the endpoint would be ingested un-stripped under the namespace. Do not add
cross-cutting metrics (process, runtime, HTTP request) to this exporter. An
endpoint carrying **two** groups also needs an explicit per-instance `metrics:`
filter on the check side — which is why the SolidQueue gauges are documented as
belonging on their own pod. See the README "Invariant" section.

The exposition-level example is deliberately a *single* example:
prometheus-client-mmap memoizes its file handles, so a second scrape under a
fresh multiprocess dir renders an empty body.

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
lib/rails_pod_kit/         # the gem (global_exporter + global_scheduler = the always-on singleton pod)
lib/rails_pod_kit/global_scheduler/  # the cron poll heartbeat gauge
lib/rails_pod_kit/solid_queue/  # queue gauges + supervised scheduler thread
spec/rails_pod_kit/        # isolated unit specs + the metrics invariant spec
Appraisals                 # Rails/Rack test matrix definitions
gemfiles/                  # generated, committed appraisal gemfiles
VERSION                    # single source of truth for the version
.github/workflows/         # ci, rubocop, actionlint, release-drafter, autolabeler, release
.github/release-drafter.yml, dependabot.yml
```

## Dependencies

- **Runtime:** the yabeda stack (`yabeda`, `yabeda-sidekiq`, `yabeda-puma-plugin`,
  `yabeda-prometheus-mmap`), `webrick`, `anyway_config`, `concurrent-ruby`,
  `health-monitor-rails`, `redis`. Declared in `rails_pod_kit.gemspec`.
- **Host-provided:** `puma`, `sidekiq`, `sidekiq-cron`, `solid_queue`, `rack` and
  — under Rack 3 — `rackup`. Not in the gemspec, because in a real app they are
  the host's dependencies. `puma`, `sidekiq`, `sidekiq-cron` and `rack` are in
  the `Gemfile` / `Appraisals` for the specs; `solid_queue` is not — its specs
  stub the two ActiveRecord models and the scheduler, so the suite needs no
  database.
- Dependabot (`.github/dependabot.yml`) opens weekly bundler + github-actions
  update PRs.
