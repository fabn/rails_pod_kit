# frozen_string_literal: true

module RailsPodKit
  # Blocks the main thread of an always-on entry point until the orchestrator
  # signals. A self-pipe rather than a Queue or a Mutex: writing to an IO is one
  # of the few things safe to do from a trap handler.
  module Shutdown
    SIGNALS = %w[INT TERM].freeze

    module_function

    def await(signals: SIGNALS)
      reader, writer = IO.pipe
      signals.each { |signal| Signal.trap(signal) { writer.puts(signal) } }
      reader.gets
    end
  end
end
