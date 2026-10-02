# frozen_string_literal: true

require "rails_helper"
require "rake"

# IMP-2ceb2bd37e71 — the operator entry points for System::Storage::SmbBulkRotation.
# Dry run by default; CONFIRM=<count> executes; the preflight gates execution.
RSpec.describe "SMB bulk rotation rake tasks" do
  rotate_name = "system:storage:smb_rotate_all"
  verify_name = "system:storage:smb_rotate_verify"

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?(rotate_name)
  end

  before do
    Rake::Task[rotate_name].reenable
    Rake::Task[verify_name].reenable
    report = System::Storage::SmbRotationPreflight::Report.new(verdict: verdict, summary: {})
    allow(System::Storage::SmbRotationPreflight).to receive(:call).and_return(report)
  end
  after { %w[CONFIRM SINCE LIMIT].each { |k| ENV.delete(k) } }

  let(:verdict) { "safe_to_rotate" }
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:backend_instance) { create(:system_node_instance, account: account) }
  let(:smb_storage) do
    create(:file_storage, :smb, :node_mountable, account: account,
      configuration: { "mount_path" => "/mnt/rk", "server_address" => "192.0.2.10", "share_name" => "storage",
                       "export_host_node_instance_id" => backend_instance.id })
  end

  def seed_assignments(count)
    count.times.map do |i|
      consumer = create(:system_node_instance, account: account)
      Sdwan::PeerEnroller.call(network: network, node_instance: consumer)
      assignment = create(:system_storage_assignment, account: account, file_storage_id: smb_storage.id,
                                                      node_instance: consumer, mount_path: "/mnt/rk#{i}")
      assignment.update_columns(status: "mounted", mounted_credential_id: assignment.active_credential.id)
      assignment
    end
  end

  def run(name)
    original = $stdout
    $stdout = StringIO.new
    status = nil
    begin
      Rake::Task[name].invoke
    rescue SystemExit => e
      status = e.status
    end
    [ $stdout.string, status ]
  ensure
    $stdout = original
  end

  describe "smb_rotate_all" do
    it "is a dry run by default: states the count and database, rotates nothing, tells how to confirm" do
      seed_assignments(2)

      output = nil
      expect { output, = run(rotate_name) }.not_to change(System::StorageCredential, :count)

      expect(output).to include("DRY RUN")
      expect(output).to include("This will rotate 2 SMB credential(s)")
      expect(output).to include("database=#{ActiveRecord::Base.connection_db_config.database}")
      expect(output).to include("CONFIRM=2")
      expect(output).to include("preflight: safe_to_rotate")
    end

    it "shows the first 3 and the last 1 of a larger set" do
      assignments = seed_assignments(6)

      output, = run(rotate_name)

      shown = assignments.map(&:id).select { |id| output.include?(id) }
      expect(shown).to match_array(assignments.first(3).map(&:id) + [ assignments.last.id ])
      expect(output).to include("... 2 more")
    end

    it "executes only with CONFIRM equal to the planned count and reports progress and a verify hint" do
      seed_assignments(2)
      ENV["CONFIRM"] = "2"

      output, status = run(rotate_name)

      expect(output).to include("[1/2]")
      expect(output).to include("[2/2]")
      expect(output).to include("rotated=2 skipped=0 failed=0 not_attempted=0")
      expect(output).to include("system:storage:smb_rotate_verify")
      expect(status).to be_nil
    end

    it "refuses a mismatched CONFIRM with exit 3 and rotates nothing" do
      seed_assignments(2)
      ENV["CONFIRM"] = "5"

      output = nil
      status = nil
      expect { output, status = run(rotate_name) }.not_to change(System::StorageCredential, :count)

      expect(output).to include("REFUSED")
      expect(status).to eq(3)
    end

    context "when the preflight is not safe" do
      let(:verdict) { "not_safe" }

      it "refuses to execute even with the right CONFIRM, and the dry run says it would be refused" do
        seed_assignments(1)

        dry, = run(rotate_name)
        expect(dry).to include("preflight: not_safe")
        expect(dry).to include("would be REFUSED")

        Rake::Task[rotate_name].reenable
        ENV["CONFIRM"] = "1"
        output, status = run(rotate_name)
        expect(output).to include("REFUSED").and include("not_safe")
        expect(status).to eq(3)
      end
    end

    it "exits 1 and names the unrotated remainder when a rotation fails" do
      seed_assignments(2)
      ENV["CONFIRM"] = "2"
      allow_any_instance_of(System::Storage::CredentialIssuer).to receive(:rotate!).and_raise(StandardError, "boom")

      output, status = run(rotate_name)

      expect(output).to include("rotated=0 skipped=0 failed=1 not_attempted=1")
      expect(output).to include("SINCE=")
      expect(status).to eq(1)
    end

    it "prints started_at before the first rotation so an interrupted run can resume" do
      seed_assignments(1)
      ENV["CONFIRM"] = "1"

      output, = run(rotate_name)

      expect(output.index("started_at=")).to be < output.index(" rotated\n")
    end

    it "rotates only LIMIT credentials and states the pilot" do
      seed_assignments(3)
      ENV["LIMIT"] = "1"
      ENV["CONFIRM"] = "1"

      output, = run(rotate_name)

      expect(output).to include("limit=1 of 3 eligible")
      expect(output).to include("rotated=1 skipped=0 failed=0")
    end

    it "lists excluded assignments in the dry run" do
      assignment, = seed_assignments(1)
      assignment.update_columns(enabled: false)

      output, = run(rotate_name)

      expect(output).to include("[EXCLUDED] assignment=#{assignment.id}")
      expect(output).to include("reason=disabled")
      expect(output).to include("This will rotate 0 SMB credential(s)")
    end

    it "rejects a SINCE in the future and a non-positive LIMIT with exit 3" do
      ENV["SINCE"] = (Time.current + 1.day).iso8601
      _, status = run(rotate_name)
      expect(status).to eq(3)

      Rake::Task[rotate_name].reenable
      ENV.delete("SINCE")
      ENV["LIMIT"] = "0"
      _, status = run(rotate_name)
      expect(status).to eq(3)
    end

    it "never prints the exception message of a failed rotation" do
      seed_assignments(1)
      ENV["CONFIRM"] = "1"
      allow_any_instance_of(System::Storage::CredentialIssuer).to receive(:rotate!)
        .and_raise(StandardError, "DETAIL: Failing row contains (hunter2)")

      output, = run(rotate_name)

      expect(output).to include("FAILED").and include("StandardError")
      expect(output).not_to include("hunter2")
    end

    it "rejects an unparseable SINCE with exit 3" do
      ENV["SINCE"] = "yesterday-ish"

      output, status = run(rotate_name)

      expect(output).to include("SINCE")
      expect(status).to eq(3)
    end
  end

  describe "smb_rotate_verify" do
    it "exits 1 while any consumer is still on the superseded credential and lists it" do
      assignment, = seed_assignments(1)
      old = assignment.active_credential
      System::Storage::CredentialIssuer.new(assignment: assignment.reload).rotate!(old)

      output, status = run(verify_name)

      expect(output).to include("VERDICT: PENDING")
      expect(output).to include(assignment.id)
      expect(status).to eq(1)
    end

    it "exits 0 once every consumer confirmed the active credential" do
      assignment, = seed_assignments(1)
      assignment.update_columns(status: "mounted", mounted_credential_id: assignment.active_credential.id)

      output, status = run(verify_name)

      expect(output).to include("VERDICT: COMPLETE")
      expect(status).to be_nil
    end
  end
end
