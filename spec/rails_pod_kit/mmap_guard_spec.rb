# frozen_string_literal: true

require 'rails_pod_kit/mmap_guard'

RSpec.describe RailsPodKit::MmapGuard do
  describe '.broken_serialization?' do
    # The suite itself runs on a combination that works — the appraisals pin
    # json 2.x where ActiveSupport still passes quirks_mode — so the healthy
    # case is the live one and the broken case has to be staged.
    it 'is false when to_json accepts the encoder ActiveSupport hands it' do
      expect(described_class.broken_serialization?).to be(false)
    end

    it 'is true when to_json rejects a keyword, as json 3 does with quirks_mode' do
      allow_any_instance_of(Array).to receive(:to_json)
        .and_raise(ArgumentError, 'unknown keyword: quirks_mode')

      expect(described_class.broken_serialization?).to be(true)
    end

    # Only the keyword rejection means this bug. Anything else is a real
    # failure that must not be swallowed and mislabelled.
    it 'lets an unrelated error through' do
      allow_any_instance_of(Array).to receive(:to_json).and_raise(NoMethodError, 'boom')

      expect { described_class.broken_serialization? }.to raise_error(NoMethodError)
    end
  end

  describe '.check!' do
    it 'stays quiet on a healthy stack' do
      expect(described_class).to_not receive(:warn)

      described_class.check!
    end

    it 'warns once when there is no Rails logger to use' do
      allow(described_class).to receive_messages(broken_serialization?: true, logger: nil)

      expect(described_class).to receive(:warn).with(described_class::MESSAGE).once

      described_class.check!
    end

    it 'prefers the Rails logger when there is one' do
      logger = instance_double(Logger)
      allow(described_class).to receive_messages(broken_serialization?: true, logger: logger)

      expect(logger).to receive(:warn).with(described_class::MESSAGE)

      described_class.check!
    end
  end
end
