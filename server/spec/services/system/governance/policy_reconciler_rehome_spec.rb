# frozen_string_literal: true

require "rails_helper"

# HIER-P2A — the reconciler MOVES a row whose declared owner changed; it does
# not duplicate it.
#
# When a declared key moves from agent A's set to agent B's (the 14 sdwan
# remediation rows to SDWAN Manager, system.gitops_drift_remediate to GitOps
# Reconciler, system.disk_image_publication_investigate to Disk Image Manager),
# an established install still carries the row on A — possibly with an
# operator-tuned verb, possibly deactivated. Absence-only reconciling would
# create a fresh default row on B and leave the tuned one stale on A: the
# operator's intent lost on the agent that now decides, and a decoy left on
# the agent that no longer does. So the row is RE-HOMED: ai_agent_id updated
# in place, everything else preserved, an audit row written.
#
# On ops-hub the live Fleet Autonomy set is the migration path for this
# reconciler run at deploy, so every example here is also an idempotency
# claim.
RSpec.describe System::Governance::PolicyReconciler, "owner re-homing" do
  let(:account) { create(:account) }
  subject(:reconciler) { described_class.new(account: account, logger: Logger.new(IO::NULL)) }

  let!(:fleet) do
    create(:ai_agent, account: account, name: "Fleet Autonomy", agent_type: "monitor",
                      source_key: "fleet-autonomy")
  end
  let!(:sdwan) do
    create(:ai_agent, account: account, name: "SDWAN Manager", agent_type: "monitor",
                      source_key: "sdwan-manager")
  end

  # A key that MOVED: declared on Fleet Autonomy until HIER-P2A, on SDWAN
  # Manager since.
  let(:moved) { "system.sdwan_peer_remediate" }

  def row(agent, category)
    Ai::InterventionPolicy.find_by(account: account, scope: "agent", ai_agent_id: agent.id,
                                   action_category: category)
  end

  def legacy_row!(category, policy: "notify_and_proceed", is_active: true, priority: 10,
                  conditions: { "trust_tier_minimum" => "monitored" })
    Ai::InterventionPolicy.create!(
      account: account, scope: "agent", ai_agent_id: fleet.id, user_id: nil,
      action_category: category, policy: policy, priority: priority, is_active: is_active,
      conditions: conditions, preferred_channels: %w[notification]
    )
  end

  it "pins the moved key as declared on SDWAN Manager and not on Fleet Autonomy" do
    expect(System::Governance::PolicyDeclarations.owner_of(moved)).to eq("sdwan-manager")
    expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES).not_to have_key(moved)
  end

  context "on first boot (no rows)" do
    it "creates the moved key on its new owner and nothing on the old one" do
      result = reconciler.reconcile!

      expect(row(sdwan, moved)).to be_present
      expect(row(sdwan, moved).policy).to eq("notify_and_proceed")
      expect(row(fleet, moved)).to be_nil
      expect(result.rehomed).to be_empty
      expect(result.created_categories).to include("sdwan-manager/#{moved}")
    end
  end

  context "on an already-booted install with an operator-tuned row on the old owner" do
    let!(:tuned) { legacy_row!(moved, policy: "require_approval", priority: 42, conditions: { "trust_tier_minimum" => "trusted" }) }

    it "re-homes the row in place — same id, verb, priority and conditions; nothing left on the old owner" do
      result = reconciler.reconcile!

      expect(tuned.reload.ai_agent_id).to eq(sdwan.id)
      expect(tuned.policy).to eq("require_approval")
      expect(tuned.priority).to eq(42)
      expect(tuned.conditions).to eq("trust_tier_minimum" => "trusted")
      expect(tuned.is_active).to be(true)
      expect(row(fleet, moved)).to be_nil
      expect(Ai::InterventionPolicy.where(account: account, action_category: moved).count).to eq(1)

      # The operator-facing line must name the agent the row moved FROM. It is
      # the only record of the migration in the deploy log, and the name has to
      # be captured BEFORE the update — reading it off the row afterwards
      # resolves the NEW foreign key and reports the destination as the source.
      expect(result.rehomed).to include(
        a_string_matching(%r{sdwan-manager/#{Regexp.escape(moved)} \(from Fleet Autonomy\)})
      )
      expect(result.created_categories).not_to include("sdwan-manager/#{moved}")
      expect(result).to be_changed
    end

    it "writes an audit row naming the old and new owner" do
      expect { reconciler.reconcile! }.to change(AuditLog, :count).by_at_least(1)

      audit = AuditLog.where(account: account, resource_type: "Ai::InterventionPolicy",
                             resource_id: tuned.id).last
      expect(audit).to be_present
      expect(audit.action).to eq(described_class::REHOME_AUDIT_ACTION)
      expect(audit.old_values).to include("ai_agent_id" => fleet.id, "agent_key" => "fleet-autonomy")
      expect(audit.new_values).to include("ai_agent_id" => sdwan.id, "agent_key" => "sdwan-manager")
      expect(audit.metadata).to include("action_category" => moved, "set_key" => "sdwan-manager")
    end

    it "is idempotent — a second run re-homes and creates nothing" do
      reconciler.reconcile!
      again = described_class.new(account: account, logger: Logger.new(IO::NULL)).reconcile!

      expect(again.rehomed).to be_empty
      expect(again.created_categories).not_to include(a_string_matching(/#{Regexp.escape(moved)}/))
      expect(tuned.reload.ai_agent_id).to eq(sdwan.id)
    end

    it "names the re-homable row in the drift report before the run, and not after" do
      before = reconciler.drift
      pending = before.rehomable
      expect(pending.map(&:to_s)).to include(a_string_matching(%r{sdwan-manager/#{Regexp.escape(moved)}.*re-home from Fleet Autonomy}))
      expect(before).to be_drifted

      reconciler.reconcile!
      after = described_class.new(account: account, logger: Logger.new(IO::NULL)).drift
      expect(after.rehomable).to be_empty
      expect(after.missing.map(&:to_s)).not_to include(a_string_matching(/#{Regexp.escape(moved)}/))
    end
  end

  context "with a row an operator DEACTIVATED on the old owner" do
    let!(:off) { legacy_row!(moved, is_active: false) }

    it "re-homes it and leaves it inactive on the new owner" do
      reconciler.reconcile!

      expect(off.reload.ai_agent_id).to eq(sdwan.id)
      expect(off.is_active).to be(false)
      expect(Ai::InterventionPolicy.where(account: account, action_category: moved).count).to eq(1)
    end
  end

  context "boundaries" do
    it "does NOT touch a row on the old owner for a key that owner STILL declares" do
      keeps = legacy_row!("system.cert_rotate", policy: "block")

      reconciler.reconcile!

      expect(keeps.reload.ai_agent_id).to eq(fleet.id)
      expect(keeps.policy).to eq("block")
    end

    it "does NOT re-home a row that sits on an agent the declarations do not know" do
      foreign = create(:ai_agent, account: account, name: "Operator's Own Agent", agent_type: "monitor")
      theirs = Ai::InterventionPolicy.create!(
        account: account, scope: "agent", ai_agent_id: foreign.id, user_id: nil,
        action_category: moved, policy: "block", priority: 10, is_active: true,
        conditions: {}, preferred_channels: %w[notification]
      )

      reconciler.reconcile!

      expect(theirs.reload.ai_agent_id).to eq(foreign.id)
      expect(row(sdwan, moved)).to be_present # created fresh, the foreign row is not a former owner's
    end

    it "does not re-home when the new owner already has its own row (the old one is left for the operator)" do
      legacy = legacy_row!(moved, policy: "block")
      own = Ai::InterventionPolicy.create!(
        account: account, scope: "agent", ai_agent_id: sdwan.id, user_id: nil,
        action_category: moved, policy: "auto_approve", priority: 10, is_active: true,
        conditions: {}, preferred_channels: %w[notification]
      )

      result = reconciler.reconcile!

      expect(own.reload.policy).to eq("auto_approve")
      expect(legacy.reload.ai_agent_id).to eq(fleet.id)
      expect(result.rehomed).to be_empty
    end
  end
end
