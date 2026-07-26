# frozen_string_literal: true

module RailsPodKit
  # Where the gem's background work (the SolidQueue scheduler supervisor, the
  # scrape-time metric collectors) sends the errors it swallows. Those errors
  # must never propagate — one would kill the supervising timer or fail the whole
  # /metrics response — but they must not vanish either.
  #
  # Always logs, and additionally hands the error to the Rails error reporter
  # when there is one, so the host's Rollbar / Sentry / Datadog subscriber picks
  # it up. The log line is not redundant: `Rails.error.report` only fans out to
  # subscribers, so on an app with none — or with one that is not wired in a
  # given environment — the failure would otherwise leave no trace at all, and
  # the only symptom of a broken collector is a gauge quietly serving a stale
  # value.
  module ErrorReporter
    module_function

    def report(error, source:)
      message = "[#{source}] #{error.class}: #{error.message}"
      logger ? logger.error(message) : warn(message)

      rails_reporter&.report(error, handled: true, source: source)
    end

    def logger
      ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
    end

    def rails_reporter
      ::Rails.error if defined?(::Rails) && ::Rails.respond_to?(:error)
    end
  end
end
