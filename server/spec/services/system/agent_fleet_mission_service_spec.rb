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

  describe "#delegate!" do
    before do
      service.plan!
      service.provision!
    end

    it "assigns subtasks round-robin + records authorized A2A sub-delegation targets (hybrid)" do
      result = service.delegate!
      expect(result[:count]).to eq(2)
      assignments = result[:assignments]
      expect(assignments.map { |a| a["subtask_id"] }).to eq(%w[s1 s2])

      # hybrid: every member offers embed-text + is granted embed-*, so each
      # assignee may sub-delegate to the OTHER members (never to itself).
      targets = assignments.first["sub_delegation_targets"]
      expect(targets).to be_present
      expect(targets).not_to include(assignments.first["assignee_instance_id"])
    end

    it "records no sub-delegation targets in central mode" do
      mission.update!(configuration: deep_set(mission.configuration, %w[fleet plan delegation], "central"))
      result = service.delegate!
      expect(result[:assignments].first["sub_delegation_targets"]).to eq([])
    end
  end

  describe "#aggregate!" do
    before do
      service.plan!
      service.provision!
      service.delegate!
    end

    it "produces a complete report envelope per subtask" do
      result = service.aggregate!
      report = result[:report]
      expect(report["subtasks_total"]).to eq(2)
      expect(report["completed"]).to eq(2)
      expect(report["results"].map { |r| r["status"] }).to all(eq("completed"))
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

  it "runs the full plan -> provision -> delegate -> aggregate -> reap loop" do
    expect(service.plan![:ok]).to be true
    expect(service.provision![:count]).to eq(3)
    expect(service.delegate![:count]).to eq(2)
    expect(service.aggregate![:report]["completed"]).to eq(2)
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
