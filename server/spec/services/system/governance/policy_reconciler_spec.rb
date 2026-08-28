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

  # Pins the figures PolicyReconciler's header quotes. This exists as an
  # assertion rather than prose because the claim it replaced — "it cannot
  # widen autonomy that was previously closed" — was itself a comment, and a
  # comment cannot fail when the declarations move out from under it.
  #
  # If one of these fails, the declared verb mix changed: update the header's
  # numbers in the same commit.
  describe "the declared verb mix (pins the reconciler's header)" do
    # A `let`, not a constant: a constant assigned inside a describe block
    # lands on Object, where a same-named one in another spec file silently
    # clobbers it.
    let(:proceeds_unattended) { %w[auto_approve notify_and_proceed silent] }

    # The load-bearing premise. Everything below is only a widening BECAUSE
    # absence resolves to require_approval — asserted against the service
    # rather than restated, so a change to the default breaks this first.
    it "resolves an undeclared category to require_approval" do
      resolved = Ai::InterventionPolicyService
                 .new(account: account)
                 .resolve(action_category: "system.task.never_declared_anywhere")

      expect(resolved[:policy]).to eq("require_approval")
      expect(resolved[:record]).to be_nil
    end

    it "declares 27 rows in an 11/7/9 split" do
      expect(declared.size).to eq(27)
      expect(declared.values.tally).to eq(
        "auto_approve" => 11,
        "notify_and_proceed" => 7,
        "require_approval" => 9
      )
    end

    it "widens 18 of them relative to the absence they replace" do
      widening, no_op = declared.partition { |_, verb| proceeds_unattended.include?(verb) }

      expect(widening.size).to eq(18)
      expect(no_op.size).to eq(9)
      expect(no_op.map(&:last).uniq).to eq(%w[require_approval])
    end
  end
end
