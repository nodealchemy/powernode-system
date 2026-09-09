# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 4 — the fleet tool's ladder verbs:
# promote/rollback INTO an environment, gated in the TARGET plane, refusing a
# doomed promotion before anything is parked, and disclosing the pins.
RSpec.describe Ai::Tools::SystemFleetTool, "promotion ladder verbs" do
  let(:account)  { create(:account) }
  # The replay executor re-asks the principal's permissions; an AGENT principal
  # answers "any user in the account holds it".
  let!(:operator) { create(:user, account: account, permissions: %w[system.nodes.read system.modules.update system.modules.rollback]) }
  let(:agent)    { create(:ai_agent, account: account, agent_type: "monitor", name: "Release Manager") }
  let(:tool)     { described_class.new(account: account, agent: agent, internal: true) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod)      { create(:system_node_module, account: account, node_platform: platform, category: category, name: "hub-backend") }
  let(:staging)  { account.environments.find_by!(slug: "staging") }
  let(:prod)     { account.environments.find_by!(slug: "prod") }

  def version!(n)
    create(:system_node_module_version, node_module: mod, version_number: n,
           artifacts: { "erofs" => { "oci_digest" => "sha256:#{n.to_s * 64}", "size" => 12_345_000, "oci_ref" => "ref#{n}" } })
  end

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest).with_indifferent_access)
  end

  let!(:v1) { version!(1) }
  let!(:v2) { version!(2) }

  before do
    %w[release.promote release.rollback].each do |category|
      Ai::InterventionPolicy.create!(account: account, action_category: category, policy: "auto_approve",
                                     scope: "global", priority: 5, is_active: true)
    end
    mod.promote_to_version!(v1)
    mod.promote_to_version!(v2) # staging + prod (pinned) still serve nothing
  end

  it "promotes into staging (trusted, unprotected) at once, inferring the current version, and discloses the pin" do
    r = call("system_promote_module_version", module_id: mod.id, environment: "staging")
    expect(r[:success]).to be true
    expect(r.dig(:data, :pending)).to be_nil
    expect(r.dig(:data, :environment)).to eq("staging")
    expect(r.dig(:data, :version, :id)).to eq(v2.id)
    expect(r.dig(:data, :version, :pinned_in)).to eq([ "staging" ])
    expect(mod.served_version_for(staging)).to eq(v2)

    full = call("system_get_module", module_id: mod.id)
    pins = full.dig(:data, :node_module, :environment_pins)
    expect(pins.map { |p| [ p[:environment_slug], p[:version_number] ] }).to contain_exactly([ "staging", 2 ])
  end

  it "parks a promotion into prod for a person, in prod's plane, and refuses a skipped rung before parking" do
    skip_r = call("system_promote_module_version", module_id: mod.id, environment: "prod", version_id: v2.id)
    expect(skip_r[:success]).to be false
    expect(skip_r[:error]).to match(/not what staging serves \(nothing\)/)
    expect(Ai::DeferredOperation.where(account_id: account.id).count).to eq(0)
    call("system_promote_module_version", module_id: mod.id, environment: "staging", version_id: v2.id)

    # naming a laxer plane on the params does not move the gate: the target plane is the floor
    forged = call("system_promote_module_version", module_id: mod.id, environment: "prod", version_id: v2.id, environment_slug: "dev")
    expect(forged.dig(:data, :pending)).to be true

    r = call("system_promote_module_version", module_id: mod.id, environment: "prod", version_id: v2.id)
    expect(r[:success]).to be true
    expect(r.dig(:data, :pending)).to be true
    request = Ai::ApprovalRequest.find(r.dig(:data, :approval_request_id))
    expect(request.request_data["environment"]).to include("slug" => "prod")
    expect(request.request_data["environment_escalation"]).to include("supervised")
    expect(mod.served_version_for(prod)).to be_nil

    op = Ai::DeferredOperation.where(account_id: account.id, status: "pending").order(:created_at).last
    expect(op.environment).to eq(prod)
    op.update!(status: "approved")
    op.execute_now!
    expect(mod.served_version_for(prod)).to eq(v2)
  end

  it "rolls ONE environment back, downward only, without touching the fleet-global pointer" do
    call("system_promote_module_version", module_id: mod.id, environment: "staging", version_id: v2.id)
    expect(mod.served_version_for(staging)).to eq(v2)

    up = call("system_rollback_module_version", module_id: mod.id, environment: "staging", version_id: version!(3).id)
    expect(up[:success]).to be false
    expect(up[:error]).to match(/a rollback goes down/)

    missing = call("system_rollback_module_version", module_id: mod.id, environment: "staging")
    expect(missing[:success]).to be false
    expect(missing[:error]).to match(/version_id is required/)

    r = call("system_rollback_module_version", module_id: mod.id, environment: "staging", version_id: v1.id)
    expect(r[:success]).to be true
    expect(r.dig(:data, :environment)).to eq("staging")
    expect(r.dig(:data, :rolled_back_from_version_id)).to eq(v2.id)
    expect(mod.served_version_for(staging)).to eq(v1)
    expect(mod.reload.current_version).to eq(v2)
  end

  it "refuses a following plane and an unknown environment by name" do
    r = call("system_promote_module_version", module_id: mod.id, environment: "dev", version_id: v2.id)
    expect(r[:success]).to be false
    expect(r[:error]).to match(/follows publishes/)
    r2 = call("system_promote_module_version", module_id: mod.id, environment: "nowhere", version_id: v2.id)
    expect(r2[:success]).to be false
    expect(r2[:error]).to match(/not found/)
  end
end
