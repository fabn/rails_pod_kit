# frozen_string_literal: true

require 'rails_pod_kit/puma'
require 'rails_pod_kit/sidekiq' # so RailsPodKit::Sidekiq exists for the :web stub

RSpec.describe RailsPodKit::Puma do
  # A stand-in for the Puma DSL config object (`self` in config/puma.rb). A plain
  # double keeps the gem spec isolated — Puma itself need not be loaded.
  let(:puma_config) do
    double('Puma::DSL', plugin: nil, activate_control_app: nil, on_prometheus_exporter_boot: nil,
                        prometheus_silence_logger: nil)
  end

  context 'when metrics are enabled' do
    # Pin the global-metrics policy away from the :web default in the plugin
    # tests so activate stays focused on Puma wiring; the :web branch has its
    # own example below.
    before do
      RailsPodKit.configure do |c|
        c.enabled = true
        c.port = 9394
        c.sidekiq_global_metrics = :all
      end
    end

    it 'activates both yabeda Puma plugins' do
      described_class.activate(puma_config)

      expect(puma_config).to have_received(:plugin).with(:yabeda)
      expect(puma_config).to have_received(:plugin).with(:yabeda_prometheus)
    end

    it 'silences the exporter per-scrape access log by default' do
      described_class.activate(puma_config)

      expect(puma_config).to have_received(:prometheus_silence_logger).with(true)
    end

    it 'leaves the exporter access log on when the flag is disabled' do
      RailsPodKit.configure { |c| c.silence_exporter_access_log = false }

      described_class.activate(puma_config)

      expect(puma_config).to_not have_received(:prometheus_silence_logger)
    end

    it 'activates a localhost-only Puma control app for the stats reader' do
      RailsPodKit.configure do |c|
        c.enabled = true
        c.puma_control_url = 'tcp://127.0.0.1:9293'
      end

      described_class.activate(puma_config)

      expect(puma_config).to have_received(:activate_control_app)
        .with('tcp://127.0.0.1:9293', no_token: true)
    end

    it 'exposes the configured port to the plugin via PROMETHEUS_EXPORTER_PORT' do
      ENV.delete('PROMETHEUS_EXPORTER_PORT')
      RailsPodKit.configure do |c|
        c.enabled = true
        c.port = 9555
      end

      described_class.activate(puma_config)

      expect(ENV.fetch('PROMETHEUS_EXPORTER_PORT')).to eq('9555')
    ensure
      ENV.delete('PROMETHEUS_EXPORTER_PORT')
    end
  end

  context 'when under the :web global-metrics policy (the default)' do
    before do
      RailsPodKit.configure do |c|
        c.enabled = true
        c.sidekiq_global_metrics = :web
      end
    end

    it 'enables Sidekiq global collection in the web process from the exporter-boot hook' do
      # Capture the deferred hook (it runs post-Rails-boot in the real app) and
      # run it with the configure! side effects stubbed.
      boot_hook = nil
      allow(puma_config).to receive(:on_prometheus_exporter_boot) { |&blk| boot_hook = blk }
      allow(RailsPodKit::Sidekiq).to receive(:enable_global_collection!)
      allow(Yabeda).to receive(:already_configured?).and_return(true)

      described_class.activate(puma_config)
      boot_hook.call

      expect(RailsPodKit::Sidekiq).to have_received(:enable_global_collection!)
    end
  end

  context 'when metrics are disabled' do
    before { RailsPodKit.configure { |c| c.enabled = false } }

    it 'is a complete no-op (no plugins activated)' do
      described_class.activate(puma_config)

      expect(puma_config).to_not have_received(:plugin)
    end
  end
end
