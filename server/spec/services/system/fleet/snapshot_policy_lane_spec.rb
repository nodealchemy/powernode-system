# frozen_string_literal: true

require "rails_helper"

# IMP-c22215ae9546 — APO-5 door 2: the snapshot SCHEDULE lane, end to end.
#
# IMP-e025722ef14e landed the READ side (Ai::Mission#snapshot_policy resolving
# the ladder, System::VolumeManagementService.snapshot_schedule_for answering
# due/prunable) and stopped there, because the sensors directory belonged to
# another lane that batch. The result was the notify-lane-without-an-applier
# shape one level up: a read seam with ZERO production callers reads as
# coverage while nothing ever asks the question. A project's declared
# `snapshot_interval_hours` / `snapshot_retention_count` were still decorative.
#
# THE ORACLE THAT MATTERS is the TICK one below ("is reached by the decision
# engine on a real tick"). A sensor class that exists and passes its own unit
# spec, but is not in FleetAutonomyService::SENSORS, reproduces the exact
# defect it was written to fix — so this file asserts the signal arrives at
# DecisionEngine through FleetAutonomyService#tick!, not that the class
# responds to #sense.
RSpec.describe "fleet snapshot-schedule lane (declare → sense → act)", type: :service do
  before do
    skip "requires Ai::ApprovalChain (business extension)" unless defined?(::Ai::ApprovalChain)
  end

  let(:account) { create(:account) }
  let!(:user)   { create(:user, account: account) }

  let(:fleet) do
    create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy",
                      source_key: "fleet-autonomy")
  end
  let(:storage) do
    create(:ai_agent, account: account, agent_type: "monitor", name: "Storage Manager",
                      source_key: "storage-manager")
  end

  let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: fleet) }
  let(:engine)  { System::Fleet::DecisionEngine.new(autonomy_service: service) }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  def policy!(agent, category, verb)
    Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                   action_category: category, policy: verb, priority: 10, is_active: true)
  end

  # mission -> GoalPlan -> completed provisioning step, through the PRODUCTION
  # writer — the same construction volume_snapshot_schedule_spec.rb uses, so
  # the sensor is exercised against the shape the resolver really reads.
  def provisioned_mission(instance_ids, watch_policies:)
    agent = create(:ai_agent, account: account)
    goal  = Ai::AgentGoal.create!(
      account: account, agent: agent, title: "provision",
      goal_type: "creation", status: "active", priority: 3, progress: 0.0
    )
    plan = Ai::GoalPlan.create!(account: account, goal: goal, agent: agent, status: "approved", version: 1)

    mission = create(
      :ai_mission, account: account, created_by: user, mission_type: "infrastructure",
      custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ],
      configuration: { "plan" => { "plan_id" => plan.id }, "watch_policies" => watch_policies }
    )
    mission.update_columns(status: "active")

    step = plan.steps.create!(step_number: 1, status: "pending", step_type: "provisioning_skill")
    envelope = { success: true,
                 data: { dry_run: false, count: instance_ids.size, planned_actions: [],
                         outputs: { node_ids: [], node_instance_ids: instance_ids,
                                    sdwan_peer_ids: [], storage_volume_ids: [] },
                         failures: [], partial: false } }
    runner = ::Ai::Provisioning::SkillCompositionRunner.new(account: account, mission: mission, plan: plan)
    runner.send(:mark_completed, step, runner.send(:result_outputs, envelope))

    mission
  end

  def attached_volume(name)
    create(:system_provider_volume, account: account, name: name, status: "in-use",
                                    external_id: "vol-#{name}", node_instance: instance,
                                    device_name: "/dev/sdb")
  end

  def completed_snapshot(volume, at:, name: "#{volume.name}-#{at.to_i}")
    create(:system_provider_volume_snapshot, account: account, volume: volume, name: name,
                                             status: "completed", external_id: "snap-#{name}",
                                             created_at: at)
  end

  # ==========================================================================
  # The sensor
  # ==========================================================================
  describe System::Fleet::Sensors::SnapshotPolicySensor do
    let(:sensor) { described_class.new(account: account) }

    it "emits a due signal for a volume whose project declared an interval and has no restore point" do
      volume = attached_volume("data")
      provisioned_mission([ instance.id ], watch_policies: { "snapshot_interval_hours" => 6 })

      signals = sensor.sense

      due = signals.select { |s| s.kind == "system.volume_snapshot_due" }
      expect(due.size).to eq(1)
      expect(due.first.payload["provider_volume_id"]).to eq(volume.id)
      expect(due.first.payload["interval_hours"]).to eq(6)
      expect(due.first.fingerprint).to eq("volume_snapshot_due:#{volume.id}")
      expect(due.first.payload["_sensor"]).to eq("SnapshotPolicySensor")
    end

    it "emits a prunable signal for each completed snapshot beyond the declared retention count" do
      volume = attached_volume("data")
      oldest = completed_snapshot(volume, at: 40.hours.ago)
      completed_snapshot(volume, at: 2.hours.ago)
      completed_snapshot(volume, at: 1.hour.ago)
      provisioned_mission([ instance.id ], watch_policies: { "snapshot_retention_count" => 2 })

      prunable = sensor.sense.select { |s| s.kind == "system.volume_snapshot_prunable" }

      expect(prunable.size).to eq(1)
      expect(prunable.first.payload["provider_volume_snapshot_id"]).to eq(oldest.id)
      expect(prunable.first.payload["retention_count"]).to eq(2)
      expect(prunable.first.fingerprint).to eq("volume_snapshot_prunable:#{oldest.id}")
    end

    it "emits nothing for a project that declared no schedule and no retention (0 = off, never a default)" do
      attached_volume("data")
      provisioned_mission([ instance.id ], watch_policies: {})

      expect(sensor.sense).to be_empty
    end

    it "is pure read-side: sensing takes no snapshot and deletes none" do
      volume = attached_volume("data")
      completed_snapshot(volume, at: 40.hours.ago)
      completed_snapshot(volume, at: 8.hours.ago) # past the 6h interval, so DUE as well as over retention
      provisioned_mission([ instance.id ],
                          watch_policies: { "snapshot_interval_hours" => 6, "snapshot_retention_count" => 1 })
      allow(System::VolumeManagementService).to receive(:snapshot)
      allow(System::VolumeManagementService).to receive(:delete_snapshot)

      expect(sensor.sense.size).to eq(2)

      expect(System::VolumeManagementService).not_to have_received(:snapshot)
      expect(System::VolumeManagementService).not_to have_received(:delete_snapshot)
      expect(System::ProviderVolumeSnapshot.where(volume: volume).count).to eq(2)
    end
  end

  # ==========================================================================
  # THE DEFECT'S OWN ORACLE — registration + arrival at the decision engine.
  # ==========================================================================
  describe "registration" do
    it "is registered in FleetAutonomyService::SENSORS (a class nothing runs is the defect, not the fix)" do
      expect(System::Fleet::FleetAutonomyService::SENSORS)
        .to include(System::Fleet::Sensors::SnapshotPolicySensor)
    end

    it "is reached by the decision engine on a real tick" do
      attached_volume("data")
      provisioned_mission([ instance.id ], watch_policies: { "snapshot_interval_hours" => 6 })
      storage
      policy!(storage, "system.volume_snapshot_create", "notify_and_proceed")

      result = service.tick!

      expect(result[:ok]).to be(true)
      expect(result[:by_kind]).to have_key("system.volume_snapshot_due"),
        "the tick produced decisions for #{result[:by_kind].keys.inspect} — the snapshot lane never reached the engine"
    end
  end

  # ==========================================================================
  # The bindings — a signal nothing consumes is the same defect in a new place
  # ==========================================================================
  describe "the declaration" do
    let(:bindings) { System::Fleet::DecisionEngine::SIGNAL_BINDINGS }

    it "routes the due signal to system.volume_snapshot_create, owned by the Storage Manager" do
      binding = bindings.fetch("system.volume_snapshot_due")
      expect(binding[:action_category]).to eq("system.volume_snapshot_create")
      expect(System::Fleet::DecisionEngine.owner_for(binding)).to eq("storage-manager")
      expect(System::Governance::PolicyDeclarations.owner_of("system.volume_snapshot_create"))
        .to eq("storage-manager")
    end

    it "routes the prunable signal to the EXISTING system.volume_snapshot_delete row, not a second control" do
      binding = bindings.fetch("system.volume_snapshot_prunable")
      expect(binding[:action_category]).to eq("system.volume_snapshot_delete")
      expect(System::Fleet::DecisionEngine.owner_for(binding)).to eq("storage-manager")
      expect(System::Governance::PolicyDeclarations::VOLUME_SNAPSHOT_OPERATOR_POLICIES)
        .to eq("system.volume_snapshot_delete" => "require_approval")
    end

    it "declares system.volume_snapshot_create on the Storage Manager's set so PolicyReconciler owns the row" do
      d = System::Governance::PolicyDeclarations
      expect(d::STORAGE_POLICY_KEYS["system.volume_snapshot_create"]).to eq("notify_and_proceed")
      expect(d::STORAGE_MANAGER_POLICIES).to have_key("system.volume_snapshot_create")
      expect(Ai::InterventionPolicy.category_registered?("system.volume_snapshot_create")).to be true
    end

    it "gives BOTH lanes an applier — neither is a proceed that actuates nothing" do
      appliers = System::Fleet::DecisionEngine::REMEDIATION_APPLIERS
      expect(appliers).to have_key("system.volume_snapshot_due")
      expect(appliers).to have_key("system.volume_snapshot_prunable")
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_SIGNAL_KINDS)
        .not_to include("system.volume_snapshot_due", "system.volume_snapshot_prunable")
    end
  end

  # ==========================================================================
  # Acting
  # ==========================================================================
  describe "deciding and applying" do
    let(:adapter) { instance_double(System::Providers::BaseProvider) }

    before do
      storage
      allow(System::Providers::Registry).to receive(:for_volume).and_return(adapter)
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
    end

    def due_signal(volume, mission)
      System::Fleet::Signal.new(
        kind: "system.volume_snapshot_due", severity: :medium,
        fingerprint: "volume_snapshot_due:#{volume.id}",
        payload: { "provider_volume_id" => volume.id, "mission_id" => mission.id,
                   "interval_hours" => 6, "last_snapshot_at" => nil, "_sensor" => "SnapshotPolicySensor" }
      )
    end

    def prunable_signal(snapshot, volume, mission)
      System::Fleet::Signal.new(
        kind: "system.volume_snapshot_prunable", severity: :low,
        fingerprint: "volume_snapshot_prunable:#{snapshot.id}",
        payload: { "provider_volume_snapshot_id" => snapshot.id, "provider_volume_id" => volume.id,
                   "mission_id" => mission.id, "retention_count" => 1, "_sensor" => "SnapshotPolicySensor" }
      )
    end

    it "takes the scheduled snapshot when the create gate proceeds" do
      volume  = attached_volume("data")
      mission = provisioned_mission([ instance.id ], watch_policies: { "snapshot_interval_hours" => 6 })
      policy!(storage, "system.volume_snapshot_create", "notify_and_proceed")
      allow(adapter).to receive(:create_volume_snapshot).and_return(success: true, snapshot_id: "snap-new")

      decision = nil
      expect { decision = engine.decide(due_signal(volume, mission)) }
        .to change { System::ProviderVolumeSnapshot.where(volume: volume, status: "completed").count }.by(1)

      expect(decision[:decision]).to eq(:proceed)
      expect(decision[:owner]).to eq("storage-manager")
      expect(decision[:remediation]).to include(applied: true)
    end

    it "does NOT delete a retained snapshot before the operator approves (the delete row is require_approval)" do
      volume   = attached_volume("data")
      snapshot = completed_snapshot(volume, at: 40.hours.ago)
      mission  = provisioned_mission([ instance.id ], watch_policies: { "snapshot_retention_count" => 1 })
      policy!(storage, "system.volume_snapshot_delete", "require_approval")
      create(:ai_approval_chain, account: account, trigger_type: "autonomy_action",
                                 status: "active", name: "Storage Manager Actions", timeout_hours: 8)

      decision = engine.decide(prunable_signal(snapshot, volume, mission))

      expect(decision[:decision]).to eq(:pending)
      expect(decision[:remediation]).to be_nil
      expect(snapshot.reload).to be_persisted
    end

    it "prunes the snapshot once the delete gate proceeds" do
      volume   = attached_volume("data")
      snapshot = completed_snapshot(volume, at: 40.hours.ago)
      mission  = provisioned_mission([ instance.id ], watch_policies: { "snapshot_retention_count" => 1 })
      policy!(storage, "system.volume_snapshot_delete", "auto_approve")
      allow(adapter).to receive(:delete_volume_snapshot).and_return(success: true)

      decision = engine.decide(prunable_signal(snapshot, volume, mission))

      expect(decision[:decision]).to eq(:proceed)
      expect(decision[:remediation]).to include(applied: true)
      expect(System::ProviderVolumeSnapshot.where(id: snapshot.id)).to be_empty
    end

    # The require_approval half is only real if the APPROVAL actuates. A
    # pending decision that a person approves and that then applies nothing is
    # the same dead end audit F3-01 found on the reprovision lane — and the
    # replay reconstructs the signal from request_data["payload"], so it also
    # pins that the applier's lookup key survives the round trip.
    it "prunes the snapshot when the operator's approval is consumed on a later tick" do
      volume   = attached_volume("data")
      snapshot = completed_snapshot(volume, at: 40.hours.ago)
      mission  = provisioned_mission([ instance.id ], watch_policies: { "snapshot_retention_count" => 1 })
      chain = create(:ai_approval_chain, account: account, trigger_type: "autonomy_action",
                                         status: "active", name: "Storage Manager Actions", timeout_hours: 8)
      allow(adapter).to receive(:delete_volume_snapshot).and_return(success: true)
      request = Ai::ApprovalRequest.create!(
        account: account, approval_chain: chain, source_type: "system_fleet", status: "approved",
        description: "Fleet action: system.volume_snapshot_delete",
        request_data: {
          "action_category" => "system.volume_snapshot_delete",
          "payload" => prunable_signal(snapshot, volume, mission).payload
                         .merge("signal_kind" => "system.volume_snapshot_prunable",
                                "signal_severity" => "low",
                                "signal_fingerprint" => "volume_snapshot_prunable:#{snapshot.id}"),
          "agent_role" => "fleet"
        }
      )

      executed = service.execute_approved_actions!(engine)

      expect(executed).to contain_exactly(hash_including(request_id: request.id, applied: true))
      expect(System::ProviderVolumeSnapshot.where(id: snapshot.id)).to be_empty
    end

    it "reports applied:false rather than raising when the volume is gone by the time the gate proceeds" do
      volume  = attached_volume("data")
      mission = provisioned_mission([ instance.id ], watch_policies: { "snapshot_interval_hours" => 6 })
      signal  = due_signal(volume, mission)
      policy!(storage, "system.volume_snapshot_create", "notify_and_proceed")
      volume.destroy!

      decision = engine.decide(signal)

      expect(decision[:decision]).to eq(:proceed)
      expect(decision[:remediation]).to include(applied: false)
    end
  end
end
