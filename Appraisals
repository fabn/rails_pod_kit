# The yabeda-prometheus-mmap exporter mounts a WEBrick Rack handler. Under
# Rack 2.x `webrick` alone is enough; under Rack 3+ the handler was extracted
# into the `rackup` gem, so it must be added explicitly. Rails 7.2 runs
# against Rack 2.2, Rails 8.x against Rack 3.
# json 3 needs ActiveSupport >= 8.1.4. Up to 8.0, encoding passes
# `JSON.generate(..., quirks_mode: true)`, a keyword json 3.0 removed:
# prometheus-client-mmap builds its mmap keys with `to_json`, rescues the
# resulting ArgumentError and silently falls back to SimpleValue, which writes
# nothing to the mmap files, so /metrics renders an empty exposition. Up to
# 8.1.3.x, `ActiveSupport::JSON.decode` passes a positional options hash that
# json 3 rejects. Hold 7.2 and 8.0 on json 2.x; `~> 8.1.0` resolves to the
# latest 8.1 release, which handles both.
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
