# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

require 'active_record'
require 'rails_pod_kit/solid_queue'

RSpec.describe RailsPodKit::SolidQueue::SchedulerRunner do
  subject(:runner) { described_class.new }

  # A stand-in for SolidQueue::Scheduler, recording every instance the runner
  # builds. `alive?` is what the supervisor reads to decide whether to (re)start
  # one, so each example can drive it.
  let(:scheduler_class) do
    Class.new do
      class << self
        attr_accessor :instances
      end
      self.instances = []

      attr_accessor :mode, :alive
      attr_reader :options, :starts, :stops

      def initialize(**options)
        @options = options
        @starts = 0
        @stops = 0
        @alive = true
        self.class.instances << self
      end

      def start = @starts += 1
      def stop = @stops += 1
      def alive? = @alive
    end
  end

  let(:timer) { instance_double(Concurrent::TimerTask, execute: nil, shutdown: nil) }
  # Captures the supervisor's timer so examples can drive its block by hand
  # instead of waiting on a real interval.
  let(:supervisor) { {} }

  before do
    stub_const('SolidQueue::Scheduler', scheduler_class)
    allow(Rails).to receive(:env).and_return('test')

    allow(Concurrent::TimerTask).to receive(:new) do |**options, &block|
      supervisor.merge!(options: options, tick: block)
      timer
    end
  end

  def tick
    supervisor.fetch(:tick).call
  end

  def schedulers
    scheduler_class.instances
  end

  def scheduler
    schedulers.last
  end

  describe '#start' do
    it 'supervises on an interval, starting the scheduler on the first tick' do
      runner.start

      expect(supervisor[:options]).to include(run_now: true,
                                              execution_interval: described_class::DEFAULT_SUPERVISION_INTERVAL)
      expect(timer).to have_received(:execute)
    end

    it 'runs a scheduler-only, dynamic-task-enabled scheduler in its own thread' do
      runner.start
      tick

      expect(scheduler.options).to include(dynamic_tasks_enabled: true,
                                           polling_interval: described_class::DEFAULT_POLLING_INTERVAL)
      expect(scheduler.mode).to eq(:async)
      expect(scheduler.starts).to eq(1)
      expect(runner).to be_running
    end

    it 'leaves a healthy scheduler alone on subsequent ticks' do
      runner.start
      3.times { tick }

      expect(schedulers.size).to eq(1)
      expect(scheduler.starts).to eq(1)
    end

    it 'starts a fresh scheduler once the thread has died (e.g. a Postgres blip)' do
      runner.start
      tick
      scheduler.alive = false

      tick

      expect(schedulers.size).to eq(2)
      expect(schedulers).to all(have_attributes(starts: 1))
    end

    it 'reports a scheduler that cannot start, and retries on the next tick' do
      allow(RailsPodKit::ErrorReporter).to receive(:report)
      allow(scheduler_class).to receive(:new).and_raise(ActiveRecord::ConnectionNotEstablished)
      runner.start

      expect { tick }.to_not raise_error

      expect(RailsPodKit::ErrorReporter).to have_received(:report)
        .with(instance_of(ActiveRecord::ConnectionNotEstablished), source: described_class::SOURCE)
    end
  end

  describe '#stop' do
    it 'drops the supervisor before winding the scheduler down, so it cannot come back' do
      runner.start
      tick

      runner.stop

      expect(timer).to have_received(:shutdown)
      expect(scheduler.stops).to eq(1)
      expect(runner).to_not be_running
    end

    it 'ignores a tick that was already in flight' do
      runner.start
      runner.stop

      tick

      expect(schedulers).to be_empty
    end
  end

  describe 'static recurring tasks' do
    subject(:runner) { described_class.new(recurring_schedule_file: recurring_path) }

    let(:recurring_yml) do
      <<~YAML
        production:
          cleanup:
            class: CleanupJob
            schedule: every hour
        test:
          periodic:
            class: PeriodicJob
            schedule: every 5 minutes
          not_a_task:
            class: NoScheduleJob
      YAML
    end

    let(:recurring_path) { File.join(Dir.mktmpdir('rails-pod-kit-spec'), 'recurring.yml') }

    before do
      stub_const('SolidQueue::RecurringTask', Class.new do
        def self.from_configuration(key, **options) = { key: key, **options }
      end)
      File.write(recurring_path, recurring_yml)
    end

    after { FileUtils.remove_entry(File.dirname(recurring_path)) }

    it "loads only the current environment's entries that define a schedule" do
      runner.start
      tick

      expect(scheduler.options[:recurring_tasks])
        .to eq([{ key: :periodic, class: 'PeriodicJob', schedule: 'every 5 minutes' }])
    end

    it 'runs with no static tasks at all when the app has no recurring.yml' do
      described_class.new(recurring_schedule_file: File.join(__dir__, 'nope.yml')).start
      tick

      expect(scheduler.options[:recurring_tasks]).to eq([])
    end
  end
end
