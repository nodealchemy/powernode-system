# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260903120000_retire_underscored_package_module_autonomy_policy.rb"
)

# IMP-2effedffc990 — the half the code change cannot reach, for the SECOND
# duplicate-spelling pair (the architecture trio was IMP-51e5c6184ae4).
#
# `system.package_module_create` was declared in
# System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES from ext
# commit 73f2c8f7, which is an ancestor of origin/develop — so a running
# install that booted (or that ran `rake system:governance:reconcile`) after that
# commit HAS the row. Dropping the declaration stops it being created and
# strands the ones that exist: PolicyReconciler is absence-only, db/seeds is
# first-boot-only, and the orphan-cleanup seed is admin-account-only. The
# disposition is therefore a SWEEP, and this migration is it.
#
# Rows go through the migration's OWN local model, not Ai::InterventionPolicy:
# a migration that must survive its app model's validations drifting has to be
# tested against the table.
RSpec.describe RetireUnderscoredPackageModuleAutonomyPolicy do
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

  describe "the constants" do
    it "retires exactly the underscored spelling and names the dotted survivor" do
      expect(described_class::RETIRED_CATEGORIES).to eq(%w[system.package_module_create])
      expect(described_class::SURVIVING_CATEGORIES)
        .to eq("system.package_module_create" => "system.package_module.create")
    end
  end

  describe "#up" do
    it "retires the underscored spelling across ALL accounts, not just the admin one" do
      mine   = policy("system.package_module_create")
      theirs = policy("system.package_module_create", account_row: other_account, scope: "agent")

      expect { run_up }.to change { described_class::PolicyRow.count }.by(-2)

      expect(described_class::PolicyRow.where(id: [ mine.id, theirs.id ])).to be_empty
    end

    it "leaves the surviving dotted row and unrelated categories alone" do
      policy("system.package_module_create")
      survivor  = policy("system.package_module.create")
      bystander = policy("system.package_module.refresh")

      run_up

      expect(categories_now).to eq(%w[system.package_module.create system.package_module.refresh])
      expect(survivor.reload.policy).to eq("require_approval")
      expect(bystander.reload).to be_present
    end

    it "records the scope and verb of every row it deletes" do
      policy("system.package_module_create", verb: "auto_approve", scope: "agent")

      output = run_up

      expect(output).to include("retiring system.package_module_create")
      expect(output).to include('scope="agent"')
      expect(output).to include('policy="auto_approve"')
      expect(output).to include("superseded by system.package_module.create")
    end

    # The dangerous direction. Nothing resolved system.package_module.create
    # before this release: PackageModuleCreateExecutor derived the underscored
    # name, and the dotted spelling reached no gate — it is not in
    # DecisionEngine::SIGNAL_BINDINGS, and FleetAutonomyService's
    # ADVANCEMENT_ACTIONS membership only picks a 4h approval TTL. So an
    # install that loosened the dotted row believing it controlled package
    # module creation is the install whose supply-chain gate this release opens.
    it "WARNS when the surviving dotted row is looser than the verb it shipped at" do
      policy("system.package_module.create", verb: "auto_approve")
      policy("system.package_module_create")

      output = run_up

      expect(output).to include("WARNING")
      expect(output).to include('system.package_module.create = "auto_approve"')
      expect(output).to include("INERT before this release")
    end

    it "does not warn about a surviving row still at its seeded verb" do
      policy("system.package_module.create")
      policy("system.package_module_create")

      expect(run_up).not_to include("WARNING")
    end

    it "says so when there is no surviving dotted row to disclose" do
      policy("system.package_module_create")

      expect(run_up).to include("No system.package_module.create row present")
    end

    it "discloses the surviving row even when there is nothing to retire" do
      policy("system.package_module.create", verb: "auto_approve")

      output = run_up

      expect(output).to include("WARNING")
      expect(output).to include("No system.package_module_create policy rows to retire")
    end

    it "is a no-op on a second run" do
      policy("system.package_module_create")
      run_up

      expect { expect(run_up).to include("No system.package_module_create policy rows to retire") }
        .not_to change { described_class::PolicyRow.count }
    end
  end

  describe "#down" do
    it "refuses to restore a row that would be unregistered and un-saveable" do
      expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    end
  end
end
