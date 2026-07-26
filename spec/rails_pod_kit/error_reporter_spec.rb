# frozen_string_literal: true

require 'rails_pod_kit/error_reporter'

RSpec.describe RailsPodKit::ErrorReporter do
  let(:error) { ArgumentError.new('boom') }
  let(:source) { 'rails_pod_kit.spec' }

  context 'without Rails' do
    it 'writes to stderr, the only channel a Rails-free process has' do
      expect { described_class.report(error, source: source) }
        .to output(/\[#{source}\] ArgumentError: boom/).to_stderr
    end
  end

  context 'with Rails' do
    let(:logger) { instance_double(Logger, error: nil) }
    let(:reporter) { instance_double(ActiveSupport::ErrorReporter, report: nil) }

    before { stub_const('Rails', double(logger: logger, error: reporter)) }

    it 'logs as well as reporting, so a swallowed error is never silent' do
      described_class.report(error, source: source)

      expect(logger).to have_received(:error).with("[#{source}] ArgumentError: boom")
      expect(reporter).to have_received(:report).with(error, handled: true, source: source)
    end
  end
end
