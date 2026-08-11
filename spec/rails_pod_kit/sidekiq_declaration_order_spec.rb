# frozen_string_literal: true

require 'open3'

# yabeda-sidekiq declares its cluster gauges from inside its own
# `Yabeda.configure` block, and evaluates that block *at require time* when
# Yabeda has already been configured. Whether the gauges exist therefore depends
# on the policy being in place before the require — which cannot be exercised
# in-process, because the suite has already required yabeda-sidekiq by the time
# any example runs. Each case gets a fresh interpreter instead.
RSpec.describe 'sidekiq cluster-metric declaration order' do
  # Boots a host that configures Yabeda before the kit touches Sidekiq — the
  # order any Rails app gets when yabeda's Railtie runs first.
  def boot(policy)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path('../../lib', __dir__).inspect})
      require 'yabeda'
      Yabeda.configure!

      require 'rails_pod_kit/sidekiq'
      RailsPodKit.configure do |c|
        c.enabled = true
        c.sidekiq_global_metrics = #{policy.inspect}
      end
      RailsPodKit::Sidekiq.enable_global_collection! if #{policy.inspect} == :web

      declared = Yabeda.metrics.keys.map(&:to_s)
      puts({
        already_configured: Yabeda.already_configured?,
        # Undefined under :off, where yabeda-sidekiq is never required at all.
        collect_cluster_metrics: defined?(Yabeda::Sidekiq) ? Yabeda::Sidekiq.config.collect_cluster_metrics : false,
        cluster_gauges: declared.grep(/\\Asidekiq_(jobs_waiting_count|queue_latency|active_processes)\\z/).sort
      }.inspect)
    RUBY

    out, err, status = Open3.capture3(RbConfig.ruby, '-e', script)
    expect(status).to be_success, "boot failed:\n#{err}"
    eval(out) # rubocop:disable Security/Eval
  end

  it 'declares the cluster gauges the collect block references' do
    result = boot(:web)

    expect(result[:already_configured]).to be(true)
    expect(result[:collect_cluster_metrics]).to be(true)
    # Without these the collect block raises NameError on every scrape and the
    # whole endpoint 500s — the gauges and the flag must agree.
    expect(result[:cluster_gauges])
      .to eq(%w[sidekiq_active_processes sidekiq_jobs_waiting_count sidekiq_queue_latency])
  end

  it 'leaves them undeclared when no process is asked to collect them' do
    result = boot(:off)

    expect(result[:collect_cluster_metrics]).to be(false)
    expect(result[:cluster_gauges]).to be_empty
  end
end
