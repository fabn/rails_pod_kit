# rails_pod_kit

The operational endpoints a Rails pod needs to be a good Kubernetes citizen,
packaged behind a single, opinionated entry point:

- **Prometheus metrics** for Puma and Sidekiq, served **in-process** on a
  single `/metrics` endpoint (default port **9394**) in both the web (Puma) and
  worker (Sidekiq) processes — no sidecar, no separate collector process. A
  metrics agent (e.g. the Datadog Agent via OpenMetrics autodiscovery) scrapes
  the pod directly.
- **Health checks** on `/healthz` (database, cache, Redis, optionally Sidekiq),
  wired for Kubernetes startup/liveness/readiness probes — a thin, opinionated
  wrapper around [health-monitor-rails](https://github.com/lbeder/health-monitor-rails).

The metrics side is a thin wrapper around the
[yabeda](https://github.com/yabeda-rb) ecosystem:

| gem | what it gives us |
|-----|------------------|
| `yabeda` | in-process metrics registry |
| `yabeda-puma-plugin` | Puma thread-pool / worker stats + the `:yabeda` / `:yabeda_prometheus` Puma plugins |
| `yabeda-sidekiq` | Sidekiq per-process job metrics + global/Redis-wide queue metrics |
| `yabeda-prometheus-mmap` | Prometheus text exporter, multiprocess-safe via `prometheus-client-mmap` |
| `webrick` | HTTP server for the Sidekiq exporter |

> Scope: **runtime/worker metrics only** (Puma backlog/threads, Sidekiq queues
> and jobs). HTTP request-level metrics are intentionally out of scope — that is
> covered by APM.

The gem is deliberately **connection-agnostic**: it never reads `REDIS_URL` and
makes no TLS decisions. Wherever a Redis connection is needed (health checks,
the dedicated global exporter) the host injects its own options, so connection
config keeps a single, host-owned source of truth.

## Wiring

The host app wires the gem in three one-liners. Every metrics hook is a
complete no-op when the exporter is disabled or in the `test` environment, so
the suite never binds the port. The integrations wire themselves at
`Bundler.require` and the gem's Railtie mounts the health endpoint — no
`require:` gymnastics in the Gemfile, no routes change.

**1. `config/initializers/rails_pod_kit.rb`** — configure once:

```ruby
RailsPodKit.configure do |c|
  c.enabled = !Rails.env.test?
  c.port    = Integer(ENV.fetch('PROMETHEUS_EXPORTER_PORT', 9394))
end

RailsPodKit::Health.install!(
  redis:   { url: ENV['REDIS_URL'] },              # the host's own Redis options
  sidekiq: { queue_size: 200, latency: 10.minutes } # omit on hosts without Sidekiq
)
```

**2. `config/puma.rb`** — activate the Puma plugins:

```ruby
require 'rails_pod_kit/puma'
RailsPodKit::Puma.activate(self)
```

**3. `config/initializers/sidekiq.rb`** (inside `Sidekiq.configure_server`):

```ruby
RailsPodKit::Sidekiq.install!(config)
```

## Configuration

`RailsPodKit::Config` is an [anyway_config](https://github.com/palkan/anyway_config)
config: besides the `RailsPodKit.configure` block (which runs last and wins),
every setting can come from a `RAILS_POD_KIT_*` env var (e.g.
`RAILS_POD_KIT_ENABLED=false`, `RAILS_POD_KIT_PORT=9500`,
`RAILS_POD_KIT_SIDEKIQ_GLOBAL_METRICS=off`) or an optional
`config/rails_pod_kit.yml` — handy for the Rails-free exporter pod, which runs
no initializers.

| setting | default | meaning |
|---------|---------|---------|
| `enabled` | on, except in `test` | master switch; `false` ⇒ no exporter, no port bound |
| `port` | `9394` (env `PROMETHEUS_EXPORTER_PORT`) | exporter bind port for Puma **and** Sidekiq |
| `sidekiq_global_metrics` | `:web` | who exports the Redis-wide queue metrics: `:web` = only the always-on web process (no per-worker duplication); `:all` = every worker; `:off` = nobody |
| `puma_control_url` | `tcp://127.0.0.1:9293` (env `PUMA_CONTROL_URL`) | localhost-only Puma control app the stats reader queries |
| `retries_segmented_by_queue` | `false` | when `true`, the global retry gauge (`sidekiq_jobs_retry_count`) carries a `queue` tag instead of being a single scalar. Opt-in: per-queue retries increase series cardinality. |
| `silence_exporter_access_log` | `true` | suppress the exporter's per-scrape `GET /metrics` access log on **both** transports (Puma plugin + WEBrick). The endpoint is pod-internal and scraped on a fixed interval, so the line is pure noise. Set `false` only to debug the exporter. |

## Health checks (`RailsPodKit::Health`)

`Health.install!` configures health-monitor-rails with the kit's defaults:
endpoint at `/healthz`, checking **database** (health_monitor's default),
**cache**, **Redis** (connection injected by the host) and — when a `sidekiq:`
thresholds hash is given — **Sidekiq**. The gem's Railtie mounts
`HealthMonitor::Engine` at `/` automatically; pass `mount: false` to keep
route ownership (custom mount point, constraints) and mount it yourself in
`config/routes.rb`. Any further tuning goes through the optional block, which
receives the `HealthMonitor` configuration.

```ruby
RailsPodKit::Health.install!(
  redis:   { url: ENV['REDIS_URL'] }, # or a ready Redis/ConnectionPool object
  path:    :healthz,                  # default
  sidekiq: { queue_size: 200, latency: 10.minutes }
) do |config|
  config.error_callback = ->(e) { ... } # host-specific extras
end
```

Probe wiring on Kubernetes:

- **startup probe** → `/healthz` — the full check, so the pod doesn't go ready
  until its dependencies are actually up;
- **liveness/readiness probes** → `/healthz?providers[]=none` — short-circuits
  the dependency checks once the pod is live, so a transient Redis hiccup
  doesn't restart the app.

The same `providers[]=none` trick works for a manual basic check:

```bash
curl '/healthz?providers[]=none' -H 'Accept: application/json'
```

The per-probe controller logging is silenced by default (kubelet probes hit the
endpoint every few seconds); pass `silence_controller_log: false` to keep it.

## Metrics exposed on `/metrics`

- **Puma:** `puma_workers`, `puma_running`, `puma_pool_capacity`,
  `puma_max_threads`, `puma_backlog`, `puma_busy_threads`,
  `puma_requests_count`, …
- **Sidekiq (per-process):** `sidekiq_jobs_executed_total`,
  `sidekiq_jobs_success_total`, `sidekiq_jobs_failed_total`,
  `sidekiq_job_runtime_seconds`, `sidekiq_job_latency_seconds`,
  `sidekiq_running_job_runtime_seconds`, …
- **Sidekiq (global/Redis-wide):** `sidekiq_jobs_waiting_count`,
  `sidekiq_queue_latency`, `sidekiq_active_processes`,
  `sidekiq_active_workers_count`, `sidekiq_jobs_retry_count`,
  `sidekiq_jobs_dead_count`, `sidekiq_jobs_scheduled_count`.

Series are intentionally **untagged**: a scraping agent adds
`service`/`env`/`version` and `kube_*` tags at scrape time, so the gem doesn't
duplicate them.

## Datadog naming — the canonical metric set

The gem emits the **untagged native Prometheus names** above (`puma_running`,
`sidekiq_queue_latency`, …). To get a clean, **org-shared** metric set every
adopter must use the **same Datadog OpenMetrics check config**, so all series
differ only by `service` / `env` (+ the `kube_*`/`host`/`pid` tags the Agent adds
at scrape time) and dashboards/monitors are reusable across projects.

The check `namespace` prepends `puma.` / `sidekiq.`; left alone that would
**double-prefix** the native names (`puma.puma_running`). `raw_metric_prefix`
strips the redundant native segment *before* the namespace is applied, so series
land under the canonical `puma.<name>` / `sidekiq.<name>`:

```yaml
# Puma (web pod) — :9394/metrics
instances:
  - openmetrics_endpoint: "http://%%host%%:9394/metrics"
    namespace: "puma"
    raw_metric_prefix: "puma_"      # puma_running -> puma.running
    metrics: [".*"]
    tag_by_endpoint: false

# Sidekiq (worker pod + dedicated global exporter) — :9394/metrics
instances:
  - openmetrics_endpoint: "http://%%host%%:9394/metrics"
    namespace: "sidekiq"
    raw_metric_prefix: "sidekiq_"   # sidekiq_queue_latency -> sidekiq.queue_latency
    metrics: [".*"]
    tag_by_endpoint: false
```

On Kubernetes this is typically wired as pod-annotation autodiscovery. The
`openmetrics_endpoint` above uses the Datadog Agent's `%%host%%` autodiscovery
template (resolves to the pod IP) — a **non-k8s adopter** (a plain `conf.yaml`
check) swaps `%%host%%:9394` for the real `host:port`; everything else
(`namespace`, `raw_metric_prefix`, `metrics`) is identical.

### Invariant — the endpoint must stay prefix-pure

The Datadog check uses `metrics: [".*"]`, which ingests **every** series on the
endpoint. `raw_metric_prefix` only *strips* the prefix when present — **it does
not filter**. So the naming scheme above holds only because the `/metrics`
endpoint exposes **solely** yabeda-registered series, all sharing the
`puma_` / `sidekiq_` group prefix:

- the gem registers only the `:puma` and `:sidekiq` yabeda groups (no process,
  GC, or Ruby-runtime collectors);
- the exposition serves Yabeda's registry only — the Prometheus client's HTTP
  request collector (`http_*`) is **not** mounted on the exporter.

If a series without the `puma_` / `sidekiq_` prefix ever appeared on the
endpoint, `metrics: [".*"]` would ingest it **un-stripped** under the namespace
(e.g. `puma.http_requests_total`). **Do not** add cross-cutting metrics (process,
runtime, HTTP request) to this exporter, and do not mount the Prometheus Rack
collector on it. If you ever need such metrics, expose them on a separate
endpoint with its own check rather than polluting this one. Conversely, any new
metric you *do* add to the `:puma` / `:sidekiq` groups is picked up automatically
by `[".*"]` — no check change needed.

> ⚠️ Renaming the namespace prefix is a **breaking metric rename** — existing
> dashboards/monitors built on the old `puma.puma_*` / `sidekiq.sidekiq_*` series
> must be migrated.

### Canonical catalog

Functional (non-technical) tags only; `service`/`env`/`kube_*`/`pid`/… are added
by the Agent. `index` = Puma worker index (`0` in single-mode); `worker` = the
Sidekiq job class.

**Puma** (web pod, `namespace: puma`):

| canonical Datadog metric | functional tags |
|---|---|
| `puma.running` | `index` |
| `puma.backlog` | `index` |
| `puma.busy_threads` | `index` |
| `puma.pool_capacity` | `index` |
| `puma.max_threads` | `index` |
| `puma.requests_count` | `index` |

**Sidekiq — global / Redis-wide** (dedicated global-exporter pod, `namespace: sidekiq`):

| canonical Datadog metric | functional tags |
|---|---|
| `sidekiq.jobs_waiting_count` | `queue` |
| `sidekiq.queue_latency` | `queue` |
| `sidekiq.jobs_scheduled_count` | — |
| `sidekiq.jobs_retry_count` | — (`queue` if `retries_segmented_by_queue`) |
| `sidekiq.jobs_dead_count` | — |
| `sidekiq.active_processes` | — |
| `sidekiq.active_workers_count` | — |

**Sidekiq — per-process / job** (worker pod, `namespace: sidekiq`; emitted on job activity):

| canonical Datadog metric | type | functional tags |
|---|---|---|
| `sidekiq.jobs_executed_total` | counter | `queue`, `worker` |
| `sidekiq.jobs_success_total` | counter | `queue`, `worker` |
| `sidekiq.jobs_failed_total` | counter | `queue`, `worker` |
| `sidekiq.jobs_enqueued_total` | counter | `queue`, `worker` |
| `sidekiq.jobs_rerouted_total` | counter | `from_queue`, `to_queue`, `worker` |
| `sidekiq.running_job_runtime` | gauge | `queue`, `worker` |
| `sidekiq.job_runtime` | histogram | `queue`, `worker` |
| `sidekiq.job_latency` | histogram | `queue`, `worker` |

### Where Sidekiq global metrics come from

The global (Redis-wide) queue gauges — `sidekiq_jobs_waiting_count`,
`sidekiq_queue_latency`, … — are read from Redis and are identical regardless of
which process reads them. The default **`:web`** policy collects them only in the
always-on **web** process (which already has the Sidekiq client / Redis access),
so there's a **single source and no per-worker duplication**: workers export only
their own per-process job metrics. Workers can scale (even to zero) without
losing the queue metrics.

Alternatives via `c.sidekiq_global_metrics`:

- **`:all`** — every worker pod exports the global gauges (the legacy behaviour).
  Datadog then has one series **per pod**, so aggregate in dashboards/monitors
  with `max:sidekiq.queue_latency{*} by {queue}` (Datadog space aggregation —
  never `sum`, which would multiply by pod count).
- **`:off`** — neither web nor workers collect them. Use this with a **dedicated
  exporter** (below) so the gauges still come from somewhere — exactly once.

> Under `:web`, if the web Deployment runs more than one replica the gauges are
> duplicated across those (few, stable) web pods — apply the same
> `max:… by {queue}` aggregation, or use the dedicated exporter for one series.

### Dedicated global-metrics exporter (recommended for multi-replica / KEDA)

When the web and worker pods are autoscaled (e.g. KEDA, possibly to zero), the
cleanest single source for the Redis-wide queue gauges is a **dedicated 1-replica
Deployment** that does nothing but read them from Redis and expose them. It is
decoupled from web/worker scaling and yields exactly **one series** per gauge.

Set `c.sidekiq_global_metrics = :off` (so web/workers don't collect them), then
run a 1-replica Deployment with a thin, **host-owned** entrypoint — the gem
deliberately ships no executable, so the Redis connection config stays with the
host. E.g. `bin/pod-exporter`:

```ruby
#!/usr/bin/env ruby
# bundler/setup only wires the $LOAD_PATH from the lockfile — nothing is
# required beyond the lines below, so the process stays tiny.
require 'bundler/setup'
require 'rails_pod_kit/global_exporter'

RailsPodKit::GlobalExporter.run!(redis: { url: ENV['REDIS_URL'] })
```

```
command: ["bin/pod-exporter"]
```

The entrypoint is deliberately **Rails-free**: `run!` only wires the Sidekiq
client's Redis connection from the injected options plus the yabeda stack,
declares the cluster gauges, starts the exporter and blocks until SIGTERM.
Booting the full host app just to read a handful of Redis counters would cost
~300Mi RSS for nothing — this process sits at ~60Mi.

## Caveats

- **Puma only.** The Puma plugins only activate under Puma; under any other
  app server the in-process `/metrics` endpoint is **not** exposed.
- **Puma control app.** `yabeda-puma-plugin` reads Puma's thread-pool stats
  through Puma's control app, so `Puma.activate` activates one on a
  localhost-only socket (`no_token: true`, never network-exposed).
- **Rack version.** Under **Rack 3+** the mmap exporter's WEBrick handler also
  needs the `rackup` gem. Under Rack 2.x `webrick` alone is enough, but on
  Ruby ≥ 3.5 make sure `ostruct` is in the bundle (Rack 2.2 requires it
  without declaring it, and it's no longer a default gem).
- **Two kinds of entry point.** The main file (`require 'rails_pod_kit'`,
  what Bundler.require loads in a Rails app) pulls in every integration
  unconditionally — including the health-monitor-rails engine and its
  railties foundation — regardless of Gemfile declaration order. The
  sub-entry points (`rails_pod_kit/puma`, `rails_pod_kit/global_exporter`)
  require only the config core, so the Rails-free exporter stays
  railties-free and a `puma -C config/puma.rb` boot (which evaluates
  `config/puma.rb` before Rails) still gets the integrations once
  `Bundler.require` runs.

## Local verification

Boot each process with the exporter enabled and scrape `:9394/metrics`:

```bash
# Web (Puma): puma_* series
bundle exec rails server
curl -s localhost:9394/metrics | grep '^puma_'

# Worker (Sidekiq): sidekiq_* series (run a job first so per-process counters appear)
bundle exec sidekiq
curl -s localhost:9394/metrics | grep '^sidekiq_'

# Health endpoint
curl -s localhost:3000/healthz -H 'Accept: application/json'
```

## Tests

The gem's specs run in isolation (they do not load a host Rails app):

```bash
bundle install
bundle exec rspec
```

The suite runs against a matrix of Rails/Rack versions via
[Appraisal](https://github.com/thoughtbot/appraisal):

```bash
bundle exec appraisal install
bundle exec appraisal rails-8.1 rspec
```

## License

Released under the [MIT License](LICENSE.txt).
