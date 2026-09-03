# frozen_string_literal: true

require "rails_helper"

# IMP-0467eee9fc57 — the operator row behind `system.instance_cordon`.
#
# Declaring the category in PolicyDeclarations makes Ai::AutonomyGate resolve
# it, but a DECLARED category with no row anywhere resolves through the
# unmatched default — which is `require_approval` too, so the behaviour looks
# right while the operator-visible, tunable control the declaration exists to
# provide does not exist on any install. The Autonomy modal's node_lifecycle
# section is ROW-driven, so with no writer the category never appears there.
#
# BOTH WRITERS ARE PINNED: this seed writes the row on a FIRST boot, and
# System::Governance::PolicyReconciler creates it on an install that had
# already booted (db:seed is first-boot only).
#
# THE DISCRIMINATING ORACLE is `result[:record]`, not `result[:policy]`: the
# declared verb equals the absent-row default, so comparing verbs alone cannot
# tell a seeded row from no row at all.
RSpec.describe "instance-cordon operator-path intervention policy" do
  let!(:account) { create(:account, name: "Powernode Admin") }

  def load_cordon_policy_seed!
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds",
                           "system_instance_cordon_policies.rb")
    end
  end

  let(:service) { Ai::InterventionPolicyService.new(account: account) }

  let(:declared) { System::Governance::PolicyDeclarations::INSTANCE_CORDON_OPERATOR_POLICIES }

  it "declares exactly the cordon category at require_approval" do
    expect(declared).to eq({ "system.instance_cordon" => "require_approval" })
  end

  # An unlisted seed never runs — the orchestrator's %w[] list is the whole
  # reachability story for a seed file.
  it "is listed in the extension seed orchestrator" do
    orchestrator = File.read(
      Rails.root.join("..", "extensions", "system", "server", "db", "seeds.rb")
    )

    expect(orchestrator).to include("system_instance_cordon_policies.rb")
  end

  context "on a first boot (the seed)" do
    before { load_cordon_policy_seed! }

    it "writes an active operator-path row for the gated cordon category" do
      expect(
        Ai::InterventionPolicy.exists?(
          account: account, ai_agent_id: nil, user_id: nil, scope: "global",
          action_category: "system.instance_cordon", is_active: true
        )
      ).to be(true)
    end

    it "resolves the cordon to a RECORD, not to the unmatched default" do
      result = service.resolve(action_category: "system.instance_cordon", agent: nil)

      expect(result[:policy]).to eq("require_approval")
      expect(result[:record]).not_to be_nil,
                                     "resolved with no operator row behind it — the modal has nothing to show"
    end

    it "is idempotent" do
      expect { load_cordon_policy_seed! }
        .not_to change {
          Ai::InterventionPolicy.where(account: account,
                                       action_category: "system.instance_cordon").count
        }
    end
  end

  context "on an install that had already booted (the reconciler)" do
    it "creates the row the install is missing" do
      expect {
        System::Governance::PolicyReconciler.new(account: account).reconcile!
      }.to change {
        Ai::InterventionPolicy.where(account: account, scope: "global", ai_agent_id: nil,
                                     action_category: "system.instance_cordon").count
      }.from(0).to(1)
    end
  end
end
