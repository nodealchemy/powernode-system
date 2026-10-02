# frozen_string_literal: true

require "rails_helper"
require "rake"

# IMP-ecb2cbef7173 — `rails system:storage:scrub_smb_task_secrets` re-runs the
# scrub migration 20261001120000 without going through db:migrate. Exits 0
# when nothing is left, 2 when candidate rows remain, 1 when the scrub
# aborted. Never touches schema_migrations.
RSpec.describe "system:storage:scrub_smb_task_secrets rake task" do
  task_name = "system:storage:scrub_smb_task_secrets"

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?(task_name)
  end

  let(:task) { Rake::Task[task_name] }
  let(:account) { create(:account) }
  let(:marker) { "synthetic-not-a-real-smb-password-#{SecureRandom.hex(4)}" }

  before { task.reenable }

  def run_task
    original_out = $stdout
    $stdout = StringIO.new
    status = nil # stays nil when the task returns without calling exit
    begin
      task.invoke
    rescue SystemExit => e
      status = e.status
    end
    [ $stdout.string, status ]
  ensure
    $stdout = original_out
  end

  def smb_task!(options)
    task = create(:system_task, account: account, command: "storage.smb_user.apply", status: "failed")
    task.update_columns(options: options)
    task
  end

  def stamped_versions
    ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations ORDER BY version")
  end

  it "is a clean no-op, exit 0, when no row carries a secret, and names the database it read" do
    output, status = run_task

    expect(output).to include("environment=#{Rails.env} database=#{ActiveRecord::Base.connection_db_config.database}")
    expect(output).to include("nothing to scrub")
    expect(output).to include("scrubbed=0 left=0 aborted_by=none")
    expect(output).to include("OUTCOME: CLEAN")
    expect(status).to be_nil
  end

  it "scrubs a row, prints the count and never the value, and exits 0" do
    row = smb_task!("action" => "create", "username" => "u", "password" => marker)

    output, status = run_task

    expect(output).to include("scrubbed 1 storage.smb_user.apply row(s)")
    expect(output).to include("scrubbed=1 left=0 aborted_by=none")
    expect(output).not_to include(marker)
    expect(status).to be_nil
    expect(row.reload.options["password"]).to eq(ScrubSmbUserApplyTaskSecrets::SENTINEL)
  end

  it "exits 2 and says so when candidate rows remain" do
    allow_any_instance_of(ScrubSmbUserApplyTaskSecrets).to receive(:scrub)
      .and_return(ScrubSmbUserApplyTaskSecrets::Outcome.new(scrubbed: 2, left: 1, aborted_by: nil))

    output, status = run_task

    expect(output).to include("scrubbed=2 left=1 aborted_by=none")
    expect(output).to include("OUTCOME: LEFTOVER — 1 candidate row(s)")
    expect(status).to eq(2)
  end

  it "exits 1 and names the exception class when the scrub aborted" do
    allow_any_instance_of(ScrubSmbUserApplyTaskSecrets).to receive(:scrub)
      .and_return(ScrubSmbUserApplyTaskSecrets::Outcome.new(scrubbed: 0, left: nil, aborted_by: "ActiveRecord::LockWaitTimeout"))

    output, status = run_task

    expect(output).to include("scrubbed=0 left=unknown aborted_by=ActiveRecord::LockWaitTimeout")
    expect(output).to include("OUTCOME: ABORTED — the scrub stopped on ActiveRecord::LockWaitTimeout")
    expect(status).to eq(1)
  end

  it "never un-stamps or stamps the migration" do
    smb_task!("action" => "create", "username" => "u", "password" => marker)
    before = stamped_versions

    run_task

    expect(stamped_versions).to eq(before)
  end

  it "restores the migration verbosity flag it turned on" do
    ActiveRecord::Migration.verbose = false

    run_task

    expect(ActiveRecord::Migration.verbose).to be(false)
  ensure
    ActiveRecord::Migration.verbose = true
  end
end
