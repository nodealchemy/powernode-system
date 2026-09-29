# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260929150000_retire_sdwan_key_rotate_autonomy_policy.rb"
)

# IMP-2e7816b5ee95 — the half the declaration change cannot reach.
#
# system.sdwan_key_rotate was declared auto_approve (SDWAN_REMEDIATION_POLICIES)
# and reconciled onto running installs, with no producer since
# IMP-df40782d3f4d. Dropping the declaration stops it being created and strands
# the rows that exist: PolicyReconciler is absence-only, db/seeds is
# first-boot-only, and the orphan-cleanup seed is admin-account-only. So the
# disposition is a SWEEP, and this migration is it.
#
# Rows go through the migration's OWN local model, not Ai::InterventionPolicy.
RSpec.describe RetireSdwanKeyRotateAutonomyPolicy do
  subject(:migration) { described_class.new }

  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  def policy(category, account_row: account, verb: "auto_approve", scope: "agent")
    described_class::PolicyRow.create!(
      account_id: account_row.id, action_category: category,
      policy: verb, scope: scope, priority: 0, is_active: true
    )
  end

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

  it "retires exactly system.sdwan_key_rotate" do
    expect(described_class::RETIRED_CATEGORIES).to eq(%w[system.sdwan_key_rotate])
  end

  it "is no longer declared, so nothing re-creates what it deletes" do
    declared = System::Governance::PolicyDeclarations::POLICY_SETS.flat_map { |set| set[:policies].keys }

    expect(declared).not_to include("system.sdwan_key_rotate")
    expect(System::Governance::PolicyReconciler::FORMER_OWNERS).not_to have_key("system.sdwan_key_rotate")
  end

  describe "#up" do
    it "retires the rows across ALL accounts, not just the admin one" do
      mine   = policy("system.sdwan_key_rotate")
      theirs = policy("system.sdwan_key_rotate", account_row: other_account, scope: "global")

      expect { run_up }.to change { described_class::PolicyRow.count }.by(-2)

      expect(described_class::PolicyRow.where(id: [ mine.id, theirs.id ])).to be_empty
    end

    it "does not converge a retired verb onto sdwan.peer_key_rotate, and leaves every other row alone" do
      policy("system.sdwan_key_rotate", verb: "auto_approve")
      governed  = policy("sdwan.peer_key_rotate", verb: "require_approval")
      bystander = policy("system.sdwan_peer_remediate", verb: "notify_and_proceed")

      run_up

      expect(described_class::PolicyRow.where(action_category: "system.sdwan_key_rotate")).to be_empty
      expect(governed.reload.policy).to eq("require_approval")
      expect(described_class::PolicyRow.where(action_category: "sdwan.peer_key_rotate").count).to eq(1)
      expect(bystander.reload.policy).to eq("notify_and_proceed")
    end

    it "records the scope, agent and verb of every row it deletes" do
      policy("system.sdwan_key_rotate", verb: "block", scope: "agent")

      output = run_up

      expect(output).to include("retiring system.sdwan_key_rotate")
      expect(output).to include('scope="agent"')
      expect(output).to include('policy="block"')
      expect(output).to include("sdwan.peer_key_rotate")
      expect(output).to include("Retired 1 system.sdwan_key_rotate autonomy policy row(s)")
    end

    it "is a no-op on a second run" do
      policy("system.sdwan_key_rotate")
      run_up

      expect { expect(run_up).to include("No system.sdwan_key_rotate policy rows to retire") }
        .not_to change { described_class::PolicyRow.count }
    end
  end

  describe "#down" do
    it "refuses to restore an unregistered, un-saveable row" do
      expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    end
  end
end
