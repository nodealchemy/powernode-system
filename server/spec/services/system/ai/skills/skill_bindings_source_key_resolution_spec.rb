# frozen_string_literal: true

require "rails_helper"

# The property the rename increment had to establish FIRST: renaming an agent
# must not orphan anything.
#
# Before this change, SkillBindingsReconciler resolved agents with
# `Ai::Agent.global.where(name: agent_names)` and the controller resolved with
# `resolve_for(name: "System Concierge")`. Both are silent on a miss — the
# reconciler counted the agent "unknown" and dropped every binding for it, and
# the controller returned its "not seeded" refusal. So the oracle is a RENAME
# followed by an assertion that resolution still works, which is exactly the
# scenario neither lookup survived.
RSpec.describe "agent resolution survives a display-name change" do
  let(:account) { create(:account) }

  let!(:canonical) do
    create(:ai_agent, :global, name: "Infrastructure Generalist", agent_type: "assistant",
           source_key: "system-concierge", is_system: true, status: "active")
  end

  describe "the skill-binding registry" do
    it "maps the concierge token to a source key, not a display name" do
      expect(System::Ai::Skills::SkillBindings::AGENT_ALIASES.fetch("concierge"))
        .to eq("system-concierge")
    end

    it "no longer accepts the retired display name as a binding label" do
      # Nothing should reach the registry spelling the old name; if something
      # does, it must fail loudly rather than resolve to a stale target.
      expect(System::Ai::Skills::SkillBindings::AGENT_ALIASES).not_to have_key("System Concierge")
    end

    it "projects a source key for every registration" do
      entries = System::Ai::Skills::SkillBindings.discover
      expect(entries).to all(include(:agent_key))
      expect(entries.map { |e| e[:agent_key] }).to all(match(/\A[a-z0-9-]+\z/))
    end

    it "keys the concierge's own bindings on the source key" do
      # Touch a known binder so its `binds_to` has registered — under a
      # targeted run nothing else forces the executor tree to autoload.
      System::Ai::Skills::PlatformMaintenanceExecutor
      concierge_entries = System::Ai::Skills::SkillBindings.discover
                                                           .select { |e| e[:agent_key] == "system-concierge" }
      expect(concierge_entries).not_to be_empty
    end
  end

  describe "resolution after a rename" do
    # Rename to something arbitrary. Resolution must be unaffected, because
    # nothing keys on the name any more.
    before { canonical.update!(name: "Something Else Entirely") }

    it "still resolves the agent by source key" do
      found = Ai::Agent.global.find_by(source_key: "system-concierge")
      expect(found).to eq(canonical)
    end

    it "resolves the account's clone ahead of the global, by the same key" do
      clone = create(:ai_agent, account: account, name: "Ops Chat", agent_type: "assistant",
                     source_key: "system-concierge", cloned_from_id: canonical.id, status: "active")

      resolved = Ai::Agent.for_account(account.id)
                          .where(source_key: "system-concierge", agent_type: "assistant")
                          .account_override_first.first

      expect(resolved).to eq(clone)
    end

    it "falls back to the global when the account has no clone" do
      resolved = Ai::Agent.for_account(account.id)
                          .where(source_key: "system-concierge", agent_type: "assistant")
                          .account_override_first.first

      expect(resolved).to eq(canonical)
    end
  end

  describe "the slug moves with the name, which is why it is stated explicitly" do
    it "re-derives the slug on a plain rename" do
      # Documents the callback the migration deliberately bypasses.
      canonical.update!(name: "Some New Name")
      expect(canonical.reload.slug).to eq("some-new-name")
    end
  end
end
