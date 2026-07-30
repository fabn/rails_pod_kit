# frozen_string_literal: true

source 'https://rubygems.org'

# Resolve the gem's own runtime deps from the gemspec.
gemspec

# Rails is pulled in transitively by health-monitor-rails, but declare it so the
# Appraisal matrix can pin the version under test.
gem 'rails', '>= 7.2'

# Host-provided runtime gems the isolated specs exercise, pinned so the local
# suite and the /metrics harness run against the same stack a production host
# would use.
gem 'puma', '~> 7.2'
gem 'sidekiq', '~> 7.3'
# Only the scheduler entry point needs it, and only the host declares it in a
# real app — the specs exercise the poller wiring against the real gem.
gem 'sidekiq-cron', '~> 2.4'
# Rack 2.2 requires 'ostruct' (rack/show_exceptions) but doesn't declare it;
# since Ruby 4.0 ostruct is no longer a default gem, so it must be explicit.
gem 'ostruct'

# Appraisal drives the Rails/Rack test matrix; the concrete versions live in
# the Appraisals file and the generated gemfiles/*.gemfile.
gem 'appraisal', '~> 2.5'

# Test + lint toolchain.
gem 'rack-test', '~> 2.1'
gem 'rspec', '~> 3.13'
gem 'rubocop', '~> 1.50'
gem 'rubocop-performance'
gem 'rubocop-rspec'
