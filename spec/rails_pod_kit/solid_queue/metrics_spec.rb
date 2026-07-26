# frozen_string_literal: true

require 'active_record'

require 'rails_pod_kit/solid_queue'

# The gem declares no dependency on solid_queue (it's the host's, like Puma and
# Sidekiq), so the two ActiveRecord models the collector reads are stubbed here.
# What's under test is the arithmetic on top of them: what counts as claimable,
# where the wait started, and which series get zeroed.
RSpec.describe RailsPodKit::SolidQueue::Metrics do
  let(:now) { Time.utc(2026, 7, 26, 12, 0, 0) }
  let(:ready) { instance_double(ActiveRecord::Relation) }
  let(:scheduled) { instance_double(ActiveRecord::Relation) }
  let(:ready_rows) { {} }
  let(:scheduled_rows) { {} }
  let(:published) { [] }
  let(:known_queues) { [] }

  before do
    described_class.reset!

    stub_const('SolidQueue::ReadyExecution', Class.new { def self.all; end })
    stub_const('SolidQueue::ScheduledExecution', Class.new { def self.where(*); end })
    stub_const('SolidQueue::Job', Class.new { def self.distinct; end })
    allow(SolidQueue::ReadyExecution).to receive(:all).and_return(ready)
    allow(SolidQueue::ScheduledExecution).to receive(:where).and_return(scheduled)
    allow(SolidQueue::Job).to receive(:distinct).and_return(
      instance_double(ActiveRecord::Relation, pluck: known_queues)
    )

    allow(Time).to receive(:now).and_return(now)
    # Neither a real connection pool nor the global Yabeda registry belongs in a
    # unit spec: record what would have been published instead.
    allow(described_class).to receive(:with_connection).and_yield
    allow(described_class).to receive(:publish) do |queue, backlog:, latency:|
      published << { queue: queue, backlog: backlog, latency: latency }
    end

    stub_aggregates(ready, :created_at, ready_rows)
    stub_aggregates(scheduled, :scheduled_at, scheduled_rows)
  end

  # The install latch is process-global, and the examples below flip it with
  # `declare!` stubbed out. Left set, it would turn a later `install_metrics!`
  # into a no-op and the gauges would never reach the registry — which is what
  # the invariant spec's exposition example scrapes.
  after { described_class.reset! }

  # A plain method, not a subject: the drain example scrapes twice and needs the
  # second call to actually happen.
  def collect
    described_class.collect!
  end

  # Stubs the pair of grouped aggregates the collector runs per table, as
  # `.group(:queue_name).count` and `.group(:queue_name).minimum(column)` return
  # them.
  def stub_aggregates(relation, column, rows)
    grouped = instance_double(ActiveRecord::Relation)
    allow(relation).to receive(:group).with(:queue_name).and_return(grouped)
    allow(grouped).to receive(:count).and_return(rows.transform_values { |row| row[:count] })
    allow(grouped).to receive(:minimum).with(column).and_return(rows.transform_values { |row| row[:oldest] })
  end

  context 'with jobs waiting on two queues' do
    let(:ready_rows) do
      {
        'default' => { count: 3, oldest: now - 90 },
        'mailers' => { count: 1, oldest: now - 5 }
      }
    end

    it 'reports the backlog and the age of the oldest job per queue' do
      collect

      expect(published).to contain_exactly(
        { queue: 'default', backlog: 3, latency: 90.0 },
        { queue: 'mailers', backlog: 1, latency: 5.0 }
      )
    end
  end

  context 'with scheduled jobs whose time has come' do
    let(:ready_rows) { { 'default' => { count: 2, oldest: now - 10 } } }
    let(:scheduled_rows) { { 'default' => { count: 4, oldest: now - 30 } } }

    it 'counts them as backlog and measures their wait from scheduled_at' do
      collect

      expect(published).to contain_exactly(queue: 'default', backlog: 6, latency: 30.0)
    end

    it 'only looks at the ones already due' do
      collect

      expect(SolidQueue::ScheduledExecution).to have_received(:where).with(scheduled_at: ..now)
    end
  end

  context 'when a queue drains' do
    let(:ready_rows) { { 'default' => { count: 2, oldest: now - 10 } } }

    it 'zeroes the series instead of leaving the gauge pinned at its last value' do
      collect
      published.clear
      stub_aggregates(ready, :created_at, {})

      collect

      expect(published).to contain_exactly(queue: 'default', backlog: 0, latency: 0)
    end
  end

  context 'when the queue is empty' do
    let(:known_queues) { %w[default mailers] }

    it 'still publishes a zero for every queue the app is known to use' do
      collect

      expect(published).to contain_exactly(
        { queue: 'default', backlog: 0, latency: 0 },
        { queue: 'mailers', backlog: 0, latency: 0 }
      )
    end

    it 'discovers that baseline once, not on every scrape' do
      collect
      collect

      expect(SolidQueue::Job).to have_received(:distinct).once
    end

    it 'takes the baseline from the host when it pins one' do
      allow(described_class).to receive(:declare!)
      described_class.install!(queues: %w[critical])

      collect

      expect(published).to contain_exactly(queue: 'critical', backlog: 0, latency: 0)
      expect(SolidQueue::Job).to_not have_received(:distinct)
    end
  end

  context 'when the database is unreachable' do
    before do
      allow(described_class).to receive(:with_connection).and_raise(ActiveRecord::ConnectionNotEstablished)
      allow(RailsPodKit::ErrorReporter).to receive(:report)
    end

    it 'reports the error instead of failing an endpoint it shares with other groups' do
      expect { collect }.to_not raise_error

      expect(RailsPodKit::ErrorReporter).to have_received(:report)
        .with(instance_of(ActiveRecord::ConnectionNotEstablished), source: described_class::SOURCE)
    end

    it 'fails the scrape when it owns the endpoint, so the gauges go to no-data' do
      allow(described_class).to receive(:declare!)
      described_class.install!(fail_scrape_on_error: true)

      expect { collect }.to raise_error(ActiveRecord::ConnectionNotEstablished)

      expect(RailsPodKit::ErrorReporter).to have_received(:report)
    end

    # The pod boots the host's initializers — and their install_metrics! — before
    # run_exporter! gets to ask for this, so the second call has to be heard.
    it 'still takes the option when the app declared the gauges first' do
      allow(described_class).to receive(:declare!)
      described_class.install!
      described_class.install!(fail_scrape_on_error: true)

      expect { collect }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    end
  end
end
