# The yabeda-prometheus-mmap exporter mounts a WEBrick Rack handler. Under
# Rack 2.x `webrick` alone is enough; under Rack 3+ the handler was extracted
# into the `rackup` gem, so it must be added explicitly. Rails 7.1/7.2 run
# against Rack 2.2, Rails 8.x against Rack 3.
appraise 'rails-7.1' do
  gem 'rails', '~> 7.1.0'
  gem 'rack', '~> 2.2'
end

appraise 'rails-7.2' do
  gem 'rails', '~> 7.2.0'
  gem 'rack', '~> 2.2'
end

appraise 'rails-8.0' do
  gem 'rails', '~> 8.0.0'
  gem 'rackup'
end

appraise 'rails-8.1' do
  gem 'rails', '~> 8.1.0'
  gem 'rackup'
end
