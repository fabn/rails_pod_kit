# frozen_string_literal: true

require 'tmpdir'
require 'rack/test'

require 'yabeda'
require 'yabeda/sidekiq'
require 'yabeda/prometheus/mmap'

# The Puma metrics live inside the yabeda-puma-plugin's `start` hook, so we drive
# the real plugin to register them rather than duplicating its metric list.
require 'puma'
require 'puma/plugin'
require 'puma/plugin/yabeda'

# Guards the "prefix-pure endpoint" invariant the Datadog OpenMetrics check
# depends on (README "Invariant"): the :9394
# endpoint must expose *only* yabeda-registered `puma_*` / `sidekiq_*` series.
# `raw_metric_prefix` only strips the prefix, it does not filter, so any
# unprefixed series leaking onto the endpoint would be ingested un-stripped under
# the namespace (e.g. `puma.http_requests_total`).
RSpec.describe 'rails_pod_kit /metrics endpoint invariant' do
  # Only yabeda-registered puma_* / sidekiq_* series may appear on the endpoint.
  let(:prefix_pure) { /\A(puma|sidekiq)_/ }

  # Register the full Puma + Sidekiq metric set into the global Yabeda registry
  # once, mirroring a real boot. Both yabeda-sidekiq flags are forced on so the
  # per-process *and* the cluster gauges are declared (they default to
  # `Sidekiq.server?`, which is false under the specs). Yabeda is a process-wide
  # singleton configured at most once, so this guard makes it a no-op once a
  # previous example (in this run) has already driven it.
  before do
    unless Yabeda.already_configured?
      Yabeda::Sidekiq.config.declare_process_metrics = true
      Yabeda::Sidekiq.config.collect_cluster_metrics = true
      Yabeda::Sidekiq.config.retries_segmented_by_queue = false

      puma_plugin = Puma::Plugins.find('yabeda').new
      launcher = Struct.new(:options).new(
        { control_url: 'tcp://127.0.0.1:9293', control_auth_token: nil, workers: 0 }
      )
      puma_plugin.start(launcher)

      Yabeda.configure!
    end
  end

  describe 'registry level' do
    it 'registers metrics only in the :puma and :sidekiq groups' do
      expect(Yabeda.metrics).to_not be_empty

      aggregate_failures do
        Yabeda.metrics.each do |prometheus_name, metric|
          expect(%i[puma sidekiq]).to include(metric.group),
                                      "#{prometheus_name} is in unexpected group #{metric.group.inspect}"
          expect(prometheus_name).to match(prefix_pure)
        end
      end
    end
  end

  describe 'exposition level' do
    include Rack::Test::Methods

    # The exporter's own rack_app — the same Rack stack the in-process server
    # mounts. It serves Yabeda's registry only; the Prometheus Rack `http_*`
    # collector is deliberately not mounted on it (that wiring lives upstream in
    # yabeda-prometheus-mmap, so this spec doubles as an upstream-regression
    # canary).
    let(:app) { Yabeda::Prometheus::Mmap::Exporter.rack_app }

    around do |example|
      Dir.mktmpdir('rails-pod-kit-spec') do |dir|
        previous = ENV['prometheus_multiproc_dir']
        ENV['prometheus_multiproc_dir'] = dir
        Prometheus::Client.configuration.multiprocess_files_dir = dir
        example.run
      ensure
        ENV['prometheus_multiproc_dir'] = previous
      end
    end

    before do
      # The real collectors read the Puma control socket and Redis, neither of
      # which exists here. Stub the scrape-time collection and write one sample
      # per metric to the mmap store so the exposition renders the full series.
      allow(Yabeda).to receive(:collect!)
      write_sample_per_metric
    end

    it 'serves only puma_* / sidekiq_* series' do
      get '/metrics'

      expect(last_response).to be_ok
      names = metric_names(last_response.body)
      expect(names).to_not be_empty

      aggregate_failures do
        expect(names).to all(match(prefix_pure))
      end
    end

    # Sets a representative value on every registered metric so the multiprocess
    # text format (which renders from the on-disk mmap files, not the in-memory
    # registry) emits a line for each series.
    def write_sample_per_metric
      Yabeda.metrics.each_value do |metric|
        labels = metric.tags.to_h { |tag| [tag, 'spec'] }
        case metric
        when Yabeda::Counter   then metric.increment(labels, by: 1)
        when Yabeda::Histogram then metric.measure(labels, 0.1)
        else                        metric.set(labels, 1) # Gauge
        end
      end
    end

    # Every metric name in the Prometheus exposition: the `# TYPE` declarations
    # plus the bare series name leading each sample line (histogram `_bucket` /
    # `_sum` / `_count` suffixes included).
    def metric_names(body)
      body.each_line.flat_map do |line|
        if line.start_with?('# TYPE ')
          line.split[2]
        elsif line.start_with?('#') || line.strip.empty?
          []
        else
          [line[/\A[a-zA-Z_:][a-zA-Z0-9_:]*/]]
        end
      end.compact.uniq
    end
  end
end
