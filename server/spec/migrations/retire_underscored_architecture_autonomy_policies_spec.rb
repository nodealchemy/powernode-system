# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260902210000_retire_underscored_architecture_autonomy_policies.rb"
)

# IMP-51e5c6184ae4 — the half the code change cannot reach.
#
# Dropping system.architecture_<verb> from PolicyDeclarations stops the rows
# being CREATED. It does nothing about the ones every running install already
# has: PolicyReconciler is absence-only (creates a missing declared row, never
# updates or deletes), and db/seeds runs on first boot only. So the disposition
# is SWEEP, and the sweep is this migration — which means the migration, not
# the constant, is what an operator's install actually executes.
#
# Rows are written through the migration's OWN local model rather than
# Ai::InterventionPolicy, for the same reason the migration declares one: a
# migration that survives its app model's validations drifting must be tested
# against the table, not against today's model.
RSpec.describe RetireUnderscoredArchitectureAutonomyPolicies do
  subject(:migration) { described_class.new }

  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  def policy(category, account_row: account, verb: "require_approval", scope: "global")
    described_class::PolicyRow.create!(
      account_id: account_row.id, action_category: category,
      policy: verb, scope: scope, priority: 0, is_active: true
    )
  end

  def categories_now
    described_class::PolicyRow.order(:action_category).pluck(:action_category)
  end

  # `say` writes through Migration#write, which puts to $stdout when verbose.
  def run_up
    migration.verbose = true
    captured = StringIO.new
    original = $stdout
    $stdout = captured
    begin
      migration.up
    ensure
      $stdout = original
    end
    captured.string
  end

  describe "#up" do
    it "retires every underscored spelling across ALL accounts, not just the admin one" do
      mine    = described_class::RETIRED_CATEGORIES.map { |c| policy(c) }
      theirs  = policy("system.architecture_create", account_row: other_account, scope: "agent")

      expect { run_up }.to change { described_class::PolicyRow.count }.by(-4)

      expect(described_class::PolicyRow.where(id: mine.map(&:id) + [ theirs.id ])).to be_empty
    end

    it "leaves the surviving dotted rows and unrelated categories alone" do
      policy("system.architecture_delete")
      survivor = policy("system.architecture.delete")
      bystander = policy("system.package_module.refresh")

      run_up

      expect(categories_now).to eq(%w[system.architecture.delete system.package_module.refresh])
      expect(survivor.reload.policy).to eq("require_approval")
      expect(bystander.reload).to be_present
    end

    it "records the scope and verb of every row it deletes" do
      policy("system.architecture_update", verb: "auto_approve", scope: "agent")

      output = run_up

      expect(output).to include("retiring system.architecture_update")
      expect(output).to include('scope="agent"')
      expect(output).to include('policy="auto_approve"')
      expect(output).to include("superseded by system.architecture.update")
    end

    # The direction the header calls the dangerous one: the dotted row resolved
    # NOTHING before this release, so an install that loosened it believing it
    # controlled architecture CRUD is the install whose gate this release opens.
    it "WARNS when a surviving dotted row is looser than the verb it shipped at" do
      policy("system.architecture.create", verb: "auto_approve")
      policy("system.architecture_create")

      output = run_up

      expect(output).to include("WARNING")
      expect(output).to include('system.architecture.create = "auto_approve"')
      expect(output).to include("INERT before this release")
      expect(output).to include("system.architecture_create")
    end

    it "does not warn about a surviving row still at its seeded verb" do
      policy("system.architecture.create")
      policy("system.architecture_create")

      expect(run_up).not_to include("WARNING")
    end

    it "says so when there is no surviving dotted row to disclose" do
      policy("system.architecture_create")

      expect(run_up).to include("No system.architecture.<verb> rows present")
    end

    it "is a no-op on a second run" do
      described_class::RETIRED_CATEGORIES.each { |c| policy(c) }
      run_up

      expect { expect(run_up).to include("No system.architecture_<verb> policy rows to retire") }
        .not_to change { described_class::PolicyRow.count }
    end
  end

  describe "#down" do
    it "refuses to restore rows that would be unregistered and un-saveable" do
      expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    end
  end
end
