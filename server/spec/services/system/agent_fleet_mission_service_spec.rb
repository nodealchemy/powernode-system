# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L3 — agent-fleet mission orchestration.
# The provider is stubbed so no real cloud/libvirt call happens: each
# provision yields a fresh running instance on the fleet's node. This is the
# "simulated mission spins up N agents, delegates, reaps" acceptance.
RSpec.describe System::AgentFleetMissionService, type: :service do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }

  let(:fleet_spec) do
    {
      "size" => 3,
      "source" => "provision",
      "node_id" => node.id,
      "provider_region_id" => "region-x",
      "provider_instance_type_id" => "type-x",
      "grant_mcp_tools" => %w[platform.health],
      "grant_peer_skills" => %w[embed-*],
      "member_skills" => %w[embed-text],
      "subtasks" => [ { "id" => "s1", "skill" => "embed-text" }, { "id" => "s2", "skill" => "embed-text" } ],
      "delegation" => "hybrid",
      "reap" => true
    }
  end

  let(:mission) do
    create(:ai_mission, account: account, mission_type: "agent_fleet",
                        configuration: { "fleet_spec" => fleet_spec })
  end

  let(:service) { described_class.new(mission: mission) }

  before do
    allow(::System::ProvisioningService).to receive(:provision_instance) do |node:, **_kw|
      inst = create(:system_node_instance, :running, node: node)
      double(success?: true, error: nil, data: { instance: inst, cloud_instance_id: "ci-#{inst.id}" })
    end
    allow(::System::ProvisioningService).to receive(:terminate_instance) do |instance:|
      double(success?: true, error: nil)
    end
  end

  describe "#plan!" do
    it "validates the spec and persists a normalized plan" do
      result = service.plan!
      expect(result[:ok]).to be true
      plan = mission.reload.configuration.dig("fleet", "plan")
      expect(plan["size"]).to eq(3)
      expect(plan["delegation"]).to eq("hybrid")
      expect(plan["subtasks"].map { |s| s["id"] }).to eq(%w[s1 s2])
    end

    it "rejects an empty fleet" do
      mission.update!(configuration: { "fleet_spec" => fleet_spec.merge("size" => 0) })
      expect { service.plan! }.to raise_error(described_class::FleetError, /size/)
    end

    it "requires provisioning coordinates for the provision source" do
      mission.update!(configuration: { "fleet_spec" => fleet_spec.merge("provider_region_id" => nil) })
      expect { service.plan! }.to raise_error(described_class::FleetError, /provider_region_id/)
    end
  end

  describe "#provision!" do
    before { service.plan! }

    it "spins up N members, enrolls each as an enabled peer, and grants L2 + L2.5" do
      result = service.provision!
      expect(result[:count]).to eq(3)

      peers = System::NodeInstancePeer.where(account_id: account.id)
      expect(peers.count).to eq(3)
      expect(peers.all?(&:enabled?)).to be true
      expect(peers.first.granted_mcp_tools).to include("platform.health")
      expect(peers.first.granted_peer_skills).to include("embed-*")
      expect(peers.first.offered_skill_names).to include("embed-text")

      members = mission.reload.configuration.dig("fleet", "members")
      expect(members.size).to eq(3)
    end
  end

  # F1-06: provision! must be retry-safe for pool-source fleets — a retry
  # must resume from the persisted member list and reuse already-claimed
  # pool members instead of draining fresh ones while the first claims
  # leak in pool_state "claimed", invisible to reap!.
  describe "#provision! retry safety" do
    let(:fleet_spec) do
      {
        "size" => 2,
        "source" => "pool",
        "pool_name" => "workers",
        "grant_mcp_tools" => %w[platform.health],
        "grant_peer_skills" => %w[embed-*],
        "member_skills" => %w[embed-text],
        "subtasks" => [ { "id" => "s1", "skill" => "embed-text" } ],
        "delegation" => "central",
        "reap" => true
      }
    end

    let(:claimed_instances) { [] }

    before do
      service.plan!
      allow(::System::InstancePoolService).to receive(:acquire!) do
        inst = create(:system_node_instance, :running, node: node)
        claimed_instances << inst
        inst
      end
    end

    it "persists claims before enrollment and reuses them on retry instead of leaking" do
      announce_calls = 0
      allow(::System::AgentPeeringService).to receive(:announce!).and_wrap_original do |original, **kwargs|
        announce_calls += 1
        raise StandardError, "enrollment exploded" if announce_calls == 2

        original.call(**kwargs)
      end

      expect { service.provision! }.to raise_error(StandardError, /enrollment exploded/)

      # The acquired-but-unenrolled slot-1 instance must already be on the
      # mission record (reapable trail), alongside the completed slot 0.
      members_after_failure = mission.reload.configuration.dig("fleet", "members")
      expect(members_after_failure.map { |m| m["instance_id"] })
        .to match_array(claimed_instances.map(&:id))

      result = service.provision!

      expect(result[:count]).to eq(2)
      members = mission.reload.configuration.dig("fleet", "members")
      expect(members.map { |m| m["instance_id"] }).to match_array(claimed_instances.map(&:id))
      expect(members.map { |m| m["peer_id"] }).to all(be_present)
      # No fresh pool drains on retry — both claims were reused.
      expect(claimed_instances.size).to eq(2)
    end
  end

  # F1-08: reap failures must be visible — terminate_failed members are
  # leaked instances, not reaped ones — and a stuck fleet needs a force
  # lever even when its plan disabled reaping.
  describe "#reap! failure visibility" do
    before do
      service.plan!
      service.provision!
    end

    it "reports ok:false with reap_incomplete when a member fails to terminate" do
      failed_once = false
      allow(::System::ProvisioningService).to receive(:terminate_instance) do |instance:|
        if failed_once
          double(success?: true, error: nil)
        else
          failed_once = true
          double(success?: false, error: "provider timeout")
        end
      end

      result = service.reap!

      expect(result[:ok]).to be false
      expect(result[:reap_incomplete]).to be true
      expect(result[:failed_count]).to eq(1)
      expect(result[:reaped].map { |r| r["action"] }).to include("terminate_failed")
      expect(mission.reload.error_message).to match(/reap incomplete/i)
    end

    it "force-reaps a fleet whose plan disabled reaping" do
      cfg = mission.reload.configuration
      cfg["fleet"]["plan"]["reap"] = false
      mission.update_columns(configuration: cfg)

      expect(service.reap![:skipped]).to be true

      forced = service.reap!(force: true)
      expect(forced[:ok]).to be true
      expect(forced[:count]).to eq(3)
      expect(forced[:reaped].map { |r| r["action"] }).to all(eq("terminated"))
    end
  end

  describe "#delegate!" do
    before do
      service.plan!
      service.provision!
    end

    it "mints actionable A2A capability tokens for each authorized sub-delegation (hybrid)" do
      result = service.delegate!
      expect(result[:count]).to eq(2)
      assignments = result[:assignments]
      expect(assignments.map { |a| a["subtask_id"] }).to eq(%w[s1 s2])

      # hybrid: every member offers embed-text + is granted embed-*, so each
      # assignee may sub-delegate to the OTHER members (never to itself), and
      # each authorized edge carries a minted, self-contained capability token.
      targets = assignments.first["sub_delegation_targets"]
      expect(targets).to be_present
      expect(targets.map { |t| t["target_instance_id"] }).not_to include(assignments.first["assignee_instance_id"])
      expect(targets.first["skill"]).to eq("embed-text")
      tok = targets.first["capability_token"]
      expect(tok["envelope"]).to be_present
      expect(tok["signature"]).to be_present
      expect(tok["handle"]).to be_present
    end

    it "dispatches an on-node a2a_call task per tokenized sub-delegation (hybrid)" do
      result = service.delegate!
      expect(result[:dispatched_tasks]).to be_positive

      a2a_tasks = System::Task.where(command: "a2a_call")
      expect(a2a_tasks.count).to eq(result[:dispatched_tasks])
      opt = a2a_tasks.first.options
      expect(opt["skill"]).to eq("embed-text")
      expect(opt["capability_token"]["envelope"]).to be_present
      expect(opt["target_addresses"]).to be_a(Array)
      # the task is addressed to an assignee member NodeInstance.
      expect(a2a_tasks.first.operable_type).to eq("System::NodeInstance")
    end

    it "records no sub-delegation targets + dispatches nothing in central mode" do
      mission.update!(configuration: deep_set(mission.configuration, %w[fleet plan delegation], "central"))
      result = service.delegate!
      expect(result[:assignments].first["sub_delegation_targets"]).to eq([])
      expect(result[:dispatched_tasks]).to eq(0)
      expect(System::Task.where(command: "a2a_call").count).to eq(0)
    end
  end

  describe "#aggregate!" do
    before do
      service.plan!
      service.provision!
      service.delegate!
    end

    it "reports token coverage + dispatched task progress" do
      result = service.aggregate!
      report = result[:report]
      expect(report["subtasks_total"]).to eq(2)
      # delegate! minted capability tokens + dispatched a2a_call tasks.
      expect(report["delegation_tokens_minted"]).to be_positive
      expect(report["tasks_dispatched"]).to be_positive
      expect(report["tasks_complete"]).to eq(0)
      first = report["results"].first
      expect(first["sub_delegations_tokenized"]).to be_positive
      expect(first["dispatched_tasks"]).to be_positive
      # Tasks are pending (no on-node execution in the simulated mission).
      expect(report["results"].map { |r| r["status"] }).to all(eq("dispatched"))
    end

    it "flips a subtask to executed once its dispatched tasks complete" do
      System::Task.where(command: "a2a_call").update_all(status: "complete")
      report = service.aggregate![:report]
      expect(report["tasks_complete"]).to be_positive
      expect(report["results"].map { |r| r["status"] }).to all(eq("executed"))
    end

    it "reports waiting while dispatched tasks are not terminal" do
      result = service.aggregate!
      expect(result[:waiting]).to be true
      expect(result[:execution_outcome]).to be_nil
      expect(mission.reload.configuration.dig("fleet", "report", "execution_outcome")).to be_nil
    end

    it "settles with a complete outcome once every dispatched task finishes" do
      System::Task.where(command: "a2a_call").update_all(status: "complete")
      result = service.aggregate!
      expect(result[:waiting]).to be false
      expect(result[:execution_outcome]).to eq("complete")
      expect(mission.reload.configuration.dig("fleet", "report", "execution_outcome")).to eq("complete")
    end

    it "settles with a partial outcome when subtasks split between executed and failed" do
      tasks = System::Task.where(command: "a2a_call").to_a
      s1, rest = tasks.partition { |t| t.options["subtask_id"] == "s1" }
      System::Task.where(id: s1.map(&:id)).update_all(status: "complete")
      System::Task.where(id: rest.map(&:id)).update_all(status: "failed")

      result = service.aggregate!
      expect(result[:waiting]).to be false
      expect(result[:execution_outcome]).to eq("partial")
    end

    it "times out with a timeout outcome when execution never starts" do
      mission.update!(configuration: deep_set(mission.reload.configuration,
                                              %w[fleet aggregate_started_at], 2.hours.ago.iso8601))
      result = service.aggregate!
      expect(result[:waiting]).to be false
      expect(result[:execution_outcome]).to eq("timeout")
      expect(mission.reload.configuration.dig("fleet", "report", "execution_outcome")).to eq("timeout")
    end
  end

  describe "#reserve_aggregate_recheck!" do
    before do
      service.plan!
      service.provision!
      service.delegate!
    end

    it "reserves a poll slot and returns the delay" do
      delay = service.reserve_aggregate_recheck!
      expect(delay).to eq(described_class::DEFAULT_AGGREGATE_POLL_SECONDS)
      expect(mission.reload.configuration.dig("fleet", "aggregate_next_check_at")).to be_present
    end

    it "returns nil while a re-check is already pending (stale retries must not multiply)" do
      service.reserve_aggregate_recheck!
      expect(service.reserve_aggregate_recheck!).to be_nil
    end
  end

  describe "#reap!" do
    before do
      service.plan!
      service.provision!
    end

    it "terminates members and disables their peers" do
      result = service.reap!
      expect(result[:count]).to eq(3)
      expect(result[:reaped].map { |r| r["action"] }).to all(eq("terminated"))
      expect(System::NodeInstancePeer.where(account_id: account.id).where(enabled: true)).to be_empty
      expect(::System::ProvisioningService).to have_received(:terminate_instance).exactly(3).times
    end

    it "honors reap: false (leaves the fleet running)" do
      mission.update!(configuration: deep_set(mission.configuration, %w[fleet plan reap], false))
      result = service.reap!
      expect(result[:skipped]).to be true
      expect(::System::ProvisioningService).not_to have_received(:terminate_instance)
    end
  end

  describe "isolation tier (L0)" do
    it "defaults to native and records the runtime profile in the plan" do
      service.plan!
      plan = mission.reload.configuration.dig("fleet", "plan")
      expect(plan["isolation_tier"]).to eq("native")
      expect(plan["isolation"]["docker_runtime"]).to eq("runc")
    end

    it "honors a requested tier and stamps it on members + instance config" do
      mission.update!(configuration: { "fleet_spec" => fleet_spec.merge("isolation_tier" => "gvisor") })
      service.plan!
      result = service.provision!
      expect(result[:members].first["isolation"]["docker_runtime"]).to eq("runsc")
      inst = System::NodeInstance.find(result[:members].first["instance_id"])
      expect(inst.config.dig("isolation", "tier")).to eq("gvisor")
    end

    it "rejects an unknown tier" do
      mission.update!(configuration: { "fleet_spec" => fleet_spec.merge("isolation_tier" => "nope") })
      expect { service.plan! }.to raise_error(described_class::FleetError, /isolation_tier/)
    end
  end

  it "runs the full plan -> provision -> delegate -> aggregate -> reap loop" do
    expect(service.plan![:ok]).to be true
    expect(service.provision![:count]).to eq(3)
    expect(service.delegate![:count]).to eq(2)
    expect(service.aggregate![:report]["subtasks_total"]).to eq(2)
    expect(service.reap![:count]).to eq(3)
  end

  # Set a nested key on a deep-duped copy of a config hash (string-keyed).
  def deep_set(hash, path, value)
    h = hash.deep_dup
    *head, tail = path
    head.reduce(h) { |acc, k| acc[k] ||= {}; acc[k] }[tail] = value
    h
  end
end
