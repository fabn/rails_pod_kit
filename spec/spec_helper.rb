# frozen_string_literal: true

# Unit specs for the gem in isolation — they must NOT require the host Rails app.
require 'rails_pod_kit'

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |c| c.verify_partial_doubles = true }
  config.order = :random

  # Every example starts from a pristine config and a "not yet started" exporter
  # so port-binding state never leaks between examples.
  config.before do
    RailsPodKit.reset_config!
  end
end
