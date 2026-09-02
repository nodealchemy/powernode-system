# frozen_string_literal: true

require "rails_helper"

# IMP-f28b393916f3 — ModuleDriftSensor is the autonomy signal source for module
# drift. It scoped to `running`, so an instance wedged in `error` (or
# mid-`starting`/`stopping`/`rebooting`) produced no signal AND nothing that
# said it had been skipped: nothing in the sensor's output distinguished "every
# instance was asked and one drifted" from "a whole status class was filtered
# out of the question".
RSpec.describe System::Fleet::Sensors::ModuleDriftSensor, "unassessed disclosure" do
  subject(:signals) { described_class.new(account: account).sense }

  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:digest)   { "sha256:#{'a' * 64}" }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "drift-mod")
  end

  def drift_signals
    signals.select { |s| s[:kind] == "system.module_drift" }
  end

  before do
    version = System::NodeModuleVersion.create!(
      node_module: mod, version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {}, oci_digest: digest
    )
    mod.update!(current_version_id: version.id)
    System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
  end

  context "with a drifted running instance and one wedged in error" do
    let!(:drifted) do
      create(:system_node_instance, :running, node: node, running_module_digests: {})
    end
    let!(:wedged) do
      create(:system_node_instance, node: node, status: "error", running_module_digests: {})
    end

    it "answers drift only for the assessable instance" do
      expect(drift_signals.map { |s| s[:payload]["instance_id"] }).to eq([ drifted.id ])
    end

    it "discloses on the signal how many instances the tick actually covered" do
      payload = drift_signals.first[:payload]

      expect(payload["fleet_instance_count"]).to eq(2)
      expect(payload["fleet_assessed_count"]).to eq(1)
      expect(payload["fleet_not_assessed_count"]).to eq(1)
      expect(payload["fleet_not_assessed_by_status"]).to eq({ "error" => 1 })
    end

    # The disclosure describes the TICK, not the instance the rest of the
    # payload is about; an unprefixed `not_assessed_count` beside
    # `missing_count` would read as a property of this one instance.
    it "keeps the coverage keys distinguishable from the instance's own drift keys" do
      payload = drift_signals.first[:payload]

      expect(payload["missing_count"]).to eq(1)
      expect(payload.keys.grep(/\Afleet_/)).to match_array(
        %w[fleet_instance_count fleet_assessed_count fleet_not_assessed_count
           fleet_not_assessed_by_status fleet_not_reporting_count]
      )
    end
  end

  context "with a terminated instance" do
    let!(:drifted) do
      create(:system_node_instance, :running, node: node, running_module_digests: {})
    end
    let!(:gone) do
      create(:system_node_instance, node: node, status: "terminated", running_module_digests: {})
    end

    it "counts it in neither bucket — that replica is gone, not skipped" do
      payload = drift_signals.first[:payload]

      expect(payload["fleet_instance_count"]).to eq(1)
      expect(payload["fleet_not_assessed_count"]).to eq(0)
    end
  end

  # ACTIVE_STATUSES, not `running` — the sensor answers for the same population
  # drift_check (PlatformMaintenanceExecutor#drift_summary_for) assesses, so the
  # autonomy lane and the maintenance verb cannot disagree about one fleet.
  context "with a stopped instance that has reported, carrying stale digests" do
    let!(:stopped) do
      create(:system_node_instance, node: node, status: "stopped",
             running_module_digests: {}, last_heartbeat_at: 1.hour.ago)
    end

    it "emits a drift signal for it" do
      expect(drift_signals.map { |s| s[:payload]["instance_id"] }).to include(stopped.id)
    end
  end

  # THE ONE THAT BITES. system.module_drift is not an observation: DecisionEngine
  # binds it to DriftRemediateExecutor and REMEDIATION_APPLIERS dispatches a
  # `sync_modules` System::Task for it. A `pending`/`provisioning` row has never
  # had an agent report — its `{}` digest map is the column DEFAULT — so
  # answering drift there would queue a reconcile task against a node with no
  # agent on it, on every tick. It belongs in a disclosed bucket, not in the
  # answer. Same line drift_check draws with its reporting/silent split.
  context "with a provisioning instance that has never reported" do
    let!(:drifted) do
      create(:system_node_instance, :running, node: node, running_module_digests: {})
    end
    let!(:silent) do
      create(:system_node_instance, node: node, status: "provisioning",
             running_module_digests: {}, last_heartbeat_at: nil)
    end

    it "emits no drift signal for it" do
      expect(drift_signals.map { |s| s[:payload]["instance_id"] }).to eq([ drifted.id ])
    end

    it "discloses it on the tick's coverage rather than dropping it" do
      payload = drift_signals.first[:payload]

      expect(payload["fleet_instance_count"]).to eq(2)
      expect(payload["fleet_assessed_count"]).to eq(1)
      expect(payload["fleet_not_reporting_count"]).to eq(1)
      expect(payload["fleet_not_assessed_count"]).to eq(0)
    end
  end

  # `running` keeps answering without a heartbeat: sensors_spec.rb pins that row
  # as drift, and #record_heartbeat! writes `{}` unconditionally for a live agent
  # that has mounted nothing, so emptiness is not the discriminator there.
  context "with a running instance that has never reported" do
    let!(:drifted) do
      create(:system_node_instance, :running, node: node,
             running_module_digests: {}, last_heartbeat_at: nil)
    end

    it "still emits a drift signal for it" do
      expect(drift_signals.map { |s| s[:payload]["instance_id"] }).to eq([ drifted.id ])
      expect(drift_signals.first[:payload]["fleet_not_reporting_count"]).to eq(0)
    end
  end
end
