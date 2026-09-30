# frozen_string_literal: true

require "rails_helper"

# Audit F3-07 — StorageAssignmentDriftSensor was dead code: never registered
# in FleetAutonomyService::SENSORS, and its sweep mutated the DB directly in
# violation of the BaseSensor read-side contract. It is now a real sensor:
# sense only EMITS signals; reconciliation runs through the DecisionEngine's
# remediation applier behind the system.storage_assignment_reconcile gate.
RSpec.describe System::Fleet::Sensors::StorageAssignmentDriftSensor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:file_storage) { create(:file_storage, :nfs, :node_mountable, account: account) }

  let(:sensor) { described_class.new(account: account) }

  # The assignment's own after_commit triggers reconciliation (which stamps
  # last_status_at) — update_columns puts the row into the stale state the
  # sensor exists to catch, exactly like an agent that never responded.
  def stale_assignment!(last_status_at:)
    create(:system_storage_assignment, account: account, node_instance: instance,
           file_storage_id: file_storage.id).tap do |a|
      a.update_columns(status: "degraded", last_status_at: last_status_at)
    end
  end

  it "emits a storage_assignment_drift signal for an assignment stale past the window" do
    assignment = stale_assignment!(last_status_at: 10.minutes.ago)

    signals = sensor.sense

    expect(signals.size).to eq(1)
    expect(signals.first.kind).to eq("system.storage_assignment_drift")
    expect(signals.first.payload["storage_assignment_id"] || signals.first.payload[:storage_assignment_id])
      .to eq(assignment.id)
  end

  it "does not emit for assignments with a fresh status" do
    stale_assignment!(last_status_at: 1.minute.ago)

    expect(sensor.sense).to be_empty
  end

  it "is pure read-side: sensing does not invoke reconciliation" do
    stale_assignment!(last_status_at: 10.minutes.ago)
    allow(::System::Storage::AssignmentReconciliationService).to receive(:reconcile_assignment!)

    expect(sensor.sense.size).to eq(1)

    expect(::System::Storage::AssignmentReconciliationService).not_to have_received(:reconcile_assignment!)
  end

  # IMP-e48612a32273 — the .or(mount_credential_mismatch) safety net: a
  # MOUNTED assignment (never caught by pending_reconcile alone — see that
  # scope's own comment) whose mounted_credential_id no longer matches its
  # active_credential is a missed/never-fired remount-on-completion
  # callback. Still gated on the SAME staleness window as every other
  # signal this sensor emits (see #sense's own `.where("last_status_at
  # IS NULL OR ...")`, applied AFTER the .or) — a freshly-mismatched row is
  # picked up on the very next reconcile_instance! heartbeat regardless
  # (no staleness filter there), so it isn't lost, just not this sensor's
  # concern until it's also stale.
  let(:mountable_file_storage) do
    create(:file_storage, :nfs, :node_mountable, account: account,
      configuration: {
        "export_path" => "/srv/exports/drift-sensor", "mount_path" => "/srv/exports/drift-sensor",
        "share_path" => "/srv/exports/drift-sensor", "server_address" => "127.0.0.1",
        "export_host_node_instance_id" => create(:system_node_instance, account: account).id
      })
  end

  def mounted_assignment_with_mismatch!(last_status_at:)
    assignment = create(:system_storage_assignment, account: account, node_instance: instance,
                         file_storage_id: mountable_file_storage.id)
    assignment.storage_credentials.update_all(status: "revoked")
    active = System::Storage::CredentialIssuer.new(assignment: assignment).issue!
    stale_credential = create(:system_storage_credential,
      storage_assignment: assignment, node_instance: instance, kind: active.kind, status: "revoked")
    assignment.update_columns(status: "mounted", mounted_credential_id: stale_credential.id, last_status_at: last_status_at)
    assignment
  end

  it "emits a drift signal for a MOUNTED assignment with a stale mounted_credential_id, past the window" do
    assignment = mounted_assignment_with_mismatch!(last_status_at: 10.minutes.ago)

    signals = sensor.sense

    expect(signals.size).to eq(1)
    expect(signals.first.kind).to eq("system.storage_assignment_drift")
    expect(signals.first.payload["storage_assignment_id"] || signals.first.payload[:storage_assignment_id])
      .to eq(assignment.id)
  end

  it "does not emit for a MOUNTED assignment with a stale mounted_credential_id that is still fresh" do
    mounted_assignment_with_mismatch!(last_status_at: 1.minute.ago)

    expect(sensor.sense).to be_empty
  end

  it "does not emit for a MOUNTED assignment whose mounted_credential_id already matches" do
    assignment = create(:system_storage_assignment, account: account, node_instance: instance,
                         file_storage_id: mountable_file_storage.id)
    assignment.storage_credentials.update_all(status: "revoked")
    active = System::Storage::CredentialIssuer.new(assignment: assignment).issue!
    assignment.update_columns(status: "mounted", mounted_credential_id: active.id, last_status_at: 10.minutes.ago)

    expect(sensor.sense).to be_empty
  end

  # IMP-a366d6fb6b80 - the second population: an SMB credential left
  # "rotating" past the window because the consumer never confirmed a remount.
  # It rides the SAME signal kind (so the lane's existing applier sweeps it),
  # is independent of the staleness window, and names the node.
  describe "an SMB credential rotating past the retire window" do
    let(:backend) { create(:system_node_instance, account: account) }
    let(:smb_storage) do
      create(:file_storage, :smb, :node_mountable, account: account,
        configuration: {
          "mount_path" => "/mnt/drift-smb", "server_address" => "192.168.1.210",
          "share_name" => "drift-smb", "export_host_node_instance_id" => backend.id
        })
    end

    before do
      allow_any_instance_of(System::StorageCredential)
        .to receive(:vault_credentials) { |row| row.metadata.slice("username") }
    end

    # A MOUNTED, healthy assignment whose rotation crossed schemes: the old
    # credential stays rotating with rotating_since = `since`.
    def healthy_assignment_with_rotating!(since:)
      assignment = create(:system_storage_assignment, account: account, node_instance: instance,
                           file_storage_id: smb_storage.id, mount_path: "/mnt/drift-smb")
      assignment.storage_credentials.update_all(status: "revoked")
      issuer = System::Storage::CredentialIssuer.new(assignment: assignment)
      old = issuer.issue!
      old.update_columns(metadata: old.metadata.merge("username" => "n-legacy-drift"))
      successor = issuer.rotate!(old)
      old.reload.update_columns(rotating_since: since)
      assignment.update_columns(status: "mounted", mounted_credential_id: successor.id, last_status_at: 1.minute.ago)
      [ assignment, old ]
    end

    it "emits its own signal naming the node, even for a healthy mounted assignment inside the staleness window" do
      assignment, old = healthy_assignment_with_rotating!(since: 30.hours.ago)

      signals = sensor.sense

      expect(signals.size).to eq(1)
      signal = signals.first
      expect(signal.kind).to eq("system.storage_assignment_drift")
      expect(signal.fingerprint).to eq("storage_smb_rotation_overdue:#{assignment.id}")
      expect(signal.payload).to include(
        "storage_assignment_id" => assignment.id,
        "node_instance_id" => instance.id,
        "node_instance_name" => instance.name,
        "smb_rotation_overdue_credential_ids" => [ old.id ],
        "smb_rotation_window_hours" => 24,
        "reconcile" => false
      )
    end

    it "does not emit while the credential is inside the window" do
      healthy_assignment_with_rotating!(since: 2.hours.ago)

      expect(sensor.sense).to be_empty
    end

    it "emits for a rotating credential with no clock, so the sweep can stamp it" do
      assignment, old = healthy_assignment_with_rotating!(since: 30.hours.ago)
      old.update_columns(rotating_since: nil)

      expect(sensor.sense.map { |sig| sig.payload["storage_assignment_id"] }).to eq([ assignment.id ])
    end

    it "keeps the overdue check on its OWN fingerprint when the assignment is also drifting, and leaves the drift signal unchanged" do
      assignment, = healthy_assignment_with_rotating!(since: 30.hours.ago)
      assignment.update_columns(status: "degraded", last_status_at: 10.minutes.ago)

      signals = sensor.sense
      drift = signals.find { |sig| sig.fingerprint == "storage_assignment_drift:#{assignment.id}" }
      overdue = signals.find { |sig| sig.fingerprint == "storage_smb_rotation_overdue:#{assignment.id}" }

      expect(signals.size).to eq(2)
      expect(drift.payload).not_to have_key("smb_rotation_overdue_credential_ids")
      expect(drift.payload).not_to have_key("reconcile")
      expect(overdue.payload).to include("reconcile" => false)
    end

    it "does not emit for a rotating credential the sweep cannot act on (storage is not SMB, or no longer resolves)" do
      assignment, = healthy_assignment_with_rotating!(since: 30.hours.ago)

      assignment.update_columns(file_storage_id: SecureRandom.uuid)
      expect(sensor.sense).to be_empty

      assignment.update_columns(file_storage_id: mountable_file_storage.id) # an NFS storage
      expect(sensor.sense).to be_empty
    end

    it "does not emit for another account's credential" do
      healthy_assignment_with_rotating!(since: 30.hours.ago)

      expect(described_class.new(account: create(:account)).sense).to be_empty
    end

    it "is pure read-side: sensing retires nothing" do
      _assignment, old = healthy_assignment_with_rotating!(since: 30.hours.ago)

      sensor.sense

      expect(old.reload.status).to eq("rotating")
    end
  end

  # IMP-8d444c6437a3: system.storage_assignment_reconcile seeds fine but was
  # never added to the core autonomy registry in the Engine, so
  # Ai::InterventionPolicies::BulkUpdate rejects any operator disposition change for it
  # with "unknown category" — dispositions are frozen at whatever the seed
  # chose. Mirrors the same assertion capability_gap_sensor_spec.rb makes
  # for capability_gap_review.
  it "registers the storage_assignment_reconcile category with the core autonomy registry" do
    expect(Ai::InterventionPolicy.category_registered?("system.storage_assignment_reconcile")).to be true
  end
end

# The other half of F3-07: the three sensors must actually run in the tick.
RSpec.describe "F3-07 fleet sensor registration" do
  it "registers the previously-dead sensors in FleetAutonomyService::SENSORS" do
    expect(System::Fleet::FleetAutonomyService::SENSORS).to include(
      System::Fleet::Sensors::PackageDriftSensor,
      System::Fleet::Sensors::SdwanCredentialExpirySensor,
      System::Fleet::Sensors::StorageAssignmentDriftSensor
    )
  end
end
