# frozen_string_literal: true

require 'rails_pod_kit/global_exporter'
require 'rails_pod_kit/sidekiq'
require 'yabeda/prometheus/mmap'

RSpec.describe RailsPodKit::GlobalExporter do
  let(:redis_options) { { url: 'redis://example:6379' } }

  describe '.install!' do
    it 'force-enables Sidekiq cluster collection' do
      allow(RailsPodKit::Sidekiq).to receive(:enable_global_collection!)

      described_class.install!

      expect(RailsPodKit::Sidekiq).to have_received(:enable_global_collection!)
    end
  end

  describe '.configure_redis!' do
    it 'configures the Sidekiq client with the injected redis options' do
      require 'sidekiq'
      config = double('sidekiq config')
      allow(config).to receive(:redis=)
      allow(Sidekiq).to receive(:configure_client).and_yield(config)

      described_class.configure_redis!(redis_options)

      expect(config).to have_received(:redis=).with(redis_options)
    end
  end

  describe '.run!' do
    context 'when disabled' do
      before { RailsPodKit.configure { |c| c.enabled = false } }

      it 'does not start the exporter' do
        expect(RailsPodKit::Sidekiq).to_not receive(:start_metrics_server!)

        described_class.run!(redis: redis_options)
      end
    end

    context 'when enabled' do
      before { RailsPodKit.configure { |c| c.enabled = true } }

      it 'configures redis, installs, starts the exporter, configures yabeda and blocks' do
        allow(described_class).to receive(:configure_redis!)
        allow(described_class).to receive(:install!)
        allow(RailsPodKit::Sidekiq).to receive(:start_metrics_server!)
        allow(Yabeda).to receive(:already_configured?).and_return(false)
        allow(Yabeda).to receive(:configure!)
        allow(described_class).to receive(:sleep) # don't actually block

        described_class.run!(redis: redis_options)

        expect(described_class).to have_received(:configure_redis!).with(redis_options)
        expect(described_class).to have_received(:install!)
        expect(RailsPodKit::Sidekiq).to have_received(:start_metrics_server!)
        expect(Yabeda).to have_received(:configure!)
        expect(described_class).to have_received(:sleep)
      end
    end
  end
end
