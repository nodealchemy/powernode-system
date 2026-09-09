# frozen_string_literal: true

require "rails_helper"

# Environment campaign, increment 4 — the promotion ladder on NodeModule:
# following planes serve current_version, pinned planes serve ONLY their
# pin (nothing until promoted into), flipping a plane to pinned freezes every
# module where it stands, and a promotion climbs ONE pinned rung at a time.
RSpec.describe System::NodeModule, "promotion ladder" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod)      { create(:system_node_module, account: account, node_platform: platform, category: category, name: "hub-backend") }
  let(:dev)      { account.environments.find_by!(slug: "dev") }
  let(:staging)  { account.environments.find_by!(slug: "staging") }
  let(:ops)      { account.environments.find_by!(slug: "ops") }
  let(:prod)     { account.environments.find_by!(slug: "prod") }

  def version!(n, usable: true)
    artifacts = usable ? { "erofs" => { "oci_digest" => "sha256:#{n.to_s * 64}", "size" => 12_345_000, "oci_ref" => "ref#{n}" } } : {}
    create(:system_node_module_version, node_module: mod, version_number: n, artifacts: artifacts,
                                        oci_digest: usable ? "sha256:#{n.to_s * 64}" : nil)
  end

  it "serves current_version to following planes and NOTHING to a pinned plane until promoted into" do
    v1 = version!(1)
    mod.promote_to_version!(v1)
    expect(mod.served_version_for(nil)).to eq(v1)
    expect(mod.served_version_for(dev)).to eq(v1)
    expect(mod.served_version_for(ops)).to eq(v1)
    expect(mod.served_version_for(staging)).to be_nil
    expect(mod.served_version_for(prod)).to be_nil
    expect(mod.environment_pins).to be_empty

    v2 = version!(2)
    mod.promote_to_version!(v2)
    expect(mod.served_version_for(dev)).to eq(v2)
    expect(mod.served_version_for(staging)).to be_nil
  end

  it "freezes every module at its current version when a plane is flipped to pinned, and drops the pins when flipped back" do
    v1 = version!(1)
    mod.promote_to_version!(v1)
    unpublished = create(:system_node_module, account: account, node_platform: platform, category: category)

    ops.update!(auto_promote_on_publish: false)
    expect(mod.environment_pins.find_by(environment: ops)).to have_attributes(node_module_version: v1, promoted_by_type: "pin_freeze")
    expect(unpublished.environment_pins).to be_empty
    expect(mod.served_version_for(ops)).to eq(v1)

    v2 = version!(2)
    mod.promote_to_version!(v2)
    expect(mod.served_version_for(ops)).to eq(v1)
    expect(mod.served_version_for(dev)).to eq(v2)

    ops.update!(auto_promote_on_publish: true)
    expect(System::ModuleEnvironmentPin.where(environment: ops)).to be_empty
    expect(mod.served_version_for(ops)).to eq(v2)
  end

  it "measures a pinned instance's module drift against its pin, not the fleet-global pointer" do
    v1 = version!(1)
    mod.promote_to_version!(v1)
    template = create(:system_node_template, account: account, node_platform: platform, environment: staging)
    node = create(:system_node, account: account, node_template: template)
    System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
    instance = create(:system_node_instance, node: node, status: "running", running_module_digests: { mod.id => v1.oci_digest })
    mod.promote_in_environment!(environment: staging, version: v1)

    mod.promote_to_version!(version!(2))
    expect(instance.reload.module_drift[:mismatched]).to be_empty
    expect(instance.module_drifted?).to be false
    mod.promote_in_environment!(environment: staging, version: mod.current_version)
    expect(instance.reload.module_drift[:mismatched].keys).to eq([ mod.id ])
  end

  describe "#ladder_refusal" do
    let!(:v1) { version!(1) }
    let!(:v2) { version!(2) }
    before { mod.promote_to_version!(v1); mod.promote_to_version!(v2) }

    it "refuses a following plane, a foreign version, an unmountable artifact, a skipped rung and an upward rollback" do
      expect(mod.ladder_refusal(environment: dev, version: v2)).to match(/follows publishes/)
      other = create(:system_node_module, account: account, node_platform: platform, category: category)
      foreign = create(:system_node_module_version, node_module: other, version_number: 9)
      expect(mod.ladder_refusal(environment: staging, version: foreign)).to match(/different module/)
      expect(mod.ladder_refusal(environment: staging, version: version!(3, usable: false))).to match(/no mountable artifact/)
      expect(mod.ladder_refusal(environment: nil, version: v2)).to match(/environment is required/)
      expect(mod.ladder_refusal(environment: staging, version: nil)).to match(/version is required/)

      # staging has no pinned rung below it: it takes the CURRENT version only
      expect(mod.ladder_refusal(environment: staging, version: v2)).to be_nil
      expect(mod.ladder_refusal(environment: staging, version: v1)).to match(/not the current version.*\(v2\).*publish it first/)
      # prod's rung is staging (ops follows publishes and is not a rung); staging serves nothing yet
      expect(mod.ladder_refusal(environment: prod, version: v2)).to match(/not what staging serves \(nothing\); promote it there first/)
      mod.promote_in_environment!(environment: staging, version: v2)
      expect(mod.ladder_refusal(environment: prod, version: v2)).to be_nil
      expect(mod.ladder_refusal(environment: prod, version: v1)).to match(/not what staging serves \(v2\)/)

      # a rollback goes DOWN
      expect(mod.ladder_refusal(environment: prod, version: v1, direction: :down)).to match(/serves nothing yet; there is nothing to roll back/)
      expect(mod.ladder_refusal(environment: staging, version: v1, direction: :down)).to be_nil
      expect(mod.ladder_refusal(environment: staging, version: v2, direction: :down)).to match(/not below what staging serves \(v2\)/)
    end
  end

  describe "#promote_in_environment! and #rollback_in_environment!" do
    let!(:v1) { version!(1) }
    let!(:v2) { version!(2) }
    before { mod.promote_to_version!(v1); mod.promote_to_version!(v2) }

    it "moves the plane's pin one rung, arms restart_after_update, and rolls back only downward" do
      allow(System::RestartAfterUpdate).to receive(:arm!).and_call_original
      actor = create(:user, account: account)
      pin = mod.promote_in_environment!(environment: staging, version: v2, actor: actor)
      expect(System::RestartAfterUpdate).to have_received(:arm!).with(node_module: mod, version: v2)
      expect(pin).to have_attributes(node_module_version: v2, promoted_by_id: actor.id, promoted_by_type: "User")
      expect(mod.served_version_for(staging)).to eq(v2)

      expect { mod.promote_in_environment!(environment: dev, version: v2) }.to raise_error(System::NodeModule::LadderError, /follows publishes/)
      expect { mod.promote_in_environment!(environment: prod, version: v1) }.to raise_error(System::NodeModule::LadderError, /one rung at a time/)

      mod.promote_in_environment!(environment: prod, version: v2, actor: "operator")
      expect(mod.served_version_for(prod)).to eq(v2)
      expect(mod.environment_pins.find_by(environment: prod).promoted_by_type).to eq("operator")

      expect { mod.rollback_in_environment!(environment: staging, version: v2) }.to raise_error(System::NodeModule::LadderError, /a rollback goes down/)
      mod.rollback_in_environment!(environment: staging, version: v1)
      expect(mod.served_version_for(staging)).to eq(v1)
      expect(mod.served_version_for(prod)).to eq(v2)
      expect(mod.reload.current_version).to eq(v2)
    end
  end
end
