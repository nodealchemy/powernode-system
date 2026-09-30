# frozen_string_literal: true

require "rails_helper"

# IMP-a366d6fb6b80 - a scheme-crossing SMB rotation leaves the OUTGOING
# credential "rotating" (its samba user still live) until the consumer confirms
# a remount. With no clock, a node that never confirmed kept the old user and
# password valid forever. The sweeper retires such a credential once it has
# been rotating longer than the operator's window, through the SAME
# CredentialIssuer path a confirmation uses.
RSpec.describe System::Storage::RotatingCredentialSweeper do
  let(:account) { create(:account) }
  let(:node_instance) { create(:system_node_instance, account: account) }
  let(:backend_instance) { create(:system_node_instance, account: account) }

  before do
    # The forced username lives in metadata so a scheme-crossing rotation can
    # be staged without real Vault (same stand-in credential_issuer_spec uses).
    allow_any_instance_of(System::StorageCredential)
      .to receive(:vault_credentials) { |instance| instance.metadata.slice("username") }
  end

  def smb_storage(share:)
    create(:file_storage, :smb, :node_mountable, account: account,
      configuration: {
        "mount_path" => "/mnt/#{share}", "server_address" => "192.168.1.210",
        "share_name" => share, "export_host_node_instance_id" => backend_instance.id
      })
  end

  def build_assignment_and_credential(share:, username:)
    assignment = create(:system_storage_assignment,
      account: account, file_storage_id: smb_storage(share: share).id,
      node_instance: node_instance, mount_path: "/mnt/#{share}")
    assignment.storage_credentials.update_all(status: "revoked")
    credential = System::Storage::CredentialIssuer.new(assignment: assignment).issue!
    credential.update_columns(metadata: credential.metadata.merge("username" => username))
    [ assignment, credential ]
  end

  # Rotates credential A (old-scheme username, so the rotation crosses schemes)
  # and returns [assignment, old_credential, new_credential].
  def rotated_assignment(share:, username:)
    assignment, old = build_assignment_and_credential(share: share, username: username)
    successor = System::Storage::CredentialIssuer.new(assignment: assignment).rotate!(old)
    [ assignment, old.reload, successor ]
  end

  def delete_tasks_for(credential)
    System::Task.where(command: "storage.smb_user.apply")
                .where("options ->> 'action' = 'delete'")
                .select { |t| t.options.dig("credential", "id") == credential.id }
  end

  def force_audits
    AuditLog.where(action: described_class::AUDIT_ACTION)
  end

  def force_events
    System::FleetEvent.where(kind: described_class::EVENT_KIND)
  end

  describe "StorageCredential#mark_rotating!" do
    it "stamps rotating_since when a credential enters rotating" do
      _assignment, old, _successor = rotated_assignment(share: "s-stamp", username: "n-legacy-stamp")

      expect(old.status).to eq("rotating")
      expect(old.rotating_since).to be_within(1.minute).of(Time.current)
    end
  end

  describe ".sweep_assignment!" do
    it "retires a credential rotating past the window: revoked, delete task, audit row, event naming the node" do
      assignment, old, successor = rotated_assignment(share: "s-past", username: "n-legacy-past")
      old.update_columns(rotating_since: 25.hours.ago)

      result = described_class.sweep_assignment!(assignment)

      expect(result[:retired]).to eq([ old.id ])
      expect(old.reload.status).to eq("revoked")
      expect(successor.reload.status).to eq("active")

      tasks = delete_tasks_for(old)
      expect(tasks.size).to eq(1)
      expect(tasks.first.options["username"]).to eq("n-legacy-past")

      audit = force_audits.sole
      expect(audit.resource_type).to eq("System::StorageCredential")
      expect(audit.resource_id).to eq(old.id)
      expect(audit.account_id).to eq(account.id)
      expect(audit.severity).to eq("high")
      expect(audit.metadata).to include(
        "storage_assignment_id" => assignment.id,
        "node_instance_id" => node_instance.id,
        "node_instance_name" => node_instance.name,
        "successor_id" => successor.id
      )
      expect(audit.metadata["delete_task_id"]).to eq(tasks.first.id)

      event = force_events.sole
      expect(event.severity).to eq("high")
      expect(event.node_instance_id).to eq(node_instance.id)
      expect(event.payload).to include(
        "node_instance_name" => node_instance.name,
        "storage_assignment_id" => assignment.id,
        "credential_id" => old.id
      )
    end

    it "leaves a credential still inside the window untouched" do
      assignment, old, _successor = rotated_assignment(share: "s-inside", username: "n-legacy-inside")
      old.update_columns(rotating_since: 23.hours.ago)

      result = described_class.sweep_assignment!(assignment)

      expect(result[:retired]).to be_empty
      expect(old.reload.status).to eq("rotating")
      expect(delete_tasks_for(old)).to be_empty
      expect(force_audits).to be_empty
      expect(force_events).to be_empty
    end

    it "does not touch a credential retired by the ordinary path (confirmation) and raises no forced-retirement alert" do
      assignment, old, successor = rotated_assignment(share: "s-confirm", username: "n-legacy-confirm")
      # Freshly rotating, nowhere near the window: a confirmation retires it at once.
      System::Storage::CredentialIssuer.new(assignment: assignment).retire_rotating_smb_credentials!(successor)

      expect(old.reload.status).to eq("revoked")
      expect(delete_tasks_for(old).size).to eq(1)
      expect(force_audits).to be_empty
      expect(force_events).to be_empty
    end

    context "with a legacy row that has no rotating_since" do
      it "stamps it instead of retiring it instantly, then retires it once the window has run from the stamp" do
        assignment, old, _successor = rotated_assignment(share: "s-legacy", username: "n-legacy-legacy")
        old.update_columns(rotating_since: nil)

        first = described_class.sweep_assignment!(assignment)

        expect(first[:retired]).to be_empty
        expect(first[:stamped]).to eq([ old.id ])
        expect(old.reload.status).to eq("rotating")
        expect(old.rotating_since).to be_within(1.minute).of(Time.current)
        expect(delete_tasks_for(old)).to be_empty

        travel_to(25.hours.from_now) do
          second = described_class.sweep_assignment!(assignment)

          expect(second[:retired]).to eq([ old.id ])
          expect(old.reload.status).to eq("revoked")
        end
      end
    end

    it "is idempotent: a second sweep neither double-retires, nor re-creates the delete task, nor re-alerts" do
      assignment, old, _successor = rotated_assignment(share: "s-idem", username: "n-legacy-idem")
      old.update_columns(rotating_since: 30.hours.ago)

      described_class.sweep_assignment!(assignment)
      again = described_class.sweep_assignment!(assignment)

      expect(again[:retired]).to be_empty
      expect(delete_tasks_for(old).size).to eq(1)
      expect(force_audits.count).to eq(1)
      expect(force_events.count).to eq(1)
    end

    it "retires only the overdue credential: a newer rotating one on the same assignment, and another assignment's, are left alone" do
      assignment, cred_a = build_assignment_and_credential(share: "s-scope", username: "n-legacy-scope-a")
      issuer = System::Storage::CredentialIssuer.new(assignment: assignment)
      cred_b = issuer.rotate!(cred_a)
      cred_b.update_columns(metadata: cred_b.metadata.merge("username" => "n-legacy-scope-b"))
      cred_c = issuer.rotate!(cred_b)
      cred_a.reload.update_columns(rotating_since: 30.hours.ago)  # stale
      cred_b.reload.update_columns(rotating_since: 1.hour.ago)    # current rotation, in window

      other_assignment, other_old, = rotated_assignment(share: "s-scope-other", username: "n-legacy-scope-other")
      other_old.update_columns(rotating_since: 40.hours.ago)

      result = described_class.sweep_assignment!(assignment)

      expect(result[:retired]).to eq([ cred_a.id ])
      expect(cred_a.reload.status).to eq("revoked")
      expect(cred_b.reload.status).to eq("rotating")
      expect(cred_c.reload.status).to eq("active")
      expect(other_old.reload.status).to eq("rotating") # a different assignment is not this sweep's
      expect(delete_tasks_for(cred_b)).to be_empty
      expect(delete_tasks_for(other_old)).to be_empty
      expect(other_assignment.storage_credentials.rotating).to contain_exactly(other_old)
    end

    it "does not retire a credential a racing confirmation already retired (state-guarded under the row lock)" do
      assignment, old, successor = rotated_assignment(share: "s-race", username: "n-legacy-race")
      old.update_columns(rotating_since: 30.hours.ago)
      stale_view = System::StorageCredential.find(old.id) # what a sweep would have read before the confirmation landed

      System::Storage::CredentialIssuer.new(assignment: assignment).retire_rotating_smb_credentials!(successor)
      retired = System::Storage::CredentialIssuer.new(assignment: assignment)
                                                 .retire_overdue_rotating_smb_credential!(stale_view, cutoff: 24.hours.ago)

      expect(retired).to be(false)
      expect(delete_tasks_for(old).size).to eq(1) # the confirmation's, and only that
      expect(force_audits).to be_empty
    end

    it "does not retire a credential whose clock was restarted after the sweep read it" do
      assignment, old, _successor = rotated_assignment(share: "s-restart", username: "n-legacy-restart")
      old.update_columns(rotating_since: 30.hours.ago)
      stale_view = System::StorageCredential.find(old.id)
      old.update_columns(rotating_since: 1.minute.ago)

      retired = System::Storage::CredentialIssuer.new(assignment: assignment)
                                                 .retire_overdue_rotating_smb_credential!(stale_view, cutoff: 24.hours.ago)

      expect(retired).to be(false)
      expect(old.reload.status).to eq("rotating")
    end

    it "honours a configured window" do
      assignment, old, = rotated_assignment(share: "s-window", username: "n-legacy-window")
      old.update_columns(rotating_since: 3.hours.ago)
      SiteSetting.set(described_class::SETTING_KEY, 2, setting_type: "integer")

      expect(described_class.sweep_assignment!(assignment)[:retired]).to eq([ old.id ])
    end

    it "reports a credential whose retirement raised, and leaves it rotating for the next tick" do
      assignment, old, = rotated_assignment(share: "s-fail", username: "n-legacy-fail")
      old.update_columns(rotating_since: 30.hours.ago)
      allow_any_instance_of(System::Storage::SmbUserManager).to receive(:deprovision_user!).and_raise("backend unreachable")

      result = described_class.sweep_assignment!(assignment)

      expect(result[:retired]).to be_empty
      expect(result[:failed]).to eq([ old.id ])
      expect(old.reload.status).to eq("rotating")
      expect(force_audits).to be_empty
    end
  end

  describe "when a forced retirement fails" do
    def failed_events
      System::FleetEvent.where(kind: described_class::FAILED_EVENT_KIND)
    end

    it "raises one HIGH alert naming the node and the credential" do
      assignment, old, = rotated_assignment(share: "s-alert", username: "n-legacy-alert")
      old.update_columns(rotating_since: 30.hours.ago)
      allow_any_instance_of(System::Storage::SmbUserManager).to receive(:deprovision_user!).and_raise("backend unreachable")

      described_class.sweep_assignment!(assignment)

      event = failed_events.sole
      expect(event.severity).to eq("high")
      expect(event.node_instance_id).to eq(node_instance.id)
      expect(event.payload).to include(
        "credential_id" => old.id,
        "node_instance_name" => node_instance.name,
        "storage_assignment_id" => assignment.id,
        "error_class" => "RuntimeError"
      )
      expect(event.payload.to_s).not_to include("backend unreachable")
    end

    it "does not re-alert for the same credential inside the window, and alerts again once it has passed" do
      assignment, old, = rotated_assignment(share: "s-dedup", username: "n-legacy-dedup")
      old.update_columns(rotating_since: 30.hours.ago)
      allow_any_instance_of(System::Storage::SmbUserManager).to receive(:deprovision_user!).and_raise("backend unreachable")

      described_class.sweep_assignment!(assignment)
      described_class.sweep_assignment!(assignment)
      expect(failed_events.count).to eq(1)

      travel_to(25.hours.from_now) do
        described_class.sweep_assignment!(assignment)
        expect(failed_events.count).to eq(2)
      end
    end

    it "alerts per credential: a second failing credential is not suppressed by the first's alert" do
      assignment, cred_a = build_assignment_and_credential(share: "s-two", username: "n-legacy-two-a")
      issuer = System::Storage::CredentialIssuer.new(assignment: assignment)
      cred_b = issuer.rotate!(cred_a)
      cred_b.update_columns(metadata: cred_b.metadata.merge("username" => "n-legacy-two-b"))
      issuer.rotate!(cred_b)
      [ cred_a, cred_b ].each { |c| c.reload.update_columns(rotating_since: 30.hours.ago) }
      allow_any_instance_of(System::Storage::SmbUserManager).to receive(:deprovision_user!).and_raise("backend unreachable")

      described_class.sweep_assignment!(assignment)

      expect(failed_events.map { |e| e.payload["credential_id"] }).to contain_exactly(cred_a.id, cred_b.id)
    end

    it "does not let a failing alert emit mask the failure it reports" do
      assignment, old, = rotated_assignment(share: "s-alertfail", username: "n-legacy-alertfail")
      old.update_columns(rotating_since: 30.hours.ago)
      allow_any_instance_of(System::Storage::SmbUserManager).to receive(:deprovision_user!).and_raise("backend unreachable")
      allow(System::Fleet::EventBroadcaster).to receive(:emit!).and_raise("bus down")

      result = described_class.sweep_assignment!(assignment)

      expect(result[:failed]).to eq([ old.id ])
    end

    it "rolls the revocation and its delete task back when the audit write fails" do
      assignment, old, = rotated_assignment(share: "s-rollback", username: "n-legacy-rollback")
      old.update_columns(rotating_since: 30.hours.ago)
      allow(AuditLog).to receive(:log_action).and_raise(ActiveRecord::RecordInvalid)

      result = described_class.sweep_assignment!(assignment)

      expect(result[:retired]).to be_empty
      expect(result[:failed]).to eq([ old.id ])
      expect(old.reload.status).to eq("rotating")
      expect(delete_tasks_for(old)).to be_empty
      expect(force_events).to be_empty
    end
  end

  describe "when the retirement commits but its alert cannot be emitted" do
    it "still reports the credential as retired, and records the lost alert instead of failing" do
      assignment, old, = rotated_assignment(share: "s-lostalert", username: "n-legacy-lostalert")
      old.update_columns(rotating_since: 30.hours.ago)
      allow(System::Fleet::EventBroadcaster).to receive(:emit!).and_raise("bus down")

      result = described_class.sweep_assignment!(assignment)

      expect(result[:retired]).to eq([ old.id ])
      expect(result[:failed]).to be_empty
      expect(result[:alert_failed]).to eq([ old.id ])
      expect(old.reload.status).to eq("revoked")
      expect(force_audits.count).to eq(1)
    end

    it "records a swallowed emit (EventBroadcaster returned nil) the same way" do
      assignment, old, = rotated_assignment(share: "s-nilalert", username: "n-legacy-nilalert")
      old.update_columns(rotating_since: 30.hours.ago)
      allow(System::Fleet::EventBroadcaster).to receive(:emit!).and_return(nil)

      result = described_class.sweep_assignment!(assignment)

      expect(result).to include(retired: [ old.id ], failed: [], alert_failed: [ old.id ])
    end
  end

  describe ".window" do
    it "defaults to 24 hours when unset" do
      expect(described_class.window).to eq(24.hours)
    end

    it "reads the SiteSetting in hours" do
      SiteSetting.set(described_class::SETTING_KEY, 48, setting_type: "integer")

      expect(described_class.window).to eq(48.hours)
    end

    it "falls back to the default for a stored value that bypassed validation (garbage, zero, negative, over bound)" do
      [ "abc", "0", "-5", "169", "" ].each do |bad|
        SiteSetting.where(key: described_class::SETTING_KEY).delete_all
        SiteSetting.insert!({ key: described_class::SETTING_KEY, value: bad.presence || "x", setting_type: "string" })

        expect(described_class.window).to eq(24.hours), "stored #{bad.inspect} should not change the window"
      end
    end
  end

  describe "the SiteSetting value check" do
    it "refuses zero, negative, non-numeric, fractional and over-bound values" do
      [ 0, -1, "abc", "1.5", "12h", 169, 100_000 ].each do |bad|
        setting = SiteSetting.new(key: described_class::SETTING_KEY, value: bad.to_s, setting_type: "integer")

        expect(setting).not_to be_valid, "#{bad.inspect} should be refused"
        expect(setting.errors[:value]).not_to be_empty
      end
    end

    it "accepts the bounds and a typical value" do
      [ 1, 24, 168 ].each do |good|
        SiteSetting.where(key: described_class::SETTING_KEY).delete_all
        expect(SiteSetting.set(described_class::SETTING_KEY, good, setting_type: "integer")).to be_persisted
      end
    end
  end

  describe "audit action registration" do
    it "registers the forced-retirement action on the dynamic union" do
      expect(AuditActions.valid_action?(described_class::AUDIT_ACTION)).to be(true)
    end
  end
end
