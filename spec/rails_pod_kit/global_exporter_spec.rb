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
    before do
      allow(described_class).to receive(:configure_redis!)
      allow(described_class).to receive(:install!)
      allow(RailsPodKit::Sidekiq).to receive(:start_metrics_server!)
      allow(Yabeda).to receive(:already_configured?).and_return(false)
      allow(Yabeda).to receive(:configure!)
      allow(RailsPodKit::Shutdown).to receive(:await) # don't actually block
      allow(RailsPodKit::GlobalScheduler).to receive_messages(start!: nil, stop!: nil)
    end

    context 'when disabled' do
      before { RailsPodKit.configure { |c| c.enabled = false } }

      it 'does not start the exporter' do
        expect(RailsPodKit::Sidekiq).to_not receive(:start_metrics_server!)

        described_class.run!(redis: redis_options)
      end

      it 'returns instead of blocking on a process with nothing to do' do
        expect(RailsPodKit::Shutdown).to_not receive(:await)

        described_class.run!(redis: redis_options)
      end

      it 'still runs the scheduler, which that switch does not own' do
        described_class.run!(redis: redis_options, scheduler: true)

        expect(RailsPodKit::GlobalScheduler).to have_received(:start!)
        expect(RailsPodKit::Shutdown).to have_received(:await)
      end
    end

    context 'when enabled' do
      before { RailsPodKit.configure { |c| c.enabled = true } }

      it 'configures redis, installs, starts the exporter, configures yabeda and blocks' do
        described_class.run!(redis: redis_options)

        expect(described_class).to have_received(:configure_redis!).with(redis_options)
        expect(described_class).to have_received(:install!)
        expect(RailsPodKit::Sidekiq).to have_received(:start_metrics_server!)
        expect(Yabeda).to have_received(:configure!)
        expect(RailsPodKit::Shutdown).to have_received(:await)
      end

      it 'leaves the scheduler off by default' do
        described_class.run!(redis: redis_options)

        expect(RailsPodKit::GlobalScheduler).to_not have_received(:start!)
      end

      it 'runs the cron poller alongside it, and winds it down on shutdown' do
        described_class.run!(redis: redis_options, scheduler: true, poll_interval: 5)

        expect(RailsPodKit::GlobalScheduler).to have_received(:start!).with(poll_interval: 5)
        expect(RailsPodKit::GlobalScheduler).to have_received(:stop!)
      end
    end
  end
end
