# frozen_string_literal: true

require "rails_helper"
require "rake"

# IMP-04ce3762270f — `rails system:storage:smb_rotation_preflight` prints
# System::Storage::SmbRotationPreflight. Read-only; exits non-zero unless the
# verdict is safe_to_rotate (2 for an empty fleet, 1 otherwise).
RSpec.describe "system:storage:smb_rotation_preflight rake task" do
  task_name = "system:storage:smb_rotation_preflight"

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?(task_name)
  end

  let(:task) { Rake::Task[task_name] }

  before { task.reenable }
  after { ENV.delete("FORMAT") }

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

  let(:account) { create(:account) }

  def smb_backend(version, owner: account, instance: nil)
    instance ||= create(:system_node_instance, account: account).tap do |created|
      created.update_columns(agent_version: version, last_heartbeat_at: 30.seconds.ago)
    end
    smb_storage(instance.id, owner: owner)
    instance
  end

  def smb_storage(instance_id, owner: account)
    create(:file_storage, :smb, :node_mountable, account: owner,
      configuration: {
        "mount_path" => "/mnt/test", "server_address" => "192.0.2.10", "share_name" => "storage",
        "username" => "configured-user", "export_host_node_instance_id" => instance_id
      }.compact)
  end

  it "exits 2 on an empty fleet and names the database, since no SMB storage usually means the wrong one" do
    output, status = run_task

    expect(output).to include("VERDICT: NO SMB BACKENDS")
    expect(output).not_to include("SAFE TO ROTATE")
    expect(output).to include("environment=#{Rails.env} database=#{ActiveRecord::Base.connection_db_config.database}")
    expect(status).to eq(2)
  end

  it "prints SAFE TO ROTATE and does not call exit when every backend passes" do
    instance = smb_backend("2026-09-25-0123456789ab")
    output, status = run_task

    expect(output).to include("VERDICT: SAFE TO ROTATE — every backend passes both checks (see basis per row)")
    expect(output).not_to include("proven pass")
    expect(output).to include(instance.id)
    expect(output).to include("[PASS]")
    expect(output).to include("status=active")
    expect(output).to include("nodes_pass=1 nodes_fail=0 nodes_unknown=0 unresolved_storages=0")
    expect(output).to include("Zero writes performed")
    expect(status).to be_nil
  end

  it "states the scan scope and the limit of a build_date pass in the header" do
    output, = run_task

    expect(output).to include("Every SMB storage is scanned, whatever its status and whether or not it has credentials")
    expect(output).to include("sound for a build from the default branch, not for a branch build")
  end

  it "lists the agent shas seen with the command that settles a build_date pass" do
    smb_backend("2026-09-25-0123456789ab")

    output, = run_task

    expect(output).to include("git merge-base --is-ancestor 8f6aeae26de9 0123456789ab")
  end

  it "prints NOT SAFE with the reason and a hint, and exits 1, when a backend's agent is too old" do
    smb_backend("2026-09-10-0123456789ab")

    output, status = run_task

    expect(output).to include("VERDICT: NOT SAFE")
    expect(output).to include("[FAIL]")
    expect(output).to include("predates_credential_ref")
    expect(output).to include("hint: Upgrade")
    expect(status).to eq(1)
  end

  it "prints UNKNOWN with a hint and exits 1 when an agent version cannot be ordered" do
    smb_backend("dev")

    output, status = run_task

    expect(output).to include("VERDICT: UNKNOWN")
    expect(output).to include("[UNKNOWN]")
    expect(output).to include("hint: Redeploy a stamped module build")
    expect(output).not_to include("SAFE TO ROTATE")
    expect(status).to eq(1)
  end

  it "prints the cross-account failure with both accounts and exits 1" do
    other_account = create(:account)
    instance = smb_backend("2026-09-25-0123456789ab")
    smb_backend(nil, owner: other_account, instance: instance)

    output, status = run_task

    expect(output).to include("accounts: fail — serves_multiple_accounts")
    expect(output).to include(account.id, other_account.id)
    expect(output).to include("VERDICT: NOT SAFE")
    expect(status).to eq(1)
  end

  it "lists a storage whose backend instance does not exist as a failure" do
    missing_id = SecureRandom.uuid
    storage = smb_storage(missing_id)

    output, status = run_task

    expect(output).to include("SMB storages with no resolvable backend instance (1)")
    expect(output).to include("[FAIL] storage=#{storage.id}")
    expect(output).to include("backend_instance=#{missing_id} — backend_instance_not_found")
    expect(status).to eq(1)
  end

  it "lists a storage with no backend instance configured as unknown, with a hint" do
    storage = smb_storage(nil)

    output, status = run_task

    expect(output).to include("[UNKNOWN] storage=#{storage.id}")
    expect(output).to include("backend_instance=none — no_backend_instance_configured")
    expect(output).to include("external SMB server")
    expect(output).to include("VERDICT: UNKNOWN")
    expect(status).to eq(1)
  end

  it "emits the structured report as JSON with FORMAT=json" do
    instance = smb_backend("2026-09-25-0123456789ab")
    ENV["FORMAT"] = "json"

    output, status = run_task
    parsed = JSON.parse(output)

    expect(parsed["verdict"]).to eq("safe_to_rotate")
    expect(parsed["environment"]).to eq(Rails.env.to_s)
    expect(parsed["database"]).to eq(ActiveRecord::Base.connection_db_config.database)
    expect(parsed["nodes"].first["instance_id"]).to eq(instance.id)
    expect(output).not_to include("configured-user")
    expect(status).to be_nil
  end

  it "exits 2 in JSON mode too on an empty fleet" do
    ENV["FORMAT"] = "json"

    output, status = run_task

    expect(JSON.parse(output)["verdict"]).to eq("no_smb_backends")
    expect(status).to eq(2)
  end

  it "creates no task" do
    smb_backend("2026-09-25-0123456789ab")

    expect { run_task }.not_to change { ::System::Task.count }
  end
end
