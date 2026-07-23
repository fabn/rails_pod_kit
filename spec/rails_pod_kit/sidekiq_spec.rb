# frozen_string_literal: true

require 'rails_pod_kit/sidekiq'
# Preload the yabeda constants so they can be stubbed even on the disabled path,
# where install! returns before requiring them.
require 'yabeda/sidekiq'
require 'yabeda/prometheus/mmap'

RSpec.describe RailsPodKit::Sidekiq do
  before do
    # Reset the "exporter already started" latch between examples.
    described_class.instance_variable_set(:@server_started, nil)
  end

  context 'when metrics are disabled (e.g. test env)' do
    before { RailsPodKit.configure { |c| c.enabled = false } }

    it 'does not start the exporter / bind a port' do
      expect(Yabeda::Prometheus::Exporter).to_not receive(:start_metrics_server!)

      described_class.install!(nil)
    end
  end

  context 'when metrics are enabled' do
    before do
      RailsPodKit.configure do |c|
        c.enabled = true
        c.port = 9394
      end
      allow(Yabeda::Prometheus::Exporter).to receive(:start_metrics_server!)
    end

    it 'starts the in-process exporter exactly once even if called twice' do
      described_class.install!(nil)
      described_class.install!(nil)

      expect(Yabeda::Prometheus::Exporter).to have_received(:start_metrics_server!).once
    end

    it 'silences the WEBrick exporter per-scrape access log by default' do
      ENV.delete('PROMETHEUS_EXPORTER_LOG_REQUESTS')

      described_class.start_metrics_server!

      expect(ENV.fetch('PROMETHEUS_EXPORTER_LOG_REQUESTS')).to eq('false')
    ensure
      ENV.delete('PROMETHEUS_EXPORTER_LOG_REQUESTS')
    end

    it 'leaves the access log on when the flag is disabled' do
      ENV.delete('PROMETHEUS_EXPORTER_LOG_REQUESTS')
      RailsPodKit.configure { |c| c.silence_exporter_access_log = false }

      described_class.start_metrics_server!

      expect(ENV.key?('PROMETHEUS_EXPORTER_LOG_REQUESTS')).to be(false)
    ensure
      ENV.delete('PROMETHEUS_EXPORTER_LOG_REQUESTS')
    end

    describe 'global metrics policy (worker side)' do
      it 'keeps the worker collecting cluster metrics under :all' do
        RailsPodKit.configure { |c| c.sidekiq_global_metrics = :all }

        described_class.install!(nil)

        expect(Yabeda::Sidekiq.config.collect_cluster_metrics).to be(true)
      end

      it 'stops the worker collecting cluster metrics under :web (web is the source)' do
        Yabeda::Sidekiq.config.collect_cluster_metrics = true
        RailsPodKit.configure { |c| c.sidekiq_global_metrics = :web }

        described_class.install!(nil)

        expect(Yabeda::Sidekiq.config.collect_cluster_metrics).to be(false)
      end

      it 'disables cluster metrics everywhere under :off' do
        Yabeda::Sidekiq.config.collect_cluster_metrics = true
        RailsPodKit.configure { |c| c.sidekiq_global_metrics = :off }

        described_class.install!(nil)

        expect(Yabeda::Sidekiq.config.collect_cluster_metrics).to be(false)
      end
    end

    describe 'retries_segmented_by_queue' do
      it 'leaves the retry gauge global by default' do
        Yabeda::Sidekiq.config.retries_segmented_by_queue = true

        described_class.install!(nil)

        expect(Yabeda::Sidekiq.config.retries_segmented_by_queue).to be(false)
      end

      it 'segments the retry gauge by queue when opted in' do
        RailsPodKit.configure { |c| c.retries_segmented_by_queue = true }

        described_class.install!(nil)

        expect(Yabeda::Sidekiq.config.retries_segmented_by_queue).to be(true)
      end
    end
  end

  describe '.enable_global_collection!' do
    it 'force-enables cluster collection and disables per-process declarations' do
      Yabeda::Sidekiq.config.collect_cluster_metrics = false
      Yabeda::Sidekiq.config.declare_process_metrics = true

      described_class.enable_global_collection!

      expect(Yabeda::Sidekiq.config.collect_cluster_metrics).to be(true)
      expect(Yabeda::Sidekiq.config.declare_process_metrics).to be(false)
    end

    it 'segments the retry gauge by queue when opted in' do
      RailsPodKit.configure { |c| c.retries_segmented_by_queue = true }

      described_class.enable_global_collection!

      expect(Yabeda::Sidekiq.config.retries_segmented_by_queue).to be(true)
    end
  end
end
