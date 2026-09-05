# frozen_string_literal: true

require "rails_helper"

# The two sites that agent_lookup_by_display_name_spec grandfathered and that
# should not have been.
#
# Every OTHER grandfathered site survives a rename because a source_key
# fallback catches it. These two did not:
#
#   * Gitops::Reconciler#gitops_agent_id was a hardcoded display name whose
#     only fallback is `for_account(...).first` — an ARBITRARY account agent.
#     So a rename did not fail loudly; it silently re-attributed every GitOps
#     proposal to whichever agent happened to come back first. A wrong author
#     is worse than no author, because nothing looks broken.
#
#   * Governance::AgentResolver had the precedence INVERTED relative to
#     HierarchyReconciler — name first, source_key second. It worked, but by
#     luck of ordering rather than by design, and two resolvers disagreeing
#     about which field is the identity is the ambiguity that produced two
#     agents both called "concierge".
#
# The oracle for both is a RENAME. Rename the canonical, then assert
# resolution still finds THAT row — not nil, and not somebody else.
RSpec.describe "agent resolution precedence: source_key first" do
  let(:account) { create(:account) }

  describe "System::Gitops::Reconciler#gitops_agent_id" do
    # DECOY FIRST, deliberately. The pre-fix fallback is
    # `for_account(...).first` with no ORDER BY, and Postgres returns rows in
    # physical order, so whichever agent was inserted first is what a renamed
    # agent silently resolved to. Creating the decoy first is what makes this
    # spec reproduce the defect instead of passing by accident on row order.
    let!(:unrelated) do
      create(:ai_agent, account: account, name: "Some Other Agent", agent_type: "monitor",
             source_key: "unrelated", status: "active")
    end

    let!(:gitops_agent) do
      create(:ai_agent, :global, name: "GitOps Reconciler", agent_type: "monitor",
             source_key: "gitops-reconciler", is_system: true, status: "active")
    end

    let(:repository) { instance_double(System::GitopsRepository, account_id: account.id) }
    let(:reconciler) { System::Gitops::Reconciler.new(repository: repository) }

    it "resolves the GitOps agent while it still carries its seeded name" do
      expect(reconciler.send(:gitops_agent_id)).to eq(gitops_agent.id)
    end

    it "still resolves it after a rename, instead of attributing to an arbitrary agent" do
      gitops_agent.update!(name: "Declarative State Reconciler")

      expect(reconciler.send(:gitops_agent_id)).to eq(gitops_agent.id)
    end

    it "does not silently fall through to an unrelated agent" do
      gitops_agent.update!(name: "Declarative State Reconciler")

      expect(reconciler.send(:gitops_agent_id)).not_to eq(unrelated.id)
    end
  end

  describe "System::Governance::AgentResolver.resolve" do
    let!(:fleet_agent) do
      create(:ai_agent, :global, name: "Fleet Autonomy", agent_type: "monitor",
             source_key: "fleet-autonomy", is_system: true, status: "active")
    end

    it "resolves by source key when the display name still matches" do
      resolved = described_class_resolve("fleet-autonomy")
      expect(resolved&.id).to eq(fleet_agent.id)
    end

    it "resolves by source key AFTER a rename" do
      fleet_agent.update!(name: "Node Lifecycle Reconciler")

      expect(described_class_resolve("fleet-autonomy")&.id).to eq(fleet_agent.id)
    end

    # The fallback stays: an install whose canonical predates source_key being
    # set has only the name to go on, and must keep resolving.
    it "still falls back to the declared name when no row carries the key" do
      fleet_agent.update!(source_key: nil)

      expect(described_class_resolve("fleet-autonomy")&.id).to eq(fleet_agent.id)
    end

    it "prefers the account's own clone over the global, by key" do
      clone = create(:ai_agent, account: account, name: "Our Fleet Agent", agent_type: "monitor",
                     source_key: "fleet-autonomy", cloned_from_id: fleet_agent.id, status: "active")

      expect(described_class_resolve("fleet-autonomy")&.id).to eq(clone.id)
    end

    def described_class_resolve(key)
      System::Governance::AgentResolver.resolve(account_id: account.id, agent_key: key, mint: false)
    end
  end
end
