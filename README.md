# rails_pod_kit

The operational endpoints a Rails pod needs to be a good Kubernetes citizen,
packaged behind a single, opinionated entry point:

- **Prometheus metrics** for Puma, Sidekiq and SolidQueue, served **in-process**
  on a single `/metrics` endpoint (default port **9394**) in the web (Puma) and
  worker processes — no sidecar, no separate collector process. A metrics agent
  (e.g. the Datadog Agent via OpenMetrics autodiscovery) scrapes the pod
  directly.
- **Health checks** on `/healthz` (database, cache, optionally Redis and Sidekiq),
  wired for Kubernetes startup/liveness/readiness probes — a thin, opinionated
  wrapper around [health-monitor-rails](https://github.com/lbeder/health-monitor-rails).
- **Scheduler hosting for scale-to-zero**, so a job executor can be autoscaled to
  zero without stranding its recurring and scheduled jobs: a supervised
  SolidQueue scheduler thread, and a supervised sidekiq-cron poller for Sidekiq.

The metrics side is a thin wrapper around the
[yabeda](https://github.com/yabeda-rb) ecosystem:

| gem | what it gives us |
|-----|------------------|
| `yabeda` | in-process metrics registry |
| `yabeda-puma-plugin` | Puma thread-pool / worker stats + the `:yabeda` / `:yabeda_prometheus` Puma plugins |
| `yabeda-sidekiq` | Sidekiq per-process job metrics + global/Redis-wide queue metrics |
| `yabeda-prometheus-mmap` | Prometheus text exporter, multiprocess-safe via `prometheus-client-mmap` |
| `webrick` | HTTP server for the non-Puma exporters |

The SolidQueue queue gauges are the gem's own: SolidQueue ships no metrics
endpoint and there is no `yabeda-solid_queue` plugin to wrap.

> Scope: **runtime/worker metrics only** (Puma backlog/threads, Sidekiq and
> SolidQueue queues and jobs). HTTP request-level metrics are intentionally out
> of scope — that is covered by APM.

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

On a SolidQueue stack there is no step 3 — see
[SolidQueue](#solidqueue-scale-to-zero) instead.

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
| `enabled` | on, except in `test` | master switch for the **exporter**; `false` ⇒ no exporter, no port bound |
| `scheduler_enabled` | on, everywhere | kill switch for the **hosted schedulers** (sidekiq-cron poller, SolidQueue scheduler thread). Separate from `enabled` — an app may want one without the other, and this is the one you may need to flip in a hurry, since the scheduler is a single point of failure for the whole schedule. On even in `test`: nothing starts a scheduler implicitly, so there is no port to protect, and a switch that failed closed on a typo would silently stop a schedule. Turning it off logs a warning naming the scheduler that did not start. |
| `port` | `9394` (env `PROMETHEUS_EXPORTER_PORT`) | exporter bind port for Puma **and** Sidekiq |
| `sidekiq_global_metrics` | `:web` | who exports the Redis-wide queue metrics: `:web` = only the always-on web process (no per-worker duplication); `:all` = every worker; `:off` = nobody |
| `puma_control_url` | `tcp://127.0.0.1:9293` (env `PUMA_CONTROL_URL`) | localhost-only Puma control app the stats reader queries |
| `retries_segmented_by_queue` | `false` | when `true`, the global retry gauge (`sidekiq_jobs_retry_count`) carries a `queue` tag instead of being a single scalar. Opt-in: per-queue retries increase series cardinality. |
| `silence_exporter_access_log` | `true` | suppress the exporter's per-scrape `GET /metrics` access log on **both** transports (Puma plugin + WEBrick). The endpoint is pod-internal and scraped on a fixed interval, so the line is pure noise. Set `false` only to debug the exporter. |

## Health checks (`RailsPodKit::Health`)

`Health.install!` configures health-monitor-rails with the kit's defaults:
endpoint at `/healthz`, checking **database** (health_monitor's default),
**cache**, — when a `redis:` connection is given — **Redis** (connection
injected by the host) and — when a `sidekiq:` thresholds hash is given —
**Sidekiq**. Omit `redis:` on hosts with no Redis dependency (e.g. a Solid
Queue stack) to get a database + cache only endpoint. The gem's Railtie mounts
`HealthMonitor::Engine` at `/` automatically; pass `mount: false` to keep
route ownership (custom mount point, constraints) and mount it yourself in
`config/routes.rb`. Any further tuning goes through the optional block, which
receives the `HealthMonitor` configuration.

```ruby
RailsPodKit::Health.install!(
  redis:   { url: ENV['REDIS_URL'] }, # optional: a ready Redis/ConnectionPool
                                      # object or options hash; omit for no
                                      # Redis provider
  path:    :healthz,                  # default
  sidekiq: { queue_size: 200, latency: 10.minutes }
) do |config|
  config.error_callback = ->(e) { ... } # host-specific extras
end
```

Without a `redis:` argument the endpoint checks only database and cache
(plus Sidekiq when its thresholds are given):

```ruby
RailsPodKit::Health.install!(path: :healthz) # database + cache only
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
- **SolidQueue (DB-wide):** `solid_queue_backlog`,
  `solid_queue_latency_seconds`.

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

# SolidQueue (the pod publishing the queue gauges) — :9394/metrics
instances:
  - openmetrics_endpoint: "http://%%host%%:9394/metrics"
    namespace: "solid_queue"
    raw_metric_prefix: "solid_queue_"  # solid_queue_backlog -> solid_queue.backlog
    metrics: [".*"]
    tag_by_endpoint: false
```

**One prefix per endpoint.** `metrics: [".*"]` ingests *everything* served
there, so each block above assumes its endpoint carries a single group — which
is why the SolidQueue gauges are best published from their own pod (below).
Where one endpoint really must carry two groups (e.g. a web pod exposing both
`puma_*` and `solid_queue_*`), give **every** instance on it an explicit filter
— `metrics: ["puma_.*"]` and `metrics: ["solid_queue_.*"]` — or each namespace
will swallow the other's series un-stripped.

On Kubernetes this is typically wired as pod-annotation autodiscovery. The
`openmetrics_endpoint` above uses the Datadog Agent's `%%host%%` autodiscovery
template (resolves to the pod IP) — a **non-k8s adopter** (a plain `conf.yaml`
check) swaps `%%host%%:9394` for the real `host:port`; everything else
(`namespace`, `raw_metric_prefix`, `metrics`) is identical.

### Invariant — every series must carry a group prefix

The Datadog check uses `metrics: [".*"]`, which ingests **every** series on the
endpoint. `raw_metric_prefix` only *strips* the prefix when present — **it does
not filter**. So the naming scheme above holds only because the `/metrics`
endpoint exposes **solely** yabeda-registered series, each carrying its
`puma_` / `sidekiq_` / `solid_queue_` group prefix:

- the gem registers only the `:puma`, `:sidekiq` and `:solid_queue` yabeda
  groups (no process, GC, or Ruby-runtime collectors);
- the exposition serves Yabeda's registry only — the Prometheus client's HTTP
  request collector (`http_*`) is **not** mounted on the exporter.

If an unprefixed series ever appeared on the endpoint, `metrics: [".*"]` would
ingest it **un-stripped** under the namespace (e.g. `puma.http_requests_total`).
**Do not** add cross-cutting metrics (process, runtime, HTTP request) to this
exporter, and do not mount the Prometheus Rack collector on it. If you ever need
such metrics, expose them on a separate endpoint with its own check rather than
polluting this one. Conversely, any new metric you *do* add to an existing group
is picked up automatically by `[".*"]` — no check change needed.

`spec/rails_pod_kit/metrics_invariant_spec.rb` guards this at both the registry
and the exposition level.

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

**SolidQueue — DB-wide queue state** (`namespace: solid_queue`):

| canonical Datadog metric | type | functional tags |
|---|---|---|
| `solid_queue.backlog` | gauge | `queue` |
| `solid_queue.latency_seconds` | gauge | `queue` |

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

## Sidekiq: scale-to-zero

Being an always-on singleton makes that same pod the right home for the
**sidekiq-cron poller**, which is what lets the worker fleet scale to zero.

sidekiq-cron installs its poller from inside `Sidekiq.configure_server`, so on
its own the schedule exists only while a Sidekiq server is alive. At zero
replicas nothing polls, nothing is enqueued, and nothing ever raises the queue
depth that would wake a worker back up — a closed loop that forces a permanent
floor of one replica just to keep a poller alive. Missed runs are not caught up
afterwards either: `reschedule_grace_period` (60s by default) discards any run
older than itself.

The poller has no such requirement of its own — `Sidekiq::Cron::Poller` is a
Redis-polling thread that runs in any process holding a Sidekiq config — so
`scheduler: true` hosts it here:

```ruby
RailsPodKit::GlobalExporter.run!(
  redis: { url: ENV['REDIS_URL'] },
  scheduler: true,
  schedule_file: File.expand_path('../config/schedule.yml', __dir__)
)
```

`schedule_file:`, `poll_interval:` and `reschedule_grace_period:` override
sidekiq-cron's defaults (`config/schedule.yml` resolved against the working
directory, polled every 30s, catching up runs at most 60s late);
`supervision_interval:` tunes the liveness check. `RailsPodKit::GlobalScheduler`
is usable on its own (`start!` / `stop!`) if the always-on process is something
other than the exporter.

> **Size `reschedule_grace_period` over your worst restart.** It is what makes
> restarting the *only* scheduling process free: below it a missed occurrence is
> caught up on the next poll, above it the run is skipped silently. sidekiq-cron
> defaults to 60s, which a node drain or an evicted pod can easily exceed —
> rolling updates are covered anyway, since a `maxSurge` overlap means there is
> no gap at all. Catching up is bounded, not repeated: `last_enqueue_time` in
> Redis still gates each occurrence to exactly one enqueue.
>
> This is the reason a singleton scheduler does **not** need to become an HA
> pair. A second replica is safe for the poller (same `zadd` lock) but doubles
> every metric series the pod publishes, and a `PodDisruptionBudget` on a
> single-replica Deployment stalls node drains rather than protecting anything.

The poller runs under `RailsPodKit::Supervisor` — the same supervising timer
that keeps the SolidQueue scheduler thread alive, since both share the failure
mode: the thread dies, the host process notices nothing, and the schedule stops
silently. The cron poller's own loop swallows StandardError, so a Redis blip
costs one skipped tick; the supervisor makes anything it does *not* catch a
skipped tick too.

> **Every schedule entry must declare `active_job: true`.** This process has no
> Rails, so it cannot resolve the job classes; sidekiq-cron then falls back to
> pushing a raw message, and only that flag makes the message an ActiveJob
> wrapper (naming the class as a *string*, which the worker resolves). Without it
> the job is pushed as a bare Sidekiq job and runs outside ActiveJob entirely.
> `start!` logs a warning naming any entry in that state. For the same reason the
> schedule file's ERB must not reach for Rails.

Leaving the workers' own poller in place is fine and costs nothing: enqueueing is
gated on a Redis `zadd` that exactly one caller wins — the same lock that already
lets multiple worker replicas coexist without double-firing. Both processes must
then read the *same* schedule file, though: `load_from_hash!` removes the
schedule-sourced jobs that are absent from the file it is given, so two processes
loading different files will delete each other's entries.

## SolidQueue: scale-to-zero

SolidQueue's executor has nothing to do while the queue is empty, so it is the
natural candidate for **scale-to-zero** autoscaling (KEDA, or an HPA). Two things
stand in the way, and the gem covers both. Everything here is opt-in; requiring
the gem alone changes nothing.

### 1. The scheduler has to move off the executor

With the executor at zero there is no scheduler, so nothing enqueues the
recurring and scheduled jobs that would wake one — the queue stays empty because
it is empty. A k8s CronJob can't take over either: it can't own **dynamic**
recurring tasks, the ones created and updated at runtime through
`SolidQueue.schedule_recurring_task`.

The fix is to run the *scheduler alone* on a process that is always on, and let
the executor be nothing but dispatcher + workers (`bin/jobs` with
`SOLID_QUEUE_SKIP_RECURRING=true`):

```ruby
# config/puma.rb — after_booted only runs in the real Puma process, never in a
# console, a rake task or the test suite.
after_booted { RailsPodKit::SolidQueue.start_scheduler! }
at_exit      { RailsPodKit::SolidQueue.stop_scheduler! }
```

This is deliberately **not** `plugin :solid_queue`. That one runs the full
supervisor, which forks and whose watchdog takes Puma down when the supervisor
exits — and a transient Postgres disconnect is enough to cause that
([rails/solid_queue#512](https://github.com/rails/solid_queue/issues/512)). Here
a DB blip at worst kills the scheduler thread; `RailsPodKit::Supervisor` — a
`Concurrent::TimerTask`, the same primitive SolidQueue supervises its own
processes with, and the same one that keeps the sidekiq-cron poller alive —
notices on the next tick and starts a fresh one, the process itself never
notices, and the scheduler re-registers on recovery.

Running it on every replica is safe: enqueues stay exactly-once via the unique
index on `solid_queue_recurring_executions (task_key, run_at)`. Static tasks come
from `config/recurring.yml` (honouring `SOLID_QUEUE_RECURRING_SCHEDULE`), dynamic
ones from the DB.

| option | default | meaning |
|---|---|---|
| `polling_interval` | `5` | how often the scheduler re-reads the dynamic tasks |
| `supervision_interval` | `5` | how often we check the scheduler thread is alive |
| `recurring_schedule_file` | `config/recurring.yml` | static task definitions; skipped when absent |

`start_scheduler!` is **not** gated on `enabled` — that switch owns the metrics
exporter, and an app may well want the scheduler with metrics off.
`scheduler_enabled` is the switch that does own it, shared with the sidekiq-cron
poller. Beyond that, what keeps it out of consoles and specs is *where* you call
it from.

### 2. Queue depth has to be visible

SolidQueue publishes no metrics, so the autoscaler and the dashboards have
nothing to read. `install_metrics!` adds two gauges, computed **at scrape time**
from the SolidQueue tables (a yabeda `collect` block — no background thread, no
cached snapshot):

```ruby
# config/initializers/rails_pod_kit.rb
RailsPodKit::SolidQueue.install_metrics!
```

| metric | meaning |
|---|---|
| `solid_queue_backlog` | how many jobs could be claimed right now, per `queue` |
| `solid_queue_latency_seconds` | how long the oldest of them has been waiting, per `queue` |

"Claimable right now" is ready executions **plus** scheduled ones whose time has
come — the dispatcher has only to move those across. A scheduled job's wait is
measured from its `scheduled_at`, not its `created_at`: enqueuing a week ahead of
the slot doesn't make it a week late.

Both matter, and neither alone is enough: backlog misses a small-but-stalled
queue, latency misses a large-but-moving one.

**An idle system reads 0, not no-data.** A queue that drains is explicitly zeroed
rather than left pinned at its last reading, and the zeroing starts from a
baseline of every queue the app is known to use — discovered once per process
from the jobs table, or pinned by the host:

```ruby
RailsPodKit::SolidQueue.install_metrics!(queues: %w[default mailers])
```

Without that baseline a process booting while the queue is empty — the steady
state of a scale-to-zero deployment — would publish no series at all, since a
gauge only exists once it has been set. Discovery is best-effort: the jobs table
is bounded by `clear_finished_jobs_after`, so a queue idle for longer than the
retention window leaves no trace in it. Pin `queues:` where the zero has to be
guaranteed.

**A collection error is always reported** (logged, plus handed to
`Rails.error`), then either swallowed or raised:

| | |
|---|---|
| `fail_scrape_on_error: false` (default) | serve the last reading. Right on an endpoint shared with the Puma or Sidekiq series, where failing the response would lose those too — at the cost of a stale gauge a consumer cannot tell apart from a live one. |
| `fail_scrape_on_error: true` (`run_exporter!`'s default) | fail the scrape. Right on the dedicated pod, where there is nothing else to protect: the gauges go to no-data and the scrape failure shows up in the scraper's own `up` series. |

### The always-on pod

The cleanest home for both is a **1-replica Deployment** that hosts the scheduler
and publishes the gauges, decoupled from the web and the executor — so the
signals survive either scaling to zero, and each series has exactly one source.
`run_exporter!` is that process: it declares the gauges, starts the scheduler,
serves `/metrics` and blocks until SIGTERM (winding the scheduler down so it
deregisters rather than expiring).

Unlike the Sidekiq global exporter it is **not** Rails-free — SolidQueue is
ActiveRecord-backed and reads the app's own tables — so the host's entrypoint
boots the environment first. The gem ships no executable; e.g.
`bin/solid-queue-pod`:

```ruby
#!/usr/bin/env ruby
require_relative '../config/environment'

RailsPodKit::SolidQueue.run_exporter!
```

```
command: ["bin/solid-queue-pod"]
```

Pass `scheduler: false` to serve the gauges only, on an app whose web process
already hosts the scheduler, and `metrics:` to override the gauge options (this
endpoint is the collector's own, so `fail_scrape_on_error` defaults to `true`
here):

```ruby
RailsPodKit::SolidQueue.run_exporter!(scheduler: false, metrics: { queues: %w[default mailers] })
```

Keep the endpoint single-prefix (see
[One prefix per endpoint](#datadog-naming--the-canonical-metric-set)) — that pod
serves `solid_queue_*` and nothing else, so the check config needs no filters.

## Caveats

- **Puma only.** The Puma plugins only activate under Puma; under any other
  app server the in-process `/metrics` endpoint is **not** exposed. The non-Puma
  entry points (Sidekiq, the global exporter, the SolidQueue pod) serve it from
  a WEBrick thread instead, started at most once per process.
- **SolidQueue and Sidekiq are the host's.** The gem depends on neither; the
  SolidQueue integration is inert until you call it, exactly like the Sidekiq one.
  `sidekiq-cron` too: it is required only when `GlobalScheduler.start!` is called,
  so an app that does not schedule anything need not carry it.
- **Queue-gauge query cost.** The gauges run four small grouped aggregates per
  scrape. `MIN(created_at)` is not covered by SolidQueue's indexes, so on a
  backlog of many thousands of rows it is a scan — cheap at a normal scrape
  interval, worth knowing about if you scrape aggressively.
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
  `Bundler.require` runs. The main file also loads the yabeda-prometheus-mmap
  adapter at require time — before any host initializer runs — so host
  initializers may declare Yabeda metrics (yabeda-rails, yabeda-activejob, a
  custom collector) safely: the adapter registers itself while no metric exists
  yet, regardless of whether the app boots via `bin/rails server` or
  `puma -C config/puma.rb`.

## Local verification

Boot each process with the exporter enabled and scrape `:9394/metrics`:

```bash
# Web (Puma): puma_* series
bundle exec rails server
curl -s localhost:9394/metrics | grep '^puma_'

# Worker (Sidekiq): sidekiq_* series (run a job first so per-process counters appear)
bundle exec sidekiq
curl -s localhost:9394/metrics | grep '^sidekiq_'

# SolidQueue: solid_queue_* series (enqueue a job first so the queue isn't empty)
bin/solid-queue-pod
curl -s localhost:9394/metrics | grep '^solid_queue_'

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
