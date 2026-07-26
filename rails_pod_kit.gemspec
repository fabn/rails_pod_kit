# frozen_string_literal: true

require_relative 'lib/rails_pod_kit/version'

Gem::Specification.new do |spec|
  spec.name        = 'rails_pod_kit'
  spec.version     = RailsPodKit::VERSION
  spec.authors     = ['Fabio Napoleoni']
  spec.email       = ['f.napoleoni@gmail.com']
  spec.summary     = 'Operational endpoints for Rails pods: Prometheus metrics (Puma, Sidekiq, SolidQueue) and health checks'
  spec.description = <<~DESC
    Packages the yabeda ecosystem and health-monitor-rails into a single,
    opinionated kit for running Rails applications on Kubernetes: Puma, Sidekiq
    and SolidQueue runtime metrics in Prometheus text format on an in-process
    /metrics endpoint (default port 9394), plus a /healthz endpoint wired for
    liveness/readiness/startup probes. No sidecar, no separate collector. For
    SolidQueue it also ships the supervised scheduler thread that lets the job
    executor scale to zero.
  DESC
  spec.homepage = 'https://github.com/fabn/rails_pod_kit'
  spec.license  = 'MIT'

  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata['source_code_uri']       = spec.homepage
  spec.metadata['changelog_uri']         = 'https://github.com/fabn/rails_pod_kit/releases'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb', 'VERSION', 'README.md', 'LICENSE.txt']
  spec.require_paths = ['lib']

  # --- yabeda ecosystem (pinned, coherent set) ---
  # Core in-process metrics registry.
  spec.add_dependency 'yabeda', '~> 0.16'
  # Sidekiq job + queue metrics (per-process and global/Redis-wide).
  spec.add_dependency 'yabeda-sidekiq', '~> 0.12'
  # Puma worker/thread-pool metrics + the `:yabeda` / `:yabeda_prometheus` Puma plugins.
  spec.add_dependency 'yabeda-puma-plugin', '~> 0.9'
  # Prometheus exporter (WEBrick metrics server), multiprocess-safe via prometheus-client-mmap.
  spec.add_dependency 'yabeda-prometheus-mmap', '~> 0.4'
  # HTTP server used by the Sidekiq in-process exporter.
  spec.add_dependency 'webrick', '~> 1.8'

  # Configuration backend: RAILS_POD_KIT_* env vars and optional YAML besides
  # the plain Ruby configure block.
  spec.add_dependency 'anyway_config', '~> 2.0'

  # TimerTask, which supervises the SolidQueue scheduler thread. Always present
  # transitively via ActiveSupport, but used directly here.
  spec.add_dependency 'concurrent-ruby', '~> 1.2'

  # --- health checks ---
  # /healthz probe endpoint (Rails engine), wrapped by RailsPodKit::Health.
  # Only loaded under Rails: the Rails-free global exporter never requires it.
  spec.add_dependency 'health-monitor-rails', '~> 12.8'
  # Builds the health-check connection when the host injects an options hash.
  spec.add_dependency 'redis', '~> 5.0'
end
