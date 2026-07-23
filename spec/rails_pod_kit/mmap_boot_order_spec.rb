# frozen_string_literal: true

require 'English'
require 'rbconfig'
require 'tempfile'

# Regression guard for the boot-order crash fixed by loading the mmap adapter
# from the gem's main entry point.
#
# yabeda-prometheus-mmap's `mmap.rb` requires its adapter *before* defining
# `Yabeda::Prometheus::Mmap.registry`, and the adapter self-registers with
# Yabeda at require time. If any metric is already declared when the adapter
# loads, registration eagerly reaches for that not-yet-defined `.registry` and
# raises `NoMethodError`. Under `bin/rails server`, Rails boots (host
# initializers may declare metrics) *before* config/puma.rb requires the
# adapter — so the adapter must be loaded earlier, at Bundler.require, while no
# metric exists yet. lib/rails_pod_kit.rb does exactly that.
#
# The crash only manifests on the *first* require of the adapter, and `require`
# is idempotent within a process (spec_helper already loaded the gem, hence the
# adapter). So the trigger is exercised in a fresh subprocess that replays the
# `bin/rails server` boot order.
RSpec.describe 'mmap adapter boot-order safety' do
  let(:lib_dir) { File.expand_path('../../lib', __dir__) }

  # Mirrors the crashing sequence: load the gem (Bundler.require), let a host
  # initializer declare a metric, then hit the lazy require the Puma path runs
  # from config/puma.rb (RailsPodKit::Puma.activate).
  let(:boot_script) do
    <<~RUBY
      $LOAD_PATH.unshift(#{lib_dir.inspect})
      require 'rails_pod_kit'
      require 'yabeda'
      Yabeda.configure { group(:boot_probe) { counter(:boot_probe_total, comment: 'probe') } }
      Yabeda.configure!
      require 'yabeda/prometheus/mmap'
      print 'BOOT_OK'
    RUBY
  end

  def run_boot_script(script)
    Tempfile.create(['mmap_boot_order', '.rb']) do |file|
      file.write(script)
      file.flush
      # Inherits BUNDLE_GEMFILE + bundler/setup from `bundle exec rspec`, so the
      # yabeda stack resolves to the bundled gems. Merge stderr into stdout so a
      # crash backtrace is captured for the failure message.
      output = IO.popen([RbConfig.ruby, file.path], err: %i[child out], &:read)
      [output, $CHILD_STATUS]
    end
  end

  it 'declares a Yabeda metric and then loads the mmap adapter without crashing' do
    output, status = run_boot_script(boot_script)

    aggregate_failures do
      expect(status).to be_success, "boot script exited non-zero:\n#{output}"
      expect(output).to include('BOOT_OK')
      expect(output).to_not include('NoMethodError')
    end
  end
end
