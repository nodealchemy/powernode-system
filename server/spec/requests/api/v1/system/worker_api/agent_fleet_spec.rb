# frozen_string_literal: true

require "rails_helper"

# AI/MCP workload substrate L3 — agent-fleet mission phase callbacks (worker_api).
# Verifies the worker → service → self-advance wiring + the review_fleet gate.
RSpec.describe "Api::V1::System::WorkerApi::AgentFleet", type: :request do
  let(:worker) { create(:worker) }
  let(:headers) { worker_mtls_headers(worker).merge("Content-Type" => "application/json") }
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }

  let(:agent_fleet_phases) do
    [
      { "order" => 0, "key" => "plan_fleet",      "requires_approval" => false, "job_class" => "AiAgentFleetPlanJob" },
      { "order" => 1, "key" => "review_fleet",    "requires_approval" => true,  "job_class" => nil, "gate_name" => "fleet_review" },
      { "order" => 2, "key" => "provision_fleet", "requires_approval" => false, "job_class" => "AiAgentFleetProvisionJob" },
      { "order" => 3, "key" => "delegate",        "requires_approval" => false, "job_class" => "AiAgentFleetDelegateJob" },
      { "order" => 4, "key" => "aggregate",       "requires_approval" => false, "job_class" => "AiAgentFleetAggregateJob" },
      { "order" => 5, "key" => "reap",            "requires_approval" => false, "job_class" => "AiAgentFleetReapJob" }
    ]
  end

  let(:template) do
    create(:ai_mission_template, name: "system_agent_fleet_req", template_type: "system",
                                 mission_type: "agent_fleet", phases: agent_fleet_phases,
                                 approval_gates: %w[review_fleet],
                                 rejection_mappings: { "review_fleet" => "plan_fleet" })
  end

  let(:fleet_spec) do
    {
      "size" => 2, "source" => "provision", "node_id" => node.id,
      "provider_region_id" => "r", "provider_instance_type_id" => "t",
      "grant_mcp_tools" => %w[platform.health], "grant_peer_skills" => %w[embed-*],
      "member_skills" => %w[embed-text],
      "subtasks" => [ { "id" => "s1", "skill" => "embed-text" } ],
      "delegation" => "hybrid", "reap" => true
    }
  end

  def fleet_mission(phase:)
    create(:ai_mission, account: account, mission_type: "agent_fleet", mission_template: template,
                        status: "active", current_phase: phase, configuration: { "fleet_spec" => fleet_spec })
  end

  def path(mission, phase)
    "/api/v1/system/worker_api/agent_fleet/missions/#{mission.id}/#{phase}"
  end

  # Never enqueue real worker jobs when a phase self-advances to a non-gate phase.
  before { allow(WorkerJobService).to receive(:enqueue_job) }

  describe "auth + guards" do
    it "401 without worker mTLS" do
      m = fleet_mission(phase: "plan_fleet")
      post path(m, "plan_fleet")
      expect(response).to have_http_status(:unauthorized)
    end

    it "404 for an unknown mission" do
      post "/api/v1/system/worker_api/agent_fleet/missions/#{SecureRandom.uuid}/plan_fleet", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "422 for a non-agent_fleet mission" do
      other = create(:ai_mission, account: account, mission_type: "operations")
      post path(other, "plan_fleet"), headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "plan_fleet" do
    it "composes the plan and advances to the review_fleet approval gate (no dispatch)" do
      m = fleet_mission(phase: "plan_fleet")
      post path(m, "plan_fleet"), headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "phase")).to eq("review_fleet")
      expect(m.reload.current_phase).to eq("review_fleet")
      expect(m.configuration.dig("fleet", "plan", "size")).to eq(2)
      expect(WorkerJobService).not_to have_received(:enqueue_job) # gate → no auto-dispatch
    end
  end

  describe "provision_fleet" do
    before do
      allow(::System::ProvisioningService).to receive(:provision_instance) do |node:, **_kw|
        inst = create(:system_node_instance, :running, node: node)
        double(success?: true, error: nil, data: { instance: inst, cloud_instance_id: "ci-#{inst.id}" })
      end
    end

    it "provisions members + self-advances to delegate" do
      m = fleet_mission(phase: "provision_fleet")
      ::System::AgentFleetMissionService.new(mission: m).plan! # fleet.plan must exist first

      post path(m, "provision_fleet"), headers: headers

      expect(response).to have_http_status(:ok)
      expect(m.reload.current_phase).to eq("delegate")
      expect(System::NodeInstancePeer.where(account_id: account.id).count).to eq(2)
    end
  end

  describe "aggregate (execution wait before reap)" do
    before do
      allow(::System::ProvisioningService).to receive(:provision_instance) do |node:, **_kw|
        inst = create(:system_node_instance, :running, node: node)
        double(success?: true, error: nil, data: { instance: inst, cloud_instance_id: "ci-#{inst.id}" })
      end
    end

    # Mission with real delegated state: plan + members + assignments +
    # dispatched (pending) a2a_call tasks — exactly what the on-node agents
    # would still be executing when aggregate first runs.
    def delegated_mission
      m = fleet_mission(phase: "aggregate")
      svc = ::System::AgentFleetMissionService.new(mission: m)
      svc.plan!
      svc.provision!
      svc.delegate!
      m.reload
    end

    it "does not advance while dispatched tasks are pending and re-enqueues a delayed re-check" do
      m = delegated_mission
      post path(m, "aggregate"), headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "waiting")).to be true
      expect(m.reload.current_phase).to eq("aggregate")
      expect(WorkerJobService).to have_received(:enqueue_job)
        .with("AiAgentFleetAggregateJob", hash_including(delay: kind_of(Numeric)))
    end

    it "advances to reap with a complete outcome once dispatched tasks finish" do
      m = delegated_mission
      System::Task.where(command: "a2a_call").update_all(status: "complete")

      post path(m, "aggregate"), headers: headers

      expect(response).to have_http_status(:ok)
      expect(m.reload.current_phase).to eq("reap")
      expect(m.configuration.dig("fleet", "report", "execution_outcome")).to eq("complete")
    end

    it "advances with a timeout outcome when the execution window elapses" do
      m = delegated_mission
      cfg = m.configuration.deep_dup
      cfg["fleet"]["aggregate_started_at"] = 2.hours.ago.iso8601
      m.update!(configuration: cfg)

      post path(m, "aggregate"), headers: headers

      expect(response).to have_http_status(:ok)
      expect(m.reload.current_phase).to eq("reap")
      expect(m.configuration.dig("fleet", "report", "execution_outcome")).to eq("timeout")
    end
  end

  describe "inactive mission guard (cancel/pause mid-flight)" do
    before do
      allow(::System::ProvisioningService).to receive(:provision_instance) do |node:, **_kw|
        inst = create(:system_node_instance, :running, node: node)
        double(success?: true, error: nil, data: { instance: inst, cloud_instance_id: "ci-#{inst.id}" })
      end
      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(double(success?: true, error: nil))
    end

    it "skips phase work and does not advance a cancelled mission" do
      m = fleet_mission(phase: "provision_fleet")
      ::System::AgentFleetMissionService.new(mission: m).plan!
      m.update!(status: "cancelled")

      post path(m, "provision_fleet"), headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "skipped")).to be true
      expect(m.reload.current_phase).to eq("provision_fleet")
      expect(::System::ProvisioningService).not_to have_received(:provision_instance)
    end

    it "skips phase work on a paused mission" do
      m = fleet_mission(phase: "delegate")
      svc = ::System::AgentFleetMissionService.new(mission: m)
      svc.plan!
      svc.provision!
      m.update!(status: "paused")

      post path(m, "delegate"), headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "skipped")).to be true
      expect(m.reload.current_phase).to eq("delegate")
      expect(System::Task.where(command: "a2a_call")).to be_empty
    end

    it "reap on a cancelled mission releases members without advancing" do
      m = fleet_mission(phase: "delegate")
      svc = ::System::AgentFleetMissionService.new(mission: m)
      svc.plan!
      svc.provision!
      m.update!(status: "cancelled")

      post path(m, "reap"), headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)["data"]
      expect(body["cleanup"]).to be true
      expect(body["count"]).to eq(2)
      expect(::System::ProvisioningService).to have_received(:terminate_instance).twice
      m.reload
      expect(m.current_phase).to eq("delegate")
      expect(m.status).to eq("cancelled")
    end

    it "does not reap a paused mission" do
      m = fleet_mission(phase: "reap")
      svc = ::System::AgentFleetMissionService.new(mission: m)
      svc.plan!
      svc.provision!
      m.update!(status: "paused")

      post path(m, "reap"), headers: headers

      expect(JSON.parse(response.body).dig("data", "skipped")).to be true
      expect(::System::ProvisioningService).not_to have_received(:terminate_instance)
    end
  end
end
