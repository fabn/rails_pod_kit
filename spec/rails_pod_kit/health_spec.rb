# frozen_string_literal: true

require 'rails_pod_kit/health'

RSpec.describe RailsPodKit::Health do
  # HealthMonitor memoizes its configuration process-wide (and Health keeps the
  # auto-mount latch); start each example from a clean slate.
  before do
    HealthMonitor.configuration = nil
    described_class.instance_variable_set(:@auto_mount, nil)
  end

  after { HealthMonitor.configuration = nil }

  def provider(name)
    HealthMonitor.configuration.providers.find { |p| p.class.name.demodulize == name }
  end

  def provider_names
    HealthMonitor.configuration.providers.map { |p| p.class.name.demodulize }
  end

  describe '.install!' do
    it 'configures the :healthz path and the database/cache/redis providers' do
      described_class.install!(redis: { url: 'redis://example:6379/1' }, silence_controller_log: false)

      expect(HealthMonitor.configuration.path).to eq(:healthz)
      expect(provider_names).to contain_exactly('Database', 'Cache', 'Redis')
    end

    it 'builds the redis connection from the host-injected options hash' do
      described_class.install!(redis: { url: 'redis://example:6379/1' }, silence_controller_log: false)

      expect(provider('Redis').configuration.connection).to be_a(Redis)
    end

    it 'passes a ready connection object through untouched' do
      connection = Object.new

      described_class.install!(redis: connection, silence_controller_log: false)

      expect(provider('Redis').configuration.connection).to be(connection)
    end

    it 'adds the sidekiq provider with the given thresholds only when asked' do
      described_class.install!(
        redis: { url: 'redis://example:6379/1' },
        sidekiq: { queue_size: 200, latency: 600 },
        silence_controller_log: false
      )

      expect(provider('Sidekiq')).to_not be_nil
      expect(provider('Sidekiq').configuration.queue_size).to eq(200)
      expect(provider('Sidekiq').configuration.latency).to eq(600)
    end

    it 'supports a custom endpoint path' do
      described_class.install!(redis: { url: 'redis://example:6379/1' }, path: :health,
                               silence_controller_log: false)

      expect(HealthMonitor.configuration.path).to eq(:health)
    end

    it 'turns on the railtie auto-mount by default' do
      expect { described_class.install!(redis: { url: 'redis://example:6379/1' }, silence_controller_log: false) }
        .to change(described_class, :auto_mount?).from(false).to(true)
    end

    it 'keeps route ownership with the host when mount is opted out' do
      described_class.install!(redis: { url: 'redis://example:6379/1' }, mount: false,
                               silence_controller_log: false)

      expect(described_class.auto_mount?).to be(false)
    end

    it 'yields the HealthMonitor configuration for host-specific tuning' do
      yielded = nil

      described_class.install!(redis: { url: 'redis://example:6379/1' }, silence_controller_log: false) do |config|
        yielded = config
      end

      expect(yielded).to be(HealthMonitor.configuration)
    end
  end
end
