# frozen_string_literal: true

module RailsPodKit
  # Where the gem's background work (the SolidQueue scheduler supervisor, the
  # scrape-time metric collectors) sends the errors it swallows. Those errors
  # must never propagate — one would kill the supervising timer or fail the whole
  # /metrics response — but they must not vanish either.
  #
  # Uses the Rails error reporter when there is one (so the host's Rollbar /
  # Sentry / Datadog subscriber picks it up) and falls back to stderr for the
  # Rails-free processes.
  module ErrorReporter
    module_function

    def report(error, source:)
      if defined?(::Rails) && ::Rails.respond_to?(:error) && ::Rails.error
        ::Rails.error.report(error, handled: true, source: source)
      else
        warn "[#{source}] #{error.class}: #{error.message}"
      end
    end
  end
end
