# frozen_string_literal: true

module RailsPodKit
  # Detects the one dependency combination that makes this gem's headline
  # feature fail without saying so.
  #
  # prometheus-client-mmap builds each metric's mmap key with `to_json`
  # (MmapedValue#rebuild_key). Under Rails that is ActiveSupport's encoder, and
  # up to ActiveSupport 8.0 it calls `JSON.generate(..., quirks_mode: true)` —
  # a keyword json 3.0 removed. The ArgumentError never reaches the host:
  # prometheus-client-mmap catches it in UsesValueType#value_object, logs at
  # INFO and falls back to SimpleValue. The value then lives in the recording
  # process's own memory instead of the shared mmap file, so the multiprocess
  # exposition this gem serves renders empty or partial. Nothing raises,
  # /metrics still answers 200, and the only symptom is series quietly going
  # missing from the dashboards.
  #
  # Neither half is ours to fix. ActiveSupport 8.1 dropped the option and no
  # 8.0.x patch backports it, so the escapes are json 2.x or Rails 8.1. And the
  # constraint cannot go in the gemspec: a dependency there is unconditional,
  # so `json < 3` would hold back hosts on Rails 8.1+ that have no problem, on
  # a default gem the whole bundle touches. What is left is to notice, and say
  # so once, at boot.
  #
  # The Rails-free global exporter cannot hit this: without ActiveSupport's
  # core ext, `to_json` is plain JSON and takes no `quirks_mode`. Hence the
  # check hangs off the Railtie.
  module MmapGuard
    MESSAGE = '[rails_pod_kit] activesupport < 8.1 with json >= 3: ' \
              'prometheus-client-mmap cannot build its mmap keys and silently falls back to ' \
              'SimpleValue, so /metrics will serve an empty or partial exposition. ' \
              'Pin `json` to "< 3" or upgrade to Rails 8.1.'

    module_function

    # Probes the exact call prometheus-client-mmap makes rather than comparing
    # version numbers, so this stays correct whichever side fixes it first.
    def broken_serialization?
      ['metric_name', 'name', [], []].to_json
      false
    rescue ArgumentError
      true
    end

    def check!
      return unless broken_serialization?

      logger ? logger.warn(MESSAGE) : warn(MESSAGE)
      nil
    end

    def logger
      ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
    end
  end
end
