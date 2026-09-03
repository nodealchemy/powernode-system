# frozen_string_literal: true

require "rails_helper"

# HIER-P2A — a fleet sensor is gated under the agent that OWNS its policy set.
#
# FleetAutonomyService::SENSORS runs every sensor on the Fleet Autonomy tick,
# and #gate_action! used to resolve EVERY decision against the agent running
# that tick. That mechanical fact is why 14 system.sdwan_* / system.federation_*
# remediation rows, the gitops-drift row and the disk-image publication row all
# had to live in FLEET_AUTONOMY_POLICIES although SDWAN Manager, GitOps
# Reconciler and Disk Image Manager exist — a row on the specialist agent was
# invisible to the tick and the signal died at the gate.
#
# The owner is declared on the SIGNAL_BINDINGS entry, not on the SENSORS entry,
# because ownership is a property of the ACTION CATEGORY the gate resolves
# (that is what a policy row is keyed on), and one sensor can emit kinds that
# land on different owners: SdwanBgpSessionHealthSensor routes
# sdwan_bgp_session_unhealthy to SDWAN Manager's remediation row and
# sdwan_bgp_session_stale to Fleet Autonomy's system.observation row. A per-
# sensor owner would strand one of the two.
#
# One example per consequence: policy lookup, approval chain, executor agent,
# EventBroadcaster attribution, the agent_id on the ApprovalRequest, the
# missing-owner fallback, and the declaration/ownership coherence.
RSpec.describe "fleet sensor ownership (DecisionEngine owner gating)" do
  before do
    skip "requires Ai::ApprovalChain (business extension)" unless defined?(::Ai::ApprovalChain)
  end

  let(:account) { create(:account) }
  let(:fleet) do
    create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy",
                      source_key: "fleet-autonomy")
  end
  let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: fleet) }
  let(:engine)  { System::Fleet::DecisionEngine.new(autonomy_service: service) }

  def sdwan_manager!
    create(:ai_agent, account: account, agent_type: "monitor", name: "SDWAN Manager",
                      source_key: "sdwan-manager")
  end

  def policy!(agent, category, verb)
    Ai::InterventionPolicy.create!(account: account, ai_agent_id: agent.id, scope: "agent",
                                   action_category: category, policy: verb,
                                   priority: 10, is_active: true)
  end

  def chain!(name)
    create(:ai_approval_chain, account: account, trigger_type: "autonomy_action",
                               status: "active", name: name, timeout_hours: 4)
  end

  # A notify-only SDWAN lane (skill: nil) — the purest gate-only path.
  def decide_service_silent
    engine.decide(kind: "system.sdwan_service_silent", severity: :high,
                  payload: { "service_id" => "svc-1" },
                  fingerprint: "sdwan_service_silent:svc-1")
  end

  describe "the declaration" do
    it "defaults a binding without an owner to fleet-autonomy" do
      expect(System::Fleet::DecisionEngine.owner_for({ action_category: "system.cert_rotate" }))
        .to eq("fleet-autonomy")
    end

    it "reassigns the sdwan, gitops-drift and disk-image-publication bindings to their specialist agents" do
      bindings = System::Fleet::DecisionEngine::SIGNAL_BINDINGS
      owner = ->(kind) { System::Fleet::DecisionEngine.owner_for(bindings.fetch(kind)) }

      expect(owner.call("system.sdwan_peer_drift")).to eq("sdwan-manager")
      expect(owner.call("system.sdwan_service_silent")).to eq("sdwan-manager")
      expect(owner.call("system.federation_peer_liveness")).to eq("sdwan-manager")
      expect(owner.call("system.gitops.drift_detected")).to eq("gitops-reconciler")
      expect(owner.call("system.disk_image_publication_failure_streak")).to eq("disk-image-manager")

      # The observation-routed kinds of the SAME sensors stay on Fleet Autonomy:
      # ownership follows the action category, not the sensor.
      expect(owner.call("system.sdwan_bgp_session_stale")).to eq("fleet-autonomy")
      expect(owner.call("system.sdwan_credential_refresh_stalled")).to eq("fleet-autonomy")
    end

    # THE EQUALITY ORACLE. A binding's owner must be the agent whose declared
    # set carries its action_category — otherwise the gate resolves against an
    # agent that has no row and the lane dies at the gate exactly as before,
    # one layer over. Every binding, not a sample.
    it "declares every binding's owner as the agent whose policy set declares its action_category" do
      mismatched = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.filter_map do |kind, binding|
        declared = System::Governance::PolicyDeclarations.owner_of(binding[:action_category])
        actual = System::Fleet::DecisionEngine.owner_for(binding)
        next if declared == actual

        "#{kind} -> #{binding[:action_category]}: binding owner #{actual.inspect}, " \
          "declared on #{declared.inspect}"
      end

      expect(mismatched).to eq([])
    end

    it "has real inputs (guards the equality above from passing vacuously)" do
      owners = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.values
                                                            .map { |b| System::Fleet::DecisionEngine.owner_for(b) }
                                                            .uniq
      expect(owners).to include("fleet-autonomy", "sdwan-manager", "gitops-reconciler", "disk-image-manager",
                                "capacity-manager", "storage-manager", "supply-chain-manager")
    end

    # HIER-P2DECL — the bindings whose category moved to a wave-1 manager.
    # Capacity: the DR replace lane and the three project.* adaptation kinds.
    # Storage: the assignment-drift lane. Supply chain: package drift. Ingress
    # and topology own NO sensor-routed category today — their rows gate the
    # executor/MCP doors only — and that is asserted rather than assumed.
    it "reassigns the capacity, storage and supply-chain bindings to the wave-1 managers" do
      bindings = System::Fleet::DecisionEngine::SIGNAL_BINDINGS
      owner = ->(kind) { System::Fleet::DecisionEngine.owner_for(bindings.fetch(kind)) }

      expect(owner.call("system.instance_unrecoverable")).to eq("capacity-manager")
      expect(owner.call("system.project_slo_violation")).to eq("capacity-manager")
      expect(owner.call("system.project_drift")).to eq("capacity-manager")
      expect(owner.call("system.project_cost_breach")).to eq("capacity-manager")
      expect(owner.call("system.storage_assignment_drift")).to eq("storage-manager")
      expect(owner.call("system.package_drift_pressure")).to eq("supply-chain-manager")

      # The remediation core stays: a silent instance is reprovisioned/rebooted
      # under Fleet Autonomy, and the replica-lag observation too.
      expect(owner.call("system.instance_silent")).to eq("fleet-autonomy")
      expect(owner.call("system.instance_state_drifted")).to eq("fleet-autonomy")
      expect(owner.call("system.replica_lag_unsafe")).to eq("fleet-autonomy")
    end

    it "routes no signal to an Ingress Manager or Topology Designer category (their rows gate the executor doors)" do
      routed = System::Fleet::DecisionEngine::SIGNAL_BINDINGS.values.map { |b| b[:action_category] }
      d = System::Governance::PolicyDeclarations
      expect(routed & d::INGRESS_MANAGER_POLICIES.keys).to eq([])
      expect(routed & d::TOPOLOGY_DESIGNER_POLICIES.keys).to eq([])
    end
  end

  # HIER-P2DECL moved declarations before wave 2 seeded the agents, so the
  # tick had to keep working with the new owners ABSENT — and still must: an
  # ESTABLISHED install whose first boot predates the wave-2 seeds
  # (HIER-P2B/P2C/P2D/P2E) still has the moved rows on Fleet Autonomy until
  # the seeds are re-run there (the reconciler skips a set whose agent is
  # absent and never moves a row off its former owner until the new one
  # exists), so the fallback gate finds them there. That install, not a fresh
  # one, is what this block models.
  describe "a wave-1 owner that is not seeded yet" do
    def decide_storage_drift(suffix = "1")
      engine.decide(kind: "system.storage_assignment_drift", severity: :medium,
                    payload: { "storage_assignment_id" => "sa-#{suffix}" },
                    fingerprint: "storage_assignment_drift:sa-#{suffix}")
    end

    it "gates a storage-manager-owned binding under Fleet Autonomy with the fleet.owner_agent_missing event" do
      fleet_chain = chain!("Fleet Autonomy Actions")
      policy!(fleet, "system.storage_assignment_reconcile", "require_approval")

      d = decide_storage_drift

      expect(d[:decision]).to eq(:pending)
      expect(d[:agent_id]).to eq(fleet.id)
      expect(d[:decision_record].approval_chain_id).to eq(fleet_chain.id)

      warned = System::FleetEvent.where(account: account,
                                        kind: System::Fleet::FleetAutonomyService::OWNER_MISSING_EVENT_KIND)
      expect(warned.count).to eq(1)
      expect(warned.last.payload).to include("owner" => "storage-manager", "fallback_agent_id" => fleet.id)
    end

    it "gates it under the Storage Manager once a stub agent with that identity exists" do
      identity = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch("storage-manager")
      storage = create(:ai_agent, account: account, agent_type: identity[:agent_type], name: identity[:name],
                                  source_key: "storage-manager")
      chain!("Fleet Autonomy Actions")
      storage_chain = chain!("Storage Manager Actions")
      # The row is where the reconciler puts it once the agent exists — on the owner.
      policy!(storage, "system.storage_assignment_reconcile", "require_approval")

      d = decide_storage_drift("2")

      expect(d[:decision]).to eq(:pending)
      expect(d[:agent_id]).to eq(storage.id)
      expect(d[:owner]).to eq("storage-manager")
      expect(d[:decision_record].approval_chain_id).to eq(storage_chain.id)
      expect(d[:decision_record].request_data["agent_key"]).to eq("storage-manager")
      expect(System::FleetEvent.where(account: account,
                                      kind: System::Fleet::FleetAutonomyService::OWNER_MISSING_EVENT_KIND).count).to eq(0)
    end

    it "gates the capacity-owned replace lane under the Capacity Manager when present, else Fleet Autonomy" do
      identity = System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch("capacity-manager")
      capacity = create(:ai_agent, account: account, agent_type: identity[:agent_type], name: identity[:name],
                                   source_key: "capacity-manager")
      expect(service.for_owner("capacity-manager").agent).to eq(capacity)

      absent = System::Fleet::FleetAutonomyService.new(account: account, agent: fleet)
      capacity.destroy!
      expect(absent.for_owner("capacity-manager")).to be(absent)
    end
  end

  describe "policy lookup" do
    it "gates a sdwan-manager-owned binding under SDWAN Manager's row, NOT Fleet Autonomy's" do
      allow(Rails.logger).to receive(:error)
      sdwan = sdwan_manager!
      # The row is on the tick agent only — where it used to have to be.
      policy!(fleet, "system.sdwan_service_health_investigate", "notify_and_proceed")

      blocked = decide_service_silent
      expect(blocked[:decision]).to eq(:blocked)
      expect(blocked[:gate]).to eq(System::Autonomy::RoutedLaneGuard::GATE_POLICY_MISSING)

      policy!(sdwan, "system.sdwan_service_health_investigate", "notify_and_proceed")

      # A fresh tick: #permitted_actions is memoized per gate for the life of
      # a tick service, exactly as it is on the tick agent's own gate.
      next_tick = System::Fleet::DecisionEngine.new(
        autonomy_service: System::Fleet::FleetAutonomyService.new(account: account, agent: fleet)
      )
      proceeded = next_tick.decide(kind: "system.sdwan_service_silent", severity: :high,
                                   payload: { "service_id" => "svc-2" },
                                   fingerprint: "sdwan_service_silent:svc-2")
      expect(proceeded[:decision]).to eq(:proceed)
      expect(proceeded[:gate]).to eq("notify_and_proceed")
      expect(proceeded[:agent_id]).to eq(sdwan.id)
      expect(proceeded[:owner]).to eq("sdwan-manager")
    end

    it "still gates a fleet-autonomy-owned binding under Fleet Autonomy when the specialist exists" do
      sdwan_manager!
      policy!(fleet, "system.cert_rotate", "auto_approve")

      d = engine.decide(kind: "system.cert_expiring", severity: :medium,
                        payload: { certificate_id: "c-1" }, fingerprint: "cert_expiring:c-1")

      expect(d[:decision]).to eq(:proceed)
      expect(d[:agent_id]).to eq(fleet.id)
    end
  end

  describe "approval chain and ApprovalRequest attribution" do
    it "mints the pending request on the OWNER's chain and stamps the owner's agent_id" do
      sdwan = sdwan_manager!
      fleet_chain = chain!("Fleet Autonomy Actions")
      sdwan_chain = chain!("SDWAN Manager Actions")
      policy!(sdwan, "system.sdwan_service_health_investigate", "require_approval")

      d = decide_service_silent

      expect(d[:decision]).to eq(:pending)
      request = d[:decision_record]
      expect(request).to be_present
      expect(request.approval_chain_id).to eq(sdwan_chain.id)
      expect(request.approval_chain_id).not_to eq(fleet_chain.id)
      expect(request.request_data["agent_id"]).to eq(sdwan.id)
      expect(request.request_data["agent_key"]).to eq("sdwan-manager")
    end

    it "keeps a Fleet-Autonomy-owned request on the fleet chain" do
      sdwan_manager!
      fleet_chain = chain!("Fleet Autonomy Actions")
      chain!("SDWAN Manager Actions")
      policy!(fleet, "system.cert_rotate", "require_approval")

      d = engine.decide(kind: "system.cert_expiring", severity: :medium,
                        payload: { certificate_id: "c-9" }, fingerprint: "cert_expiring:c-9")

      expect(d[:decision]).to eq(:pending)
      expect(d[:decision_record].approval_chain_id).to eq(fleet_chain.id)
      expect(d[:decision_record].request_data["agent_id"]).to eq(fleet.id)
    end
  end

  describe "EventBroadcaster attribution" do
    it "stamps the owner's agent_id on the notify event and on the decision event" do
      sdwan = sdwan_manager!
      policy!(sdwan, "system.sdwan_service_health_investigate", "notify_and_proceed")

      decide_service_silent

      notified = System::FleetEvent.where(account: account,
                                          kind: System::Fleet::FleetAutonomyService::NOTIFY_EVENT_KIND).last
      expect(notified.payload["agent_id"]).to eq(sdwan.id)

      decided = System::FleetEvent.where(account: account, kind: "decision.proceed").last
      expect(decided.payload["agent_id"]).to eq(sdwan.id)
    end
  end

  describe "executor construction" do
    it "hands the OWNER agent to the skill executor on the decide path" do
      sdwan = sdwan_manager!
      policy!(sdwan, "system.sdwan_failover", "require_approval")
      executor = instance_double(System::Ai::Skills::SdwanFailoverExecutor)
      expect(System::Ai::Skills::SdwanFailoverExecutor).to receive(:new)
        .with(account: account, agent: sdwan, user: nil).and_return(executor)
      allow(executor).to receive(:execute).and_return({ success: true, data: {} })

      engine.decide(kind: "system.sdwan_hub_unreachable", severity: :critical,
                    payload: { network_id: "net-1" }, fingerprint: "sdwan_hub_unreachable:net-1")
    end

    it "hands the OWNER agent to the skill executor on the approved-replay path" do
      sdwan = sdwan_manager!
      chain = chain!("SDWAN Manager Actions")
      request = Ai::ApprovalRequest.create!(
        account: account, approval_chain: chain, source_type: "system_fleet",
        status: "approved", description: "Fleet action: system.federation_peer_remediate",
        request_data: {
          "action_category" => "system.federation_peer_remediate",
          "payload" => { "federation_peer_id" => "fp-1", "reason" => "heartbeat_stale",
                         "signal_kind" => "system.federation_peer_liveness",
                         "signal_severity" => "high",
                         "signal_fingerprint" => "fed:fp-1" },
          "agent_role" => "fleet"
        }
      )
      executor = instance_double(System::Ai::Skills::FederationPeerRemediateExecutor)
      expect(System::Ai::Skills::FederationPeerRemediateExecutor).to receive(:new)
        .with(account: account, agent: sdwan, user: nil).and_return(executor)
      allow(executor).to receive(:execute).and_return({ success: true, data: {} })

      engine.execute_approved!(request)
    end
  end

  describe "a missing owner agent" do
    it "falls back to Fleet Autonomy with a WARN event, never silently dropping the sensor" do
      # No SDWAN Manager on this account. The row is where the reconciler
      # leaves it when the target agent is absent: on Fleet Autonomy.
      policy!(fleet, "system.sdwan_service_health_investigate", "notify_and_proceed")

      d = decide_service_silent

      expect(d[:decision]).to eq(:proceed)
      expect(d[:agent_id]).to eq(fleet.id)

      warned = System::FleetEvent.where(account: account,
                                        kind: System::Fleet::FleetAutonomyService::OWNER_MISSING_EVENT_KIND)
      expect(warned.count).to eq(1)
      expect(warned.last.severity).to eq("medium")
      expect(warned.last.payload).to include("owner" => "sdwan-manager",
                                             "fallback_agent_id" => fleet.id)
    end

    it "warns ONCE per tick service, not once per signal" do
      policy!(fleet, "system.sdwan_service_health_investigate", "notify_and_proceed")

      decide_service_silent
      engine.decide(kind: "system.sdwan_service_silent", severity: :high,
                    payload: { "service_id" => "svc-2" }, fingerprint: "sdwan_service_silent:svc-2")

      expect(System::FleetEvent.where(account: account,
                                      kind: System::Fleet::FleetAutonomyService::OWNER_MISSING_EVENT_KIND).count)
        .to eq(1)
    end
  end

  describe "FleetAutonomyService#for_owner" do
    it "returns itself for its own owner key" do
      expect(service.for_owner("fleet-autonomy")).to be(service)
      expect(service.for_owner(nil)).to be(service)
    end

    it "returns a gate for the owner agent, memoized per owner" do
      sdwan = sdwan_manager!
      gate = service.for_owner("sdwan-manager")

      expect(gate).to be_a(System::Fleet::FleetAutonomyService)
      expect(gate).not_to be(service)
      expect(gate.agent).to eq(sdwan)
      expect(gate.owner_key).to eq("sdwan-manager")
      expect(service.for_owner("sdwan-manager")).to be(gate)
    end

    it "resolves the owner override-aware, the same way the reconciler does" do
      global = create(:ai_agent, account: account, agent_type: "monitor", name: "Global SDWAN Manager",
                                 source_key: "sdwan-manager")
      global.update_columns(account_id: nil, name: "SDWAN Manager")
      override = sdwan_manager!

      expect(service.for_owner("sdwan-manager").agent).to eq(override)
    end
  end
end
