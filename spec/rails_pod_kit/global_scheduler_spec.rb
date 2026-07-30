# frozen_string_literal: true

require 'rails_pod_kit/global_scheduler'
require 'sidekiq'
require 'sidekiq-cron'

RSpec.describe RailsPodKit::GlobalScheduler do
  let(:poller) { instance_double(Sidekiq::Cron::Poller, start: nil, terminate: nil) }
  let(:timer) { instance_double(Concurrent::TimerTask, execute: nil, shutdown: nil) }
  # Captures the supervisor's timer so examples drive its block by hand instead
  # of waiting on a real interval.
  let(:supervisor) { {} }

  before do
    described_class.stop!
    Sidekiq::Cron.reset!

    allow(Concurrent::TimerTask).to receive(:new) do |**options, &block|
      supervisor.merge!(options: options, tick: block)
      timer
    end
  end

  after { described_class.stop! }

  def tick
    supervisor.fetch(:tick).call
  end

  describe '.start!' do
    before { allow(described_class).to receive_messages(load_schedule!: nil, build_poller: poller) }

    it 'starts the cron poller from the supervisor tick' do
      described_class.start!
      tick

      expect(poller).to have_received(:start)
      expect(described_class.poller).to eq(poller)
    end

    it 'supervises from the first tick, without waiting out an interval' do
      described_class.start!

      expect(supervisor[:options]).to include(run_now: true, execution_interval: described_class::DEFAULT_SUPERVISION_INTERVAL)
      expect(timer).to have_received(:execute)
    end

    it 'is idempotent — a second call does not build a second supervisor' do
      described_class.start!
      described_class.start!

      expect(Concurrent::TimerTask).to have_received(:new).once
    end

    it 'applies the schedule file and poll interval overrides' do
      described_class.start!(schedule_file: 'config/cron.yml', poll_interval: 5)

      expect(Sidekiq::Cron.configuration.cron_schedule_file).to eq('config/cron.yml')
      expect(Sidekiq::Cron.configuration.cron_poll_interval).to eq(5)
    end

    it 'leaves sidekiq-cron defaults alone when nothing is overridden' do
      described_class.start!

      expect(Sidekiq::Cron.configuration.cron_schedule_file).to eq('config/schedule.yml')
      expect(Sidekiq::Cron.configuration.cron_poll_interval).to eq(30)
    end
  end

  describe '.stop!' do
    before { allow(described_class).to receive_messages(load_schedule!: nil, build_poller: poller) }

    it 'drops the supervisor, terminates the poller and forgets it' do
      described_class.start!
      tick

      described_class.stop!

      expect(timer).to have_received(:shutdown)
      expect(poller).to have_received(:terminate)
      expect(described_class.poller).to be_nil
    end

    it 'is a no-op when nothing is running' do
      expect { described_class.stop! }.to_not raise_error
    end
  end

  describe 'supervision' do
    before { allow(described_class).to receive_messages(load_schedule!: nil, build_poller: poller) }

    it 'leaves a live poller alone' do
      described_class.start!
      tick
      allow(described_class).to receive(:poller_alive?).and_return(true)

      tick

      expect(poller).to have_received(:start).once
    end

    it 'replaces a poller whose thread has died' do
      described_class.start!
      tick
      allow(described_class).to receive(:poller_alive?).and_return(false)

      tick

      expect(poller).to have_received(:start).twice
    end

    it 'reports a poller that cannot start, and retries on the next tick' do
      error = StandardError.new('redis is down')
      allow(described_class).to receive(:build_poller).and_raise(error)
      allow(RailsPodKit::ErrorReporter).to receive(:report)
      described_class.start!

      expect { tick }.to_not raise_error
      expect(RailsPodKit::ErrorReporter).to have_received(:report).with(error, source: described_class::SOURCE)
    end

    it 'does not resurrect the poller once stopped' do
      described_class.start!
      tick
      described_class.stop!

      tick

      expect(poller).to have_received(:start).once
    end
  end

  describe '.poller_alive?' do
    it 'is false before anything is started' do
      expect(described_class.poller_alive?).to be(false)
    end

    it 'follows the poller thread once started' do
      allow(described_class).to receive_messages(load_schedule!: nil, build_poller: poller)
      described_class.start!
      tick
      poller.instance_variable_set(:@thread, instance_double(Thread, alive?: false))

      expect(described_class.poller_alive?).to be(false)
    end

    it 'assumes alive when the poller does not expose a thread ivar' do
      allow(described_class).to receive_messages(load_schedule!: nil, build_poller: poller)
      described_class.start!
      tick

      expect(described_class.poller_alive?).to be(true)
    end
  end

  describe '.build_poller' do
    it 'publishes the cron poll settings the poller reads back out of the Sidekiq config' do
      Sidekiq::Cron.configure { |cron| cron.cron_poll_interval = 7 }

      described_class.build_poller

      expect(Sidekiq.default_configuration[:cron_poll_interval]).to eq(7)
      # Pinned: the inherited default counts live Sidekiq servers, not pollers.
      expect(Sidekiq.default_configuration[:cron_poll_process_count]).to eq(1)
    end
  end

  describe '.load_schedule!' do
    let(:loader) { instance_double(Sidekiq::Cron::ScheduleLoader) }

    before { allow(Sidekiq::Cron::ScheduleLoader).to receive(:new).and_return(loader) }

    it 'loads the schedule sidekiq-cron would only load in a Sidekiq server' do
      allow(loader).to receive_messages(has_schedule_file?: true, load_schedule: nil)
      allow(described_class).to receive(:warn_unresolvable_entries!)

      described_class.load_schedule!

      expect(loader).to have_received(:load_schedule)
    end

    it 'does nothing when the host has no schedule file' do
      allow(loader).to receive(:has_schedule_file?).and_return(false)

      expect(loader).to_not receive(:load_schedule)

      described_class.load_schedule!
    end

    it 'honours sidekiq-cron being disabled' do
      Sidekiq::Cron.configure { |cron| cron.enabled = false }

      expect(Sidekiq::Cron::ScheduleLoader).to_not receive(:new)

      described_class.load_schedule!
    end
  end

  describe '.warn_unresolvable_entries!' do
    let(:logger) { instance_double(Logger, warn: nil) }

    def cron_job(name, active_job:, klass: 'NotDefinedAnywhere')
      instance_double(Sidekiq::Cron::Job, name: name, klass: klass, to_hash: { active_job: active_job ? '1' : '0' })
    end

    before { allow(Sidekiq).to receive(:logger).and_return(logger) }

    it 'warns about entries that would be enqueued as bare Sidekiq jobs' do
      allow(Sidekiq::Cron::Job).to receive(:all).and_return([cron_job('Nightly', active_job: false)])

      described_class.warn_unresolvable_entries!

      expect(logger).to have_received(:warn)
    end

    it 'stays quiet for entries declaring active_job' do
      allow(Sidekiq::Cron::Job).to receive(:all).and_return([cron_job('Nightly', active_job: true)])

      described_class.warn_unresolvable_entries!

      expect(logger).to_not have_received(:warn)
    end

    it 'stays quiet for entries whose class this process can resolve' do
      allow(Sidekiq::Cron::Job).to receive(:all).and_return([cron_job('Nightly', active_job: false, klass: 'String')])

      described_class.warn_unresolvable_entries!

      expect(logger).to_not have_received(:warn)
    end
  end
end
