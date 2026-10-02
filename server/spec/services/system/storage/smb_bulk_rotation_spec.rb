# frozen_string_literal: true

require "rails_helper"

# IMP-2ceb2bd37e71 — operator-run bulk rotation of every live SMB credential.
# The loop only ships the tooling: dry run by default, an explicit confirm that
# restates the planned count, and a hard gate on the step-1 preflight.
RSpec.describe System::Storage::SmbBulkRotation do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:backend_instance) { create(:system_node_instance, account: account) }
  let(:smb_storage) do
    create(:file_storage, :smb, :node_mountable, account: account,
      configuration: {
        "mount_path" => "/mnt/smb-bulk", "server_address" => "192.0.2.10", "share_name" => "storage",
        "export_host_node_instance_id" => backend_instance.id
      })
  end
  let(:verdict) { "safe_to_rotate" }

  before do
    report = System::Storage::SmbRotationPreflight::Report.new(verdict: verdict, summary: {})
    allow(System::Storage::SmbRotationPreflight).to receive(:call).and_return(report)
  end

  def assignment_with_credential(path, confirmed: true)
    consumer = create(:system_node_instance, account: account)
    Sdwan::PeerEnroller.call(network: network, node_instance: consumer)
    assignment = create(:system_storage_assignment, account: account, file_storage_id: smb_storage.id,
                                                    node_instance: consumer, mount_path: path)
    # Creating the assignment already issues its credential (reconcile hook).
    credential = assignment.active_credential || System::Storage::CredentialIssuer.new(assignment: assignment).issue!
    # A consumer the platform can remount: mounted, with a confirmed mount.
    assignment.update_columns(status: "mounted", mounted_credential_id: credential.id) if confirmed
    [ assignment, credential ]
  end

  describe "#plan" do
    it "lists exactly the live SMB credentials, one row per assignment, and writes nothing" do
      a1, c1 = assignment_with_credential("/mnt/b1")
      a2, = assignment_with_credential("/mnt/b2")
      nfs = create(:file_storage, :nfs, :node_mountable, account: account,
        configuration: { "export_path" => "/srv/x", "mount_path" => "/srv/x", "share_path" => "/srv/x",
                         "server_address" => "127.0.0.1",
                         "export_host_node_instance_id" => backend_instance.id })
      nfs_assignment = create(:system_storage_assignment, account: account, file_storage_id: nfs.id,
        node_instance: a1.node_instance, sdwan_network: network, mount_path: "/mnt/nfs")
      System::Storage::CredentialIssuer.new(assignment: nfs_assignment).issue!

      expect { @plan = described_class.new.plan }.not_to change(System::StorageCredential, :count)

      expect(@plan.count).to eq(2)
      expect(@plan.rows.map { |r| r[:assignment_id] }).to contain_exactly(a1.id, a2.id)
      expect(@plan.rows.find { |r| r[:assignment_id] == a1.id }[:credential_id]).to eq(c1.id)
      expect(@plan.rows.first.keys).not_to include(:password, :secret, :payload)
    end

    it "excludes assignments the platform cannot rotate-and-remount, with a reason, instead of rotating them" do
      assignment_with_credential("/mnt/ok")
      unconfirmed, = assignment_with_credential("/mnt/nc", confirmed: false)
      unconfirmed.update_columns(status: "mounted", mounted_credential_id: nil)
      disabled, dc = assignment_with_credential("/mnt/dis")
      disabled.update_columns(enabled: false)
      pending, = assignment_with_credential("/mnt/pen", confirmed: false)
      pending.update_columns(status: "pending")

      plan = described_class.new.plan

      expect(plan.count).to eq(1)
      expect(plan.excluded.to_h { |r| [ r[:assignment_id], r[:reason] ] }).to eq(
        unconfirmed.id => "no_confirmed_mount", disabled.id => "disabled", pending.id => "status_pending"
      )
    end

    it "limits the plan to the first N eligible rows for a pilot and reports how many were eligible" do
      3.times { |i| assignment_with_credential("/mnt/l#{i}") }

      plan = described_class.new(limit: 1).plan

      expect(plan.count).to eq(1)
      expect(plan.total_eligible).to eq(3)
    end

    it "skips credentials rotated at or after SINCE so an interrupted run resumes" do
      _, stale = assignment_with_credential("/mnt/b1")
      _, fresh = assignment_with_credential("/mnt/b2")
      stale.update_columns(last_rotated_at: 10.minutes.ago)
      fresh.update_columns(last_rotated_at: 1.minute.ago)

      plan = described_class.new(since: 5.minutes.ago).plan

      expect(plan.count).to eq(1)
      expect(plan.skipped_recent).to eq(1)
    end

    it "does not run the preflight gate as a side effect of planning" do
      assignment_with_credential("/mnt/b1")

      described_class.new.plan

      expect(System::Storage::SmbRotationPreflight).not_to have_received(:call)
    end
  end

  describe "#execute!" do
    it "refuses without a confirm that restates the planned count, and rotates nothing" do
      assignment_with_credential("/mnt/b1")
      assignment_with_credential("/mnt/b2")

      expect { described_class.new.execute!(confirm_count: nil) }
        .to raise_error(described_class::Refused, /confirm/i)
      expect { described_class.new.execute!(confirm_count: 1) }
        .to raise_error(described_class::Refused, /2/)
      expect(System::StorageCredential.where(status: "rotating")).to be_empty
      expect(System::StorageCredential.count).to eq(2)
    end

    %w[not_safe unknown no_smb_backends].each do |bad|
      context "when the preflight verdict is #{bad}" do
        let(:verdict) { bad }

        it "refuses, names the verdict, and rotates nothing" do
          assignment_with_credential("/mnt/b1")

          expect { described_class.new.execute!(confirm_count: 1) }
            .to raise_error(described_class::Refused, /#{bad}/)
          expect(System::StorageCredential.count).to eq(1)
        end
      end
    end

    it "rotates every planned credential, reports progress per item, and leaves one active credential each" do
      a1, c1 = assignment_with_credential("/mnt/b1")
      a2, c2 = assignment_with_credential("/mnt/b2")
      progress = []

      result = described_class.new.execute!(confirm_count: 2) { |event| progress << event }

      expect(result.rotated.size).to eq(2)
      expect(result.failed).to be_empty
      expect(progress.first).to include(event: "start", total: 2)
      expect(progress.first[:started_at]).to be_present
      expect(progress.drop(1).map { |e| [ e[:index], e[:total] ] }).to eq([ [ 1, 2 ], [ 2, 2 ] ])
      expect(a1.reload.active_credential.id).not_to eq(c1.id)
      expect(a2.reload.active_credential.id).not_to eq(c2.id)
      expect(c1.reload.status).not_to eq("active")
    end

    it "stops at the first failure, records it without credential material, and leaves the rest untouched" do
      a1, = assignment_with_credential("/mnt/b1")
      a2, c2 = assignment_with_credential("/mnt/b2")
      first_id = described_class.new.plan.rows.first[:assignment_id]
      allow_any_instance_of(System::Storage::CredentialIssuer).to receive(:rotate!)
        .and_raise(System::Storage::CredentialIssuer::IssuanceError, "boom")

      result = described_class.new.execute!(confirm_count: 2)

      expect(result.failed.size).to eq(1)
      expect(result.failed.first).to eq(assignment_id: first_id, error_class: "System::Storage::CredentialIssuer::IssuanceError")
      expect(result.failed.first.values.join).not_to include("boom")
      expect(result.not_attempted).to eq(1)
      expect(result.rotated).to be_empty
      expect([ a1, a2 ].map { |a| a.reload.active_credential.present? }).to all(be(true))
      expect(c2.reload.status).to eq("active")
    end
  end

  describe "#execute! when the credential stopped being rotatable after the plan" do
    it "counts it as skipped, not rotated" do
      assignment_with_credential("/mnt/b1")
      plan_rows = described_class.new.plan.rows
      System::StorageCredential.find(plan_rows.first[:credential_id]).update_columns(status: "revoked")
      allow_any_instance_of(described_class).to receive(:plan).and_return(
        described_class::Plan.new(rows: plan_rows, excluded: [], skipped_recent: 0, total_eligible: 1)
      )

      result = described_class.new.execute!(confirm_count: 1)

      expect(result.rotated).to be_empty
      expect(result.skipped.size).to eq(1)
    end
  end

  describe "#verify" do
    it "reports excluded assignments without letting them block COMPLETE" do
      a1, = assignment_with_credential("/mnt/b1")
      other, = assignment_with_credential("/mnt/b2")
      other.update_columns(enabled: false)

      report = described_class.new.verify

      expect(report.excluded.map { |r| r[:assignment_id] }).to eq([ other.id ])
      expect(report.rows.map { |r| r[:assignment_id] }).to eq([ a1.id ])
      expect(report.verdict).to eq("complete")
    end

    it "reports each consumer's remount as confirmed only when mounted_credential_id equals the active credential" do
      a1, c1 = assignment_with_credential("/mnt/b1")
      a2, = assignment_with_credential("/mnt/b2")
      other = System::StorageCredential.create!(storage_assignment: a2, node_instance_id: a2.node_instance_id,
        kind: c1.kind, status: "revoked", metadata: {})
      a2.update_columns(mounted_credential_id: other.id)

      report = described_class.new.verify

      row1 = report.rows.find { |r| r[:assignment_id] == a1.id }
      row2 = report.rows.find { |r| r[:assignment_id] == a2.id }
      expect(row1[:state]).to eq("confirmed")
      expect(row2[:state]).to eq("stale_mount")
      expect(report.verdict).to eq("pending")
      expect(report.counts).to include(confirmed: 1, stale_mount: 1)
    end

    it "flags a consumer still mounted on a superseded credential after rotation" do
      a1, c1 = assignment_with_credential("/mnt/b1")
      a1.update_columns(status: "mounted", mounted_credential_id: c1.id)
      new_cred = System::Storage::CredentialIssuer.new(assignment: a1.reload).rotate!(c1)

      report = described_class.new.verify

      expect(report.rows.first).to include(state: "stale_mount", active_credential_id: new_cred.id)
      expect(report.verdict).to eq("pending")
    end

    it "is complete only when every consumer is confirmed and no credential is still rotating" do
      a1, c1 = assignment_with_credential("/mnt/b1")
      a1.update_columns(status: "mounted", mounted_credential_id: c1.id)

      expect(described_class.new.verify.verdict).to eq("complete")

      c1.update_columns(status: "rotating", rotating_since: 2.hours.ago)
      a1.update_columns(mounted_credential_id: c1.id)
      report = described_class.new.verify
      expect(report.rotating).to eq(1)
      expect(report.verdict).to eq("pending")
    end
  end
end
