# frozen_string_literal: true

require "rails_helper"
require "rake"

# IMP-04ce3762270f — `rails system:storage:smb_rotation_preflight` prints
# System::Storage::SmbRotationPreflight. Read-only; exits non-zero unless the
# verdict is safe_to_rotate or there is nothing to rotate.
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
    status = 0
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

  def smb_backend(version)
    instance = create(:system_node_instance, account: account)
    instance.update_columns(agent_version: version, last_heartbeat_at: 30.seconds.ago)
    create(:file_storage, :smb, :node_mountable, account: account,
      configuration: {
        "mount_path" => "/mnt/test", "server_address" => "192.0.2.10", "share_name" => "storage",
        "username" => "configured-user", "export_host_node_instance_id" => instance.id
      })
    instance
  end

  it "says there are no SMB backends rather than calling an empty fleet safe" do
    output, status = run_task

    expect(output).to include("VERDICT: NO SMB BACKENDS")
    expect(output).not_to include("SAFE TO ROTATE")
    expect(status).to eq(0)
  end

  it "prints SAFE TO ROTATE and exits 0 when every backend passes" do
    instance = smb_backend("2026-09-25-0123456789ab")

    output, status = run_task

    expect(output).to include("VERDICT: SAFE TO ROTATE")
    expect(output).to include(instance.id)
    expect(output).to include("[PASS]")
    expect(output).to include("Zero writes performed")
    expect(status).to eq(0)
  end

  it "prints NOT SAFE with the reason and exits 1 when a backend's agent is too old" do
    smb_backend("2026-09-10-0123456789ab")

    output, status = run_task

    expect(output).to include("VERDICT: NOT SAFE")
    expect(output).to include("[FAIL]")
    expect(output).to include("predates_credential_ref")
    expect(status).to eq(1)
  end

  it "prints UNKNOWN and exits 1 when an agent version cannot be ordered" do
    smb_backend("dev")

    output, status = run_task

    expect(output).to include("VERDICT: UNKNOWN")
    expect(output).to include("[UNKNOWN]")
    expect(output).not_to include("SAFE TO ROTATE")
    expect(status).to eq(1)
  end

  it "emits the structured report as JSON with FORMAT=json" do
    instance = smb_backend("2026-09-25-0123456789ab")
    ENV["FORMAT"] = "json"

    output, status = run_task
    parsed = JSON.parse(output)

    expect(parsed["verdict"]).to eq("safe_to_rotate")
    expect(parsed["nodes"].first["instance_id"]).to eq(instance.id)
    expect(output).not_to include("configured-user")
    expect(status).to eq(0)
  end

  it "creates no task" do
    smb_backend("2026-09-25-0123456789ab")

    expect { run_task }.not_to change { ::System::Task.count }
  end
end
