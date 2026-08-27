# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Governance::PolicyReconciler do
  let(:account) { create(:account) }
  let(:declared) { System::Governance::PolicyDeclarations::MANUAL_OPERATION_POLICIES }
  let(:scope) { System::Governance::PolicyDeclarations::MANUAL_OPERATION_SCOPE }

  subject(:reconciler) { described_class.new(account: account, logger: Logger.new(IO::NULL)) }

  def row_for(category)
    Ai::InterventionPolicy.find_by(scope.merge(account: account, action_category: category))
  end

  describe "#drift" do
    it "reports every declared category as missing on an install that never seeded them" do
      report = reconciler.drift
      expect(report).to be_drifted
      expect(report.missing).to match_array(declared.keys)
    end

    it "mutates nothing" do
      expect { reconciler.drift }.not_to change(Ai::InterventionPolicy, :count)
    end
  end

  describe "#reconcile!" do
    it "creates the declared rows that are absent, with the declared verbs" do
      result = reconciler.reconcile!

      expect(result.created).to eq(declared.size)
      expect(row_for("system.task.terminate").policy).to eq("require_approval")
      expect(row_for("system.task.start").policy).to eq("auto_approve")
    end

    it "creates rows at the operator-resolvable shape, not agent-scoped" do
      reconciler.reconcile!
      row = row_for("system.task.terminate")

      # An agent-scoped row can never match an agent-less operator caller, so a
      # row of the wrong shape would leave the gate falling through to default.
      expect(row.scope).to eq("global")
      expect(row.ai_agent_id).to be_nil
      expect(row.user_id).to be_nil
    end

    it "is idempotent — a second run creates nothing" do
      reconciler.reconcile!
      expect { reconciler.reconcile! }.not_to change(Ai::InterventionPolicy, :count)
    end

    # THE LOAD-BEARING GUARANTEE. The seed path overwrites a tuned verb and
    # destroy_all's unlisted rows; that is safe only because it never re-runs.
    # This reconciler runs on every deploy, so it must never do either.
    it "NEVER overwrites an operator's tuned verb" do
      reconciler.reconcile!
      row = row_for("system.task.terminate")
      row.update!(policy: "block")

      reconciler.reconcile!

      expect(row.reload.policy).to eq("block")
    end

    it "NEVER deletes a row it does not declare" do
      foreign = Ai::InterventionPolicy.create!(
        scope.merge(
          account: account,
          action_category: "system.task.operator_invented_category",
          policy: "block", priority: 5, is_active: true,
          conditions: {}, preferred_channels: %w[notification]
        )
      )

      reconciler.reconcile!

      expect(foreign.reload).to be_persisted
      expect(foreign.policy).to eq("block")
    end

    it "fills only the gap when some rows already exist" do
      Ai::InterventionPolicy.create!(
        scope.merge(
          account: account, action_category: "system.task.start", policy: "block",
          priority: 5, is_active: true, conditions: {}, preferred_channels: %w[notification]
        )
      )

      result = reconciler.reconcile!

      expect(result.created).to eq(declared.size - 1)
      expect(result.created_categories).not_to include("system.task.start")
      expect(row_for("system.task.start").policy).to eq("block")
    end

    it "scopes to its own account" do
      other = create(:account)
      reconciler.reconcile!

      expect(
        Ai::InterventionPolicy.where(scope.merge(account: other)).count
      ).to eq(0)
    end
  end
end
