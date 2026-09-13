# frozen_string_literal: true

require "rails_helper"

# IMP-10c9b9634d4e — operator direction: an abandoned non-pool instance (no
# heartbeat past the abandonment window) in a non-protected plane gets a REAP
# lane, not reprovision/closure approvals; in a protected plane it parks ONE
# reap approval instead of repeating cards.
#
# The lane is skill-less: system.instance_abandoned gates under
# system.abandoned_instance_reap (Capacity Manager, auto_approve) and the
# DecisionEngine applier terminates. Plane placement is not re-implemented —
# the payload names the instance, the gate resolves the instance's plane, and
# Ai::EnvironmentPolicyOverlay escalates this destructive category in a
# protected one.
RSpec.describe "abandoned instance reap lane" do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:fleet) do
    create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy", source_key: "fleet-autonomy")
  end
  let(:capacity) do
    create(:ai_agent, account: account, agent_type: "monitor", name: "Capacity Manager", source_key: "capacity-manager")
  end
  let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: fleet) }
  let(:engine)  { System::Fleet::DecisionEngine.new(autonomy_service: service) }
  let(:category) { "system.abandoned_instance_reap" }
  let(:unprotected) { create(:ai_environment, account: account, slug: "cell-lane", is_protected: false) }
  let(:protected_plane) do
    create(:ai_environment, account: account, slug: "ops-lane", is_protected: true, default_decision_authority: "monitored")
  end

  let!(:dead) do
    inst = create(:system_node_instance, node: node, status: "starting", environment: unprotected)
    inst.update_columns(last_heartbeat_at: 29.days.ago, created_at: 45.days.ago)
    inst
  end

  def abandoned_signal(instance = dead)
    System::Fleet::Sensors::AbandonedInstanceSensor.new(account: account).sense
      .find { |s| s.payload["instance_id"] == instance.id }
  end

  def apply!(signal)
    engine.send(:apply_remediation!, signal, nil)
  end

  before do
    allow(System::ProvisioningService).to receive(:terminate_instance).and_return(System::Runtime::Result.ok)
  end

  describe "the declaration" do
    it "binds the abandoned signal, skill-less, to the reap category on the Capacity Manager" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.instance_abandoned"]

      expect(binding).to include(skill: nil, action_category: category, owner: "capacity-manager")
      expect(System::Fleet::DecisionEngine::REMEDIATION_APPLIERS["system.instance_abandoned"])
        .to eq(method: :reap_abandoned_instance)
    end

    it "declares the category auto-proceeding for the Capacity Manager" do
      expect(System::Governance::PolicyDeclarations::CAPACITY_MANAGER_POLICIES[category]).to eq("auto_approve")
    end

    it "registers the sensor on the tick" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(System::Fleet::Sensors::AbandonedInstanceSensor)
    end

    it "is a destructive category, so a protected plane escalates it and an unprotected one does not" do
      expect(Ai::EnvironmentPolicyOverlay.escalation_reason(protected_plane, category)).to match(/protected/)
      expect(Ai::EnvironmentPolicyOverlay.escalation_reason(unprotected, category)).to be_nil
    end

    it "places the action in the instance's own plane" do
      placed = Ai::EnvironmentResolution.resolve(account: account, params: abandoned_signal.payload)

      expect(placed).to eq(unprotected)
    end

    # One card per instance: a standing abandoned signal re-decided every dedup
    # window updates the open approval instead of queueing another.
    it "dedups approvals per instance, like the replace lane" do
      meta = { "instance_id" => dead.id }

      key = service.send(:dedup_key_for, category, meta)
      expect(key).not_to be_nil
      expect(key).to eq(service.send(:dedup_key_for, "system.instance_replace", meta))
    end
  end

  describe "deciding" do
    before do
      Ai::InterventionPolicy.create!(account: account, ai_agent_id: capacity.id, scope: "agent",
                                     action_category: category, policy: "auto_approve",
                                     priority: 10, is_active: true)
    end

    it "reaps an abandoned instance in an unprotected plane on the tick, with no approval" do
      decision = engine.decide(abandoned_signal)

      expect(decision[:decision]).to eq(:proceed)
      expect(decision.dig(:remediation, :applied)).to be(true), decision[:remediation].inspect
      expect(System::ProvisioningService).to have_received(:terminate_instance).with(instance: dead)
    end

    it "parks for approval, terminating nothing, when the instance is in a protected plane" do
      dead.update_columns(environment_id: protected_plane.id)

      decision = engine.decide(abandoned_signal)

      expect(decision[:decision]).to eq(:pending)
      expect(decision[:gate]).to eq("require_approval")
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    # Review F1/F2: in an unprotected plane too, a guest with something to lose
    # parks one approval rather than being destroyed on the tick.
    it "parks for approval in an unprotected plane when the guest holds an attached volume" do
      create(:system_provider_volume, :attached, account: account, node_instance_id: dead.id)

      decision = engine.decide(abandoned_signal)

      expect(decision[:decision]).to eq(:pending)
      expect(decision[:gate]).to eq("require_approval")
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    it "parks for approval in an unprotected plane when the platform last saw the guest running" do
      dead.update_columns(status: "running")

      decision = engine.decide(abandoned_signal)

      expect(decision[:decision]).to eq(:pending)
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    it "parks for approval in an unprotected plane when the guest is powered off" do
      dead.update_columns(status: "stopped")

      decision = engine.decide(abandoned_signal)

      expect(decision[:decision]).to eq(:pending)
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end
  end

  describe "the applier re-checks the claim at execution" do
    it "releases the instance from published service backends before terminating it" do
      expect(System::Fleet::ServiceBackendRelease).to receive(:release!)
        .with(hash_including(account: account, instance: dead)).ordered.and_call_original
      expect(System::ProvisioningService).to receive(:terminate_instance).with(instance: dead).ordered
        .and_return(System::Runtime::Result.ok)

      expect(apply!(abandoned_signal)).to include(applied: true, instance_id: dead.id)
    end

    it "refuses when the instance has heartbeated since it was reported" do
      signal = abandoned_signal
      dead.update_columns(last_heartbeat_at: 1.minute.ago)

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to match(/no longer abandoned/i)
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    it "refuses when an operator has put the instance on hold since" do
      signal = abandoned_signal
      dead.update_columns(ops_hold_at: Time.current)

      expect(apply!(signal)[:applied]).to be(false)
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    it "reports an instance already terminated without terminating it again" do
      signal = abandoned_signal
      dead.update_columns(status: "terminated")

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to eq("already terminated")
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    it "reports a refused terminate as not applied, with the provider's reason" do
      allow(System::ProvisioningService).to receive(:terminate_instance)
        .and_return(System::Runtime::Result.err(error: "provider said no"))

      result = apply!(abandoned_signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to include("provider said no")
    end

    # The gate parked the reap only if the sensor saw something at stake. A
    # volume attached after that has had no approval, so the tick path refuses.
    it "refuses on the unapproved path when a volume was attached after detection" do
      signal = abandoned_signal
      expect(signal.payload["requires_approval"]).to be(false)
      create(:system_provider_volume, :attached, account: account, node_instance_id: dead.id)

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to match(/attached_volumes/)
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    # An approved reap keeps the data: volumes are detached (the order the DR
    # reap uses) before the guest, and every disk in its config, is destroyed.
    it "detaches attached volumes before terminating an approved reap" do
      volume = create(:system_provider_volume, :attached, account: account, node_instance_id: dead.id)
      signal = abandoned_signal
      expect(signal.payload["requires_approval"]).to be(true)

      expect(System::VolumeManagementService).to receive(:detach).with(volume: volume).ordered
        .and_return(System::Runtime::Result.ok)
      expect(System::ProvisioningService).to receive(:terminate_instance).with(instance: dead).ordered
        .and_return(System::Runtime::Result.ok)

      expect(apply!(signal)).to include(applied: true, detached_volume_ids: [ volume.id ])
    end

    it "terminates nothing when a volume will not detach" do
      create(:system_provider_volume, :attached, account: account, node_instance_id: dead.id)
      signal = abandoned_signal
      allow(System::VolumeManagementService).to receive(:detach).and_return(System::Runtime::Result.err(error: "busy"))

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to include("busy")
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    # Re-review F4: an approval covers the reasons its card showed, not a
    # yes/no. A reason that appeared since has not been weighed by anyone.
    it "refuses an approved reap when something is at stake that the approval did not cover" do
      dead.update_columns(status: "stopped")
      signal = abandoned_signal
      expect(signal.payload["approval_reasons"]).to eq([ "stopped" ])
      create(:system_provider_volume, :attached, account: account, node_instance_id: dead.id)

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to match(/attached_volumes/)
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    # The flag reaches the applier through the approval's stored payload, not
    # the sensor's signal object: replay it the way a released request is.
    it "reaps a parked instance when its approved request is replayed" do
      dead.update_columns(status: "stopped")
      signal = abandoned_signal
      request = Struct.new(:id, :request_data).new(
        SecureRandom.uuid, { "payload" => engine.send(:skill_metadata_payload, signal, nil) }
      )

      expect(engine.execute_approved!(request)).to include(applied: true, instance_id: dead.id)
      expect(System::ProvisioningService).to have_received(:terminate_instance).with(instance: dead)
    end

    it "refuses the platform's own hosting node at execution" do
      signal = abandoned_signal
      ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, dead.node_id)

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to include("INV-1 self-management fence")
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    # An approval cannot clear this one: the lane does not move addresses, and a
    # terminate would leave the dead peer in the VIP's holder lists.
    it "refuses an approved reap of a virtual IP holder until the address is moved" do
      peer = create(:sdwan_peer, account: account, node_instance: dead)
      create(:sdwan_virtual_ip, network: peer.network, account: account, failover_holder_peer_ids: [ peer.id ])
      signal = abandoned_signal
      expect(signal.payload["approval_reasons"]).to eq([ "virtual_ip_holder" ])

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to match(/move the address off this guest/)
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    it "refuses an instance outside the account" do
      forged = System::Fleet::Signal.new(kind: "system.instance_abandoned", severity: :medium,
                                         payload: { "instance_id" => SecureRandom.uuid },
                                         fingerprint: "instance_abandoned:forged")

      expect(apply!(forged)[:applied]).to be(false)
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end
  end
end
