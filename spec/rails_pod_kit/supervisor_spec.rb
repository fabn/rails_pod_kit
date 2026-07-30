# frozen_string_literal: true

require 'rails_pod_kit/supervisor'

RSpec.describe RailsPodKit::Supervisor do
  subject(:supervisor) do
    described_class.new(source: 'spec', interval: 5, start: start_worker, alive: alive, stop: stop_worker)
  end

  # A stand-in for a supervised background worker, recording every instance the
  # supervisor builds. `alive` is what it reads to decide whether to replace one.
  let(:worker_class) do
    Class.new do
      class << self
        attr_accessor :instances
      end
      self.instances = []

      attr_accessor :alive
      attr_reader :stops

      def initialize
        @alive = true
        @stops = 0
        self.class.instances << self
      end

      def stop = @stops += 1
    end
  end

  let(:workers) { worker_class.instances }
  let(:start_worker) { -> { worker_class.new } }
  let(:alive) { :alive }
  let(:stop_worker) { :stop }

  let(:timer) { instance_double(Concurrent::TimerTask, execute: nil, shutdown: nil) }
  # Captures the timer so examples drive its block by hand instead of waiting
  # out a real interval.
  let(:captured) { {} }

  before do
    allow(Concurrent::TimerTask).to receive(:new) do |**options, &block|
      captured.merge!(options: options, tick: block)
      timer
    end
  end

  def tick
    captured.fetch(:tick).call
  end

  describe '#start' do
    it 'supervises from the first tick, without waiting out an interval' do
      supervisor.start

      expect(captured[:options]).to include(run_now: true, execution_interval: 5)
      expect(timer).to have_received(:execute)
    end

    it 'builds the worker on that tick and exposes it' do
      supervisor.start
      tick

      expect(workers.size).to eq(1)
      expect(supervisor.subject).to eq(workers.first)
    end
  end

  describe 'supervision' do
    before { supervisor.start }

    it 'leaves a live worker alone' do
      tick
      tick

      expect(workers.size).to eq(1)
    end

    it 'replaces a worker that has stopped being alive' do
      tick
      workers.first.alive = false

      tick

      expect(workers.size).to eq(2)
      expect(supervisor.subject).to eq(workers.last)
    end

    it 'reports a worker that cannot start, and retries on the next tick' do
      error = StandardError.new('backing store is down')
      allow(RailsPodKit::ErrorReporter).to receive(:report)
      allow(start_worker).to receive(:call).and_raise(error)

      expect { tick }.to_not raise_error
      expect(RailsPodKit::ErrorReporter).to have_received(:report).with(error, source: 'spec')
    end
  end

  describe '#stop' do
    before { supervisor.start }

    it 'drops the timer before winding the worker down' do
      tick

      supervisor.stop

      expect(timer).to have_received(:shutdown)
      expect(workers.first.stops).to eq(1)
      expect(supervisor.subject).to be_nil
    end

    it 'ignores a tick that was already in flight' do
      tick
      supervisor.stop

      tick

      expect(workers.size).to eq(1)
    end

    it 'is a no-op when nothing was ever built' do
      expect { supervisor.stop }.to_not raise_error
    end

    it 'simply drops a worker with no teardown' do
      runner = described_class.new(source: 'spec', start: start_worker, alive: alive)
      runner.start
      tick

      runner.stop

      expect(workers.first.stops).to eq(0)
      expect(runner.subject).to be_nil
    end
  end

  describe 'the liveness hook' do
    it 'accepts a callable, for a worker that does not expose its own check' do
      probe = ->(worker) { !worker.alive }
      runner = described_class.new(source: 'spec', start: start_worker, alive: probe)
      runner.start
      tick

      # Inverted on purpose: the callable decides, not the worker.
      expect(runner.running?).to be(false)
    end
  end

  describe '#running?' do
    it 'is false before the first tick' do
      supervisor.start

      expect(supervisor.running?).to be(false)
    end

    it 'follows the worker once built' do
      supervisor.start
      tick

      expect(supervisor.running?).to be(true)

      workers.first.alive = false

      expect(supervisor.running?).to be(false)
    end
  end
end
