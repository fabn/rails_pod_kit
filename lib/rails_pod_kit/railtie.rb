# frozen_string_literal: true

require 'rails_pod_kit/config'

require 'rails'
require 'rails/railtie'

module RailsPodKit
  # Mounts the health endpoint automatically so the host doesn't have to touch
  # config/routes.rb. The append block is evaluated when the route set is
  # drawn (and on every reload) — after the initializers have run — so the
  # guard sees whether Health.install! was called and with which `mount:`
  # option. Hosts that want route ownership (custom mount point, constraints)
  # pass `mount: false` to install! and mount HealthMonitor::Engine themselves.
  class Railtie < ::Rails::Railtie
    initializer 'rails_pod_kit.mount_health_endpoint' do |app|
      app.routes.append do
        mount HealthMonitor::Engine, at: '/' if RailsPodKit::Health.auto_mount?
      end
    end
  end
end
