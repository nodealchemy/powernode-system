# frozen_string_literal: true

require "rails_helper"

# IMP-e025722ef14e — the operator row behind `system.volume_snapshot_delete`.
#
# THE FINDING THIS PINS. Declaring the category in PolicyDeclarations makes
# `Ai::AutonomyGate` resolve it, but a DECLARED category with no row anywhere
# resolves through the unmatched default — which is `require_approval` too, so
# the behaviour looks right while the operator-visible, tunable control the
# declaration exists to provide does not exist on any install. The Autonomy
# modal's storage section is ROW-driven (see
# System::AutonomyActions#autonomy_actions_by_domain), so with no writer the
# category never appears there at all.
#
# ONE WRITER (proposal §5 ruling 7, IMP-10e4f6c3bcd2): the first-boot seed
# that used to write this row (system_volume_snapshot_policies.rb) is gone;
# System::Governance::PolicyReconciler writes it from the
# `volume-snapshot-operator` POLICY_SETS entry on every boot, the first one
# included, and via `rails system:governance:reconcile`.
#
# THE DISCRIMINATING ORACLE is `result[:record]`, not `result[:policy]`: the
# declared verb equals the absent-row default, so comparing verbs alone cannot
# tell a written row from no row at all.
RSpec.describe "volume-snapshot operator-path intervention policy" do
  let!(:account) { create(:account, name: "Powernode Admin") }

  let(:service) { Ai::InterventionPolicyService.new(account: account) }

  let(:declared) { System::Governance::PolicyDeclarations::VOLUME_SNAPSHOT_OPERATOR_POLICIES }

  def reconcile!
    System::Governance::PolicyReconciler.new(account: account, logger: Logger.new(IO::NULL)).reconcile!
  end

  # Restated independently of the declaration so a silent edit to either side
  # fails here rather than changing what an operator gets.
  it "declares exactly the snapshot delete verb at require_approval" do
    expect(declared).to eq({ "system.volume_snapshot_delete" => "require_approval" })
  end

  it "declares it as an operator-shape (global, agent-less) set the reconciler writes" do
    set = System::Governance::PolicyDeclarations::POLICY_SETS.find { |s| s[:key] == "volume-snapshot-operator" }
    expect(set).to be_present
    expect(set[:agent_key]).to be_nil
    expect(set[:scope]).to eq("global")
    expect(set[:policies]).to eq(declared)
  end

  describe "the reconciler (the only writer)" do
    it "creates the row the install is missing" do
      expect { reconcile! }.to change {
        Ai::InterventionPolicy.where(account: account, scope: "global", ai_agent_id: nil, user_id: nil,
                                     action_category: "system.volume_snapshot_delete", is_active: true).count
      }.from(0).to(1)
    end

    it "resolves the delete to a RECORD, not to the unmatched default" do
      reconcile!
      result = service.resolve(action_category: "system.volume_snapshot_delete", agent: nil)

      expect(result[:policy]).to eq("require_approval")
      expect(result[:record]).not_to be_nil,
                                     "resolved with no operator row behind it — the modal has nothing to show"
    end

    it "is idempotent" do
      reconcile!
      expect { reconcile! }.not_to change {
        Ai::InterventionPolicy.where(account: account, action_category: "system.volume_snapshot_delete").count
      }
    end
  end
end
