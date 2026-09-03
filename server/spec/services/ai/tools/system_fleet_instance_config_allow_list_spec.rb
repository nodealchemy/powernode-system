# frozen_string_literal: true

require "rails_helper"

# IMP-1b65222b8d5f — the MCP twin of the two REST writers.
#
# `system_update_instance` reached
# Ai::Tools::SystemFleetTool#update_instance, which built `attrs[:config] =
# <incoming document>` and called `instance.update!(attrs)`: a whole-document
# replace on a LIVE NodeInstance, from a tool an agent can call. It was
# invisible to the write-seam lint (spec/lint/node_instance_config_write_seam_spec.rb
# names it as its KNOWN LIMIT) because the key never appears at the write site.
#
# The code half-knew: it hand-preserved the `network_profile_source` stamp
# across the replace, which is a per-key workaround for a whole-document write.
# Under the allow-list that workaround is unnecessary — the stamp is not a
# writable key at all, so no body can carry it, and the seam merge leaves it
# alone by construction.
RSpec.describe Ai::Tools::SystemFleetTool, "system_update_instance config allow-list" do
  let(:account)   { create(:account) }
  let(:node)      { create(:system_node, account: account) }
  let(:telemetry) { { "cpu_pct" => 7, "observed_at" => "2026-09-02T00:00:00Z" } }
  let(:instance) do
    create(:system_node_instance, node: node, status: "running",
                                  config: { "runtime_metrics" => telemetry })
  end
  let(:tool) { described_class.new(account: account, internal: true) }

  def call(**rest)
    tool.execute(params: { action: "system_update_instance", instance_id: instance.id }.merge(rest))
  end

  it "refuses a config document that names a platform-written telemetry lane" do
    result = call(config: { "runtime_metrics" => { "cpu_pct" => 99 } })

    expect(result[:success]).to be(false)
    expect(result[:error]).to include("runtime_metrics")
    expect(instance.reload.config["runtime_metrics"]).to eq(telemetry)
  end

  it "refuses an invented key and leaves the whole document untouched" do
    result = call(config: { "zz_unknown_stage_key" => 1 })

    expect(result[:success]).to be(false)
    instance.reload
    expect(instance.config).not_to have_key("zz_unknown_stage_key")
    expect(instance.config["runtime_metrics"]).to eq(telemetry)
  end

  it "refuses the whole call when ONE key of several is not writable" do
    result = call(config: { "hardware_model" => "raspberry_pi_5", "boot_lkg" => { "arm_state" => "armed" } })

    expect(result[:success]).to be(false)
    instance.reload
    expect(instance.config).not_to have_key("hardware_model")
    expect(instance.config).not_to have_key("boot_lkg")
  end

  it "merges an allow-listed key WITHOUT erasing the telemetry lane beside it" do
    result = call(config: { "hardware_model" => "raspberry_pi_5" })

    expect(result[:success]).to be(true)
    instance.reload
    expect(instance.config["hardware_model"]).to eq("raspberry_pi_5")
    expect(instance.config["runtime_metrics"]).to eq(telemetry)
  end

  it "leaves an earlier allow-listed key alone when a later call names a different one" do
    call(config: { "hardware_model" => "raspberry_pi_5" })
    call(config: { "memory_mb" => 8192 })

    instance.reload
    expect(instance.config["hardware_model"]).to eq("raspberry_pi_5")
    expect(instance.config["memory_mb"]).to eq(8192)
  end

  it "documents the allow-list in the action definition rather than promising a replace" do
    description = described_class.action_definitions
                                 .fetch("system_update_instance")[:parameters][:config][:description]

    expect(description).not_to match(/replaces the stored config/i)
    expect(description).to include("hardware_model")
  end
end
