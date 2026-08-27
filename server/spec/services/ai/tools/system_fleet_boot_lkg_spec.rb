# frozen_string_literal: true

require "rails_helper"

# IMP-b8d5cfa33b79 — the READ half of the boot-LKG ingest.
#
# Ingesting the agent's ARM telemetry into NodeInstance#config answers nothing
# on its own: the question the telemetry exists for ("is this node armed with a
# valid last-known-good, so its control plane can be decommissioned?") is asked
# through the MCP fleet read surface. system_get_instance is where an operator
# or agent asks it, so that is where the document has to appear.
#
# The absence contract is carried through unchanged: an instance that never
# reported has NO document, and the surface renders that as nil — never as an
# armed-looking default, and never as a measured "not armed".
RSpec.describe Ai::Tools::SystemFleetTool, "system_get_instance boot-LKG surface" do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }
  let(:tool)          { described_class.new(account: account, internal: true) }

  def get_instance
    tool.execute(params: { action: "system_get_instance", instance_id: instance.id })[:data]
  end

  it "renders nil for an instance that has never reported boot-LKG telemetry" do
    result = tool.execute(params: { action: "system_get_instance", instance_id: instance.id })

    expect(result[:success]).to be(true)
    expect(result[:data][:instance]).to have_key(:boot_lkg)
    expect(result[:data][:instance][:boot_lkg]).to be_nil
  end

  it "surfaces the armed document so the read surface can answer 'is this node armed?'" do
    ::System::BootLkgStateWriter.write!(
      instance: instance,
      payload:  { "lkg_present" => true, "lkg_confirmed_at" => "2026-08-20T04:05:06Z",
                  "lkg_module_count" => 7 }
    )

    doc = get_instance[:instance][:boot_lkg]

    expect(doc["arm_state"]).to eq("armed")
    expect(doc["lkg_module_count"]).to eq(7)
  end

  it "surfaces an unreported arm state as unreported, never as armed" do
    ::System::BootLkgStateWriter.write!(
      instance: instance,
      payload:  { "booted_from_lkg" => true, "lkg_age_seconds" => 900 }
    )

    doc = get_instance[:instance][:boot_lkg]

    expect(doc["arm_state"]).to eq("unreported")
    expect(doc["lkg_present"]).to be_nil
  end

  # The document lives on `config`, which also holds operator-written and
  # provider-written material. The surface must read the ONE key, never hand
  # the whole jsonb to a caller that previously got a curated field list.
  it "surfaces only the boot_lkg key, not the rest of config" do
    instance.update!(config: instance.config.merge(
      "boot_lkg"            => { "arm_state" => "armed" },
      "unrelated_config_key" => "must-not-appear"
    ))

    payload = get_instance[:instance]

    expect(payload[:boot_lkg]).to eq("arm_state" => "armed")
    expect(payload).not_to have_key(:config)
    expect(payload.to_s).not_to include("must-not-appear")
  end
end
