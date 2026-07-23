# frozen_string_literal: true

RSpec.describe RailsPodKit::Config do
  describe 'defaults' do
    it 'defaults the port to 9394' do
      expect(RailsPodKit.config.port).to eq(9394)
    end

    it 'defaults the sidekiq global metrics policy to :web' do
      expect(RailsPodKit.config.sidekiq_global_metrics).to eq(:web)
    end

    it 'defaults retries_segmented_by_queue to false' do
      expect(RailsPodKit.config.retries_segmented_by_queue).to be(false)
    end

    it 'defaults silence_exporter_access_log to true' do
      expect(RailsPodKit.config.silence_exporter_access_log).to be(true)
    end

    it 'reads the port from PROMETHEUS_EXPORTER_PORT when set' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('PROMETHEUS_EXPORTER_PORT', RailsPodKit::DEFAULT_PORT).and_return('9999')

      expect(described_class.new.port).to eq(9999)
    end
  end

  describe 'anyway_config env source' do
    it 'reads settings from RAILS_POD_KIT_* variables' do
      ENV['RAILS_POD_KIT_PORT'] = '9777'
      ENV['RAILS_POD_KIT_SIDEKIQ_GLOBAL_METRICS'] = 'off'
      ENV['RAILS_POD_KIT_SILENCE_EXPORTER_ACCESS_LOG'] = 'false'

      config = described_class.new

      expect(config.port).to eq(9777)
      expect(config.sidekiq_global_metrics).to eq(:off)
      expect(config.silence_exporter_access_log).to be(false)
    ensure
      ENV.delete('RAILS_POD_KIT_PORT')
      ENV.delete('RAILS_POD_KIT_SIDEKIQ_GLOBAL_METRICS')
      ENV.delete('RAILS_POD_KIT_SILENCE_EXPORTER_ACCESS_LOG')
    end
  end

  describe '.default_enabled?' do
    it 'is disabled in the test environment' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('RAILS_ENV').and_return('test')
      allow(ENV).to receive(:[]).with('RACK_ENV').and_return(nil)

      expect(described_class.default_enabled?).to be(false)
    end

    it 'is enabled outside the test environment' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('RAILS_ENV').and_return('production')
      allow(ENV).to receive(:[]).with('RACK_ENV').and_return(nil)

      expect(described_class.default_enabled?).to be(true)
    end
  end
end

RSpec.describe RailsPodKit, '.configure' do
  it 'yields the config so the host app can override defaults' do
    described_class.configure do |c|
      c.enabled                = true
      c.port                   = 1234
      c.sidekiq_global_metrics = :off
    end

    expect(described_class.config.port).to eq(1234)
    expect(described_class.enabled?).to be(true)
    expect(described_class.config.sidekiq_global_metrics).to eq(:off)
  end

  it 'memoizes a single config instance' do
    memoized = described_class.config
    expect(described_class.config).to be(memoized)
  end
end
