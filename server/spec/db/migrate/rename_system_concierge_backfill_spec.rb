# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260905070000_rename_system_concierge_to_infrastructure_generalist.rb"
)

# The backfill's guarantee is NOT "the canonical was renamed". It is "nothing
# else was".
#
# GloballyScopable#clone_to_account copies `source_key` onto an account's
# clone, so a predicate matching source_key alone would have renamed every
# operator's customised clone along with the canonical. That is the failure
# this spec exists to catch, so the clone assertion comes first and the
# canonical assertion second.
RSpec.describe RenameSystemConciergeToInfrastructureGeneralist do
  let(:account) { create(:account) }
  let(:migration) { described_class.new }

  def run!
    migration.verbose = false
    migration.up
  end

  # The seeded global canonical, at the shape AgentSetupHelpers writes.
  let!(:canonical) do
    create(:ai_agent, :global, name: "System Concierge", agent_type: "assistant",
           source_key: "system-concierge", is_system: true, status: "active")
  end

  # An operator's clone: same source_key (the helper copies it), their own
  # name. This row must survive untouched.
  let!(:clone) do
    create(:ai_agent, account: account, name: "Ops Chat (mine)", agent_type: "assistant",
           source_key: "system-concierge", cloned_from_id: canonical.id, status: "active")
  end

  it "leaves an account clone carrying the same source_key completely alone" do
    expect { run! }.not_to change { clone.reload.attributes.slice("name", "slug") }
  end

  it "renames the global canonical and states its slug" do
    run!

    expect(canonical.reload.name).to eq("Infrastructure Generalist")
    expect(canonical.slug).to eq("infrastructure-generalist")
  end

  it "leaves the source key alone — it is the identity the rename is keyed on" do
    expect { run! }.not_to change { canonical.reload.source_key }
  end

  it "is idempotent: a second run matches nothing" do
    run!
    expect { run! }.not_to change { canonical.reload.attributes.slice("name", "slug", "updated_at") }
  end

  it "does not touch an unrelated canonical" do
    other = create(:ai_agent, :global, name: "Fleet Autonomy", agent_type: "monitor",
                   source_key: "fleet-autonomy", is_system: true, status: "active")

    expect { run! }.not_to change { other.reload.attributes.slice("name", "slug") }
  end

  describe "down" do
    it "restores both identifiers" do
      run!
      migration.down

      expect(canonical.reload.name).to eq("System Concierge")
      expect(canonical.slug).to eq("system-concierge")
    end
  end
end
