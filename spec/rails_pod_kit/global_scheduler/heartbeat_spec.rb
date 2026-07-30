# frozen_string_literal: true

require 'rails_pod_kit/global_scheduler/heartbeat'
require 'yabeda'

RSpec.describe RailsPodKit::GlobalScheduler::Heartbeat do
  after { described_class.stop! }

  describe '.age' do
    it 'is nil before the heartbeat is started, so the series stays off processes with no poller' do
      described_class.stop!

      expect(described_class.age).to be_nil
    end

    it 'measures from the start until the first tick, so a poller that never ran climbs' do
      described_class.start!

      expect(described_class.age).to be >= 0
    end

    it 'measures from the last completed tick once there is one' do
      allow(described_class).to receive(:monotonic_now).and_return(100.0)
      described_class.start!
      allow(described_class).to receive(:monotonic_now).and_return(150.0)
      described_class.record!
      allow(described_class).to receive(:monotonic_now).and_return(160.0)

      expect(described_class.age).to eq(10.0)
    end

    it 'is monotonic, so a wall-clock step cannot read as a stalled schedule' do
      expect(described_class).to receive(:monotonic_now).at_least(:once).and_call_original

      described_class.start!
      described_class.age
    end

    it 'drops back to nil once stopped' do
      described_class.start!

      described_class.stop!

      expect(described_class.age).to be_nil
    end

    it 'forgets the previous tick when restarted' do
      described_class.start!
      described_class.record!

      described_class.stop!
      allow(described_class).to receive(:monotonic_now).and_return(500.0)
      described_class.start!
      allow(described_class).to receive(:monotonic_now).and_return(520.0)

      expect(described_class.age).to eq(20.0)
    end
  end

  describe '.install!' do
    it 'declares the gauge in the sidekiq group' do
      described_class.install!
      Yabeda.configure! unless Yabeda.already_configured?

      # The registry key carries no unit — the `_seconds` suffix on the exposed
      # series is the Prometheus adapter's doing (see the invariant spec).
      expect(Yabeda.metrics).to include('sidekiq_cron_poll_age')
    end

    it 'is one-shot' do
      described_class.install!

      expect(described_class.install!).to be(false)
    end
  end
end
