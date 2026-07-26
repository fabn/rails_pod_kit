# frozen_string_literal: true

require 'rails_pod_kit/solid_queue'
require 'yabeda/prometheus/mmap'

RSpec.describe RailsPodKit::SolidQueue do
  let(:runner) { instance_double(RailsPodKit::SolidQueue::SchedulerRunner, stop: nil) }

  before do
    allow(RailsPodKit::SolidQueue::SchedulerRunner).to receive(:new).and_return(runner)
    allow(runner).to receive(:start).and_return(runner)
    described_class.stop_scheduler!
  end

  after { described_class.stop_scheduler! }

  describe '.start_scheduler!' do
    it 'starts one scheduler per process, however many times it is called' do
      expect(described_class.start_scheduler!).to be(runner)
      expect(described_class.start_scheduler!).to be(runner)

      expect(RailsPodKit::SolidQueue::SchedulerRunner).to have_received(:new).once
    end

    it 'passes the tuning through to the runner' do
      described_class.start_scheduler!(polling_interval: 30)

      expect(RailsPodKit::SolidQueue::SchedulerRunner).to have_received(:new).with(polling_interval: 30)
    end

    it 'runs regardless of the metrics master switch — it is not an exporter' do
      RailsPodKit.configure { |c| c.enabled = false }

      described_class.start_scheduler!

      expect(runner).to have_received(:start)
    end
  end

  describe '.stop_scheduler!' do
    it 'winds the runner down and forgets it, so a later start gets a fresh one' do
      described_class.start_scheduler!

      described_class.stop_scheduler!
      described_class.start_scheduler!

      expect(runner).to have_received(:stop).once
      expect(RailsPodKit::SolidQueue::SchedulerRunner).to have_received(:new).twice
    end
  end

  describe '.run_exporter!' do
    before do
      allow(described_class).to receive(:install_metrics!)
      allow(described_class).to receive(:await_shutdown)
      allow(RailsPodKit::Exporter).to receive(:start!).and_return(true)
      allow(Yabeda).to receive(:already_configured?).and_return(false)
      allow(Yabeda).to receive(:configure!)
    end

    it 'declares the gauges, runs the scheduler, serves /metrics and blocks until SIGTERM' do
      described_class.run_exporter!

      expect(described_class).to have_received(:install_metrics!)
      expect(runner).to have_received(:start)
      expect(RailsPodKit::Exporter).to have_received(:start!)
      expect(Yabeda).to have_received(:configure!)
      expect(described_class).to have_received(:await_shutdown)
    end

    it 'stops the scheduler on the way out so it deregisters instead of expiring' do
      described_class.run_exporter!

      expect(runner).to have_received(:stop)
    end

    it 'serves the gauges alone when the scheduler lives elsewhere' do
      described_class.run_exporter!(scheduler: false)

      expect(RailsPodKit::SolidQueue::SchedulerRunner).to_not have_received(:new)
      expect(RailsPodKit::Exporter).to have_received(:start!)
    end
  end
end
