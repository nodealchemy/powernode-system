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

    # IMP-10c9b9634d4e VIP ruling: a failover-only standby is not an approval
    # reason at all — the reap prunes it itself, through the same write path
    # sdwan_update_virtual_ip uses, BEFORE the volume detach and the backend
    # release (review D3), and BEFORE terminating.
    it "prunes the guest's peer from a VIP's failover list before detaching volumes, releasing backends, and terminating an unapproved reap" do
      peer = create(:sdwan_peer, account: account, node_instance: dead)
      vip = create(:sdwan_virtual_ip, network: peer.network, account: account,
                                      failover_holder_peer_ids: [ peer.id ])
      # Re-review (2): the earlier version of this example created no volume,
      # so it could not pin prune-before-DETACH at all — only prune-before-
      # release/terminate. A reorder putting the prune between the detach
      # loop and the backend release would have stayed green while
      # contradicting the comment at the top of the prune block and both
      # FLEET_SENSORS.md / CAPACITY_MANAGER_AGENT.md passages.
      volume = create(:system_provider_volume, :attached, account: account, node_instance_id: dead.id)
      signal = abandoned_signal
      expect(signal.payload["requires_approval"]).to be(true)
      expect(signal.payload["approval_reasons"]).to eq([ "attached_volumes" ])

      # Review D9(a): pin the full order review D3 requires, the same way the
      # existing plain volume-detach example above pins detach-before-terminate.
      expect(Sdwan::Executors::UpdateVirtualIp).to receive(:execute).ordered.and_call_original
      expect(System::VolumeManagementService).to receive(:detach).with(volume: volume).ordered
        .and_return(System::Runtime::Result.ok)
      expect(System::Fleet::ServiceBackendRelease).to receive(:release!)
        .with(hash_including(account: account, instance: dead)).ordered.and_call_original
      expect(System::ProvisioningService).to receive(:terminate_instance).with(instance: dead).ordered
        .and_return(System::Runtime::Result.ok)

      result = apply!(signal)

      expect(result).to include(applied: true, instance_id: dead.id, pruned_virtual_ip_failover_ids: [ vip.id ],
                                detached_volume_ids: [ volume.id ])
      expect(vip.reload.failover_holder_peer_ids).to eq([])
    end

    # Review D7: the prune is an un-gated autonomous edit of an
    # operator-configured object — it must leave a trace of its own rather
    # than dying with the method's return value.
    it "emits a fleet event naming the VIP and the pruned peer id" do
      peer = create(:sdwan_peer, account: account, node_instance: dead)
      vip = create(:sdwan_virtual_ip, network: peer.network, account: account,
                                      failover_holder_peer_ids: [ peer.id ])
      signal = abandoned_signal

      expect(apply!(signal)).to include(applied: true)

      event = System::FleetEvent.where(account: account, kind: "system.virtual_ip_failover_pruned").last
      expect(event).to be_present
      expect(event.payload).to include("virtual_ip_id" => vip.id, "instance_id" => dead.id,
                                       "removed_peer_ids" => [ peer.id ])
    end

    # Review D1: verify_replay_baseline! only fires when the write carries a
    # baseline. A concurrent VirtualIp#failover! (SdwanVipReachabilitySensor's
    # own lane, which fires on any holder handshake stale past 5 minutes — an
    # abandoned guest is stale for days) landing between the read this reap
    # took and the prune's write must stop the reap rather than being
    # silently clobbered by it.
    it "stops the reap when a concurrent write changes the failover list before the prune writes, destroying nothing" do
      peer = create(:sdwan_peer, account: account, node_instance: dead)
      concurrent_peer = create(:sdwan_peer, account: account, network: peer.network)
      vip = create(:sdwan_virtual_ip, network: peer.network, account: account,
                                      failover_holder_peer_ids: [ peer.id ])
      signal = abandoned_signal

      allow(System::Fleet::Sensors::AbandonedInstanceSensor).to receive(:virtual_ip_holdings).and_wrap_original do |original, *args, **kwargs|
        holdings = original.call(*args, **kwargs)
        # The race: something else (a real failover) writes the row between
        # this read and the prune's write, below, in the same method call.
        ::Sdwan::VirtualIp.where(id: vip.id).update_all(failover_holder_peer_ids: [ concurrent_peer.id ])
        holdings
      end
      expect(System::Fleet::ServiceBackendRelease).not_to receive(:release!)
      expect(System::ProvisioningService).not_to receive(:terminate_instance)

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to match(/did not prune/)
      expect(vip.reload.failover_holder_peer_ids).to eq([ concurrent_peer.id ])
    end

    # Optional coverage flagged by re-review: N failover-only VIPs, the prune
    # fails on VIP k, leaving 1..k-1 already written. Behaviour is correct by
    # construction (the instance itself is untouched, the partial set is
    # reported, each prune is independently idempotent on retry) — this pins
    # it rather than changing anything.
    it "reports a partial prune and runs nothing destructive when the second of two failover-only VIPs fails to prune" do
      peer = create(:sdwan_peer, account: account, node_instance: dead)
      vip_a = create(:sdwan_virtual_ip, network: peer.network, account: account, failover_holder_peer_ids: [ peer.id ])
      vip_b = create(:sdwan_virtual_ip, network: peer.network, account: account, failover_holder_peer_ids: [ peer.id ])
      signal = abandoned_signal

      call_count = 0
      allow(Sdwan::Executors::UpdateVirtualIp).to receive(:execute).and_wrap_original do |original, params, **kwargs|
        call_count += 1
        raise "simulated write failure" if call_count == 2

        original.call(params, **kwargs)
      end
      expect(System::Fleet::ServiceBackendRelease).not_to receive(:release!)
      expect(System::ProvisioningService).not_to receive(:terminate_instance)

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to match(/did not prune/)
      expect(result[:pruned_virtual_ip_failover_ids].size).to eq(1)
      succeeded_id = result[:pruned_virtual_ip_failover_ids].first
      succeeded_vip, failed_vip = [ vip_a, vip_b ].partition { |v| v.id == succeeded_id }.map(&:first)
      expect(succeeded_vip.reload.failover_holder_peer_ids).to eq([])
      expect(failed_vip.reload.failover_holder_peer_ids).to eq([ peer.id ])
      expect(dead.reload.status).not_to eq("terminated")
    end

    # Review D2 TOCTOU: the active-holder refusal is evaluated before the
    # (real, provider-round-trip) volume detach and the destructive backend
    # release. A failover promoting this guest's peer into the holder seat
    # inside that window must be honoured, not tombstoned by the terminate.
    it "refuses at the last moment when the guest is promoted to active holder mid-reap" do
      peer = create(:sdwan_peer, account: account, node_instance: dead)
      vip = create(:sdwan_virtual_ip, network: peer.network, account: account)
      volume = create(:system_provider_volume, :attached, account: account, node_instance_id: dead.id)
      signal = abandoned_signal
      expect(signal.payload["approval_reasons"]).to eq([ "attached_volumes" ])

      # Re-review (3): a call-order LOG, not just a call COUNT — pinning "two
      # calls happened" would stay green if the re-check were moved right
      # next to the first check (before the detach/release), which silently
      # restores the exact TOCTOU window D2 exists to close. The log asserts
      # the SECOND virtual_ip_holdings read happens strictly after release!.
      call_log = []
      call_count = 0
      allow(System::Fleet::Sensors::AbandonedInstanceSensor).to receive(:virtual_ip_holdings).and_wrap_original do |original, *args, **kwargs|
        call_count += 1
        call_log << :"virtual_ip_holdings_#{call_count}"
        result = original.call(*args, **kwargs)
        # The FIRST call (the pre-detach/release check) reads genuinely
        # nothing at stake, above. Promote the peer to active holder only
        # AFTER that read returns, simulating a failover landing during the
        # detach/release window — the SECOND call (review D2's re-check)
        # must see the promotion.
        vip.update_columns(holder_peer_ids: [ peer.id ]) if call_count == 1
        result
      end
      allow(System::VolumeManagementService).to receive(:detach).with(volume: volume)
        .and_return(System::Runtime::Result.ok)
      allow(System::Fleet::ServiceBackendRelease).to receive(:release!).and_wrap_original do |original, **kwargs|
        call_log << :release!
        original.call(**kwargs)
      end
      expect(System::ProvisioningService).not_to receive(:terminate_instance)

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to match(/promoted mid-reap/)
      expect(result[:reason]).to match(/approval will not help/)
      expect(result[:reason]).to match(/already detached/)
      expect(vip.reload.holder_peer_ids).to eq([ peer.id ])
      expect(call_log).to eq([ :virtual_ip_holdings_1, :release!, :virtual_ip_holdings_2 ])
    end

    # D9(b): a peer that is the active holder of ONE VIP while only standing
    # by for a DIFFERENT VIP must still refuse outright at the active-holder
    # check, before the applier ever reaches the failover-only prune — so
    # neither VIP is touched and no volume is detached.
    it "refuses outright, touching neither VIP nor any volume, when the same peer holds one VIP and stands by for another" do
      peer = create(:sdwan_peer, account: account, node_instance: dead)
      held_vip = create(:sdwan_virtual_ip, network: peer.network, account: account, holder_peer_ids: [ peer.id ])
      standby_vip = create(:sdwan_virtual_ip, network: peer.network, account: account,
                                              failover_holder_peer_ids: [ peer.id ])
      volume = create(:system_provider_volume, :attached, account: account, node_instance_id: dead.id)
      signal = abandoned_signal
      expect(signal.payload["approval_reasons"]).to include("virtual_ip_active_holder")

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to match(/approval will not help/)
      expect(standby_vip.reload.failover_holder_peer_ids).to eq([ peer.id ])
      expect(held_vip.reload.holder_peer_ids).to eq([ peer.id ])
      expect(volume.reload.status).to eq("in-use")
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
    end

    it "refuses an active virtual IP holder even when approved, and the refusal names the remedy" do
      peer = create(:sdwan_peer, account: account, node_instance: dead)
      vip = create(:sdwan_virtual_ip, network: peer.network, account: account,
                                      holder_peer_ids: [ peer.id ])
      signal = abandoned_signal
      expect(signal.payload["approval_reasons"]).to eq([ "virtual_ip_active_holder" ])

      result = apply!(signal)

      expect(result[:applied]).to be(false)
      expect(result[:reason]).to match(/approval will not help/)
      expect(result[:reason]).to include(vip.name)
      expect(result[:reason]).to match(/sdwan_update_virtual_ip/)
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
      expect(vip.reload.holder_peer_ids).to eq([ peer.id ])
    end

    # The card an operator reads BEFORE deciding must say the same thing —
    # otherwise approving it looks like it should work and records no outcome,
    # so a fresh card is raised every tick with no explanation.
    it "names the same 'approval will not help' remedy on the approval card summary" do
      peer = create(:sdwan_peer, account: account, node_instance: dead)
      create(:sdwan_virtual_ip, network: peer.network, account: account, holder_peer_ids: [ peer.id ])
      signal = abandoned_signal

      summary = engine.send(:build_summary, signal, nil)

      expect(summary).to match(/approval will not help/)
      expect(summary).to match(/sdwan_update_virtual_ip/)
    end

    # D9(d): the note is keyed to THIS card's own reason, not stamped onto
    # every card the lane raises — an unrelated reason must not carry it.
    it "does not carry the VIP note on a card parked for an unrelated reason" do
      create(:system_provider_volume, :attached, account: account, node_instance_id: dead.id)
      signal = abandoned_signal

      summary = engine.send(:build_summary, signal, nil)

      expect(summary).not_to match(/approval will not help/)
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
