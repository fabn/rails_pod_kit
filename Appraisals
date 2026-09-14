# The yabeda-prometheus-mmap exporter mounts a WEBrick Rack handler. Under
# Rack 2.x `webrick` alone is enough; under Rack 3+ the handler was extracted
# into the `rackup` gem, so it must be added explicitly. Rails 7.2 runs
# against Rack 2.2, Rails 8.x against Rack 3.
# ActiveSupport up to 8.0 encodes JSON with `JSON.generate(..., quirks_mode: true)`,
# a keyword json 3.0 removed. prometheus-client-mmap builds its mmap keys with
# `to_json`, rescues the resulting ArgumentError and silently falls back to
# SimpleValue — which writes nothing to the mmap files, so /metrics renders an
# empty exposition. Hold those appraisals on json 2.x; ActiveSupport 8.1 dropped
# the option and needs no pin.
appraise 'rails-7.2' do
  gem 'rails', '~> 7.2.0'
  gem 'rack', '~> 2.2'
  gem 'json', '< 3'
end

appraise 'rails-8.0' do
  gem 'rails', '~> 8.0.0'
  gem 'rackup'
  gem 'json', '< 3'
end

appraise 'rails-8.1' do
  gem 'rails', '~> 8.1.0'
  gem 'rackup'
end
