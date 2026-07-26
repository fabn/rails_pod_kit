# frozen_string_literal: true

require 'rails_pod_kit/exporter'
require 'yabeda/prometheus/mmap'

RSpec.describe RailsPodKit::Exporter do
  describe '.start!' do
    context 'when metrics are disabled (e.g. test env)' do
      before { RailsPodKit.configure { |c| c.enabled = false } }

      it 'does not bind a port' do
        expect(Yabeda::Prometheus::Exporter).to_not receive(:start_metrics_server!)

        expect(described_class.start!).to be(false)
      end
    end

    context 'when metrics are enabled' do
      before do
        RailsPodKit.configure { |c| c.enabled = true }
        allow(Yabeda::Prometheus::Exporter).to receive(:start_metrics_server!)
      end

      it 'starts the server only once, however many entry points ask for it' do
        expect(described_class.start!).to be(true)
        expect(described_class.start!).to be(false)

        expect(Yabeda::Prometheus::Exporter).to have_received(:start_metrics_server!).once
        expect(described_class).to be_started
      end

      it 'publishes the configured port for the exporter to bind' do
        ENV.delete('PROMETHEUS_EXPORTER_PORT')
        RailsPodKit.configure { |c| c.port = 9500 }

        described_class.start!

        expect(ENV.fetch('PROMETHEUS_EXPORTER_PORT')).to eq('9500')
      ensure
        ENV.delete('PROMETHEUS_EXPORTER_PORT')
      end
    end
  end
end
