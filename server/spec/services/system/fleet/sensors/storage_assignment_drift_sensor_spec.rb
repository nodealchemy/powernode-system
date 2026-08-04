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

  # IMP-8d444c6437a3: system.storage_assignment_reconcile seeds fine but was
  # never added to the core autonomy registry in the Engine, so
  # AutonomyActions#update rejects any operator disposition change for it
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
