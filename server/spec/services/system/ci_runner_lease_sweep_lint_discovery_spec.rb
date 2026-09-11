# frozen_string_literal: true

require "rails_helper"

# D1b — the lease deadline that replaces D1's in-process linter timeout
# (campaign 01a08c9b). A lint_discovery lease ends when its ci.lint_discovery
# task finishes or at its deadline. Either way every repository that never
# reported is recorded as not measured with a named reason, and the lease is
# released. Both arms: a lease inside its deadline with a running task is left
# alone.
RSpec.describe System::CiRunnerLeaseSweepService, "lint_discovery leases" do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node) { create(:system_node, account: account, node_template: node_template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:core) { create(:git_repository, account: account, name: "core") }
  let(:docs) { create(:git_repository, account: account, name: "docs") }

  let(:task) do
    System::Task.create!(
      account: account, operable: instance, command: "ci.lint_discovery", status: "running",
      options: { "run_ref" => "pending", "repository_ids" => [ core.id, docs.id ] }
    )
  end

  let!(:lease) do
    System::CiRunnerLease.create!(
      account: account, node_instance: instance, status: "leased", purpose: "lint_discovery",
      build_task_id: task.id, expires_at: 1.hour.from_now,
      metadata: { "repository_ids" => [ core.id, docs.id ], "reported_repository_ids" => [ core.id ] }
    )
  end

  def sweep! = described_class.run!(account: account)

  def records
    AuditLog.where(action: "ai.improvement_discovery.run", account_id: account.id)
  end

  it "leaves a lease alone while its task runs and its deadline has not passed" do
    sweep!

    expect(lease.reload).to be_active
    expect(records).to be_empty
  end

  it "at the deadline, records every repository that never reported and releases the lease" do
    lease.update!(expires_at: 1.minute.ago)

    sweep!

    expect(lease.reload).to be_released
    expect(records.count).to eq(1)
    expect(records.last.metadata).to include(
      "phase" => "ingest", "status" => "not_measured", "reason" => "runner_deadline_passed",
      "run_ref" => lease.id, "unreported_repository_ids" => [ docs.id ]
    )
  end

  it "when the task finishes, records the repositories it never reported and releases the lease" do
    task.update_columns(status: "complete")

    sweep!

    expect(lease.reload).to be_released
    expect(records.last.metadata).to include("status" => "not_measured", "reason" => "runner_did_not_report",
                                             "unreported_repository_ids" => [ docs.id ])
  end

  it "records nothing when every repository reported, and still releases the lease" do
    lease.update!(metadata: lease.metadata.merge("reported_repository_ids" => [ core.id, docs.id ]))
    task.update_columns(status: "complete")

    sweep!

    expect(lease.reload).to be_released
    expect(records).to be_empty
  end
end
