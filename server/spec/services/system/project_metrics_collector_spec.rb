# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ProjectMetricsCollector do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  def build_active_infrastructure_mission
    m = create(
      :ai_mission,
      account: account,
      created_by: user,
      mission_type: "infrastructure",
      custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ]
    )
    m.update_columns(status: "active")
    m
  end

  describe ".collect!" do
    it "writes one ProjectMetric row per known metric_name" do
      mission = build_active_infrastructure_mission

      expect {
        described_class.collect!(mission: mission)
      }.to change { System::ProjectMetric.where(mission_id: mission.id).count }
        .by(described_class::METRIC_TYPE_MAP.size)

      names = System::ProjectMetric.where(mission_id: mission.id).pluck(:metric_name)
      expect(names).to match_array(described_class::METRIC_TYPE_MAP.keys)
    end

    it "stamps each row with the matching metric_type from METRIC_TYPE_MAP" do
      mission = build_active_infrastructure_mission
      described_class.collect!(mission: mission)

      System::ProjectMetric.where(mission_id: mission.id).find_each do |row|
        expect(row.metric_type).to eq(described_class::METRIC_TYPE_MAP.fetch(row.metric_name))
      end
    end

    it "writes honest 'unavailable' samples (observed=nil, source=unavailable) for un-backed metrics" do
      mission = build_active_infrastructure_mission
      described_class.collect!(mission: mission)

      %w[p99_latency_ms availability_pct cpu_pct memory_pct cost_usd_mtd].each do |name|
        row = System::ProjectMetric.where(mission_id: mission.id, metric_name: name).first
        expect(row.value).to include("observed" => nil, "source" => "unavailable"),
          "expected #{name} to be an honest unavailable sample, got #{row.value.inspect}"
      end

      latency = System::ProjectMetric.where(mission_id: mission.id, metric_name: "p99_latency_ms").first
      expect(latency.value["unit"]).to eq("ms")
    end

    it "never records a fabricated zero observation for an un-backed metric" do
      mission = build_active_infrastructure_mission
      described_class.collect!(mission: mission)

      fabricated_zeros = System::ProjectMetric
        .where(mission_id: mission.id)
        .reject { |r| r.value["source"] == "live" }
        .select { |r| r.value["observed"] == 0 }
      expect(fabricated_zeros).to be_empty
    end

    it "reports replica_count/region_count as 'unavailable' when the mission has no resolvable plan" do
      mission = build_active_infrastructure_mission # no configuration["plan"]
      described_class.collect!(mission: mission)

      %w[replica_count region_count].each do |name|
        row = System::ProjectMetric.where(mission_id: mission.id, metric_name: name).first
        expect(row.value).to include("observed" => nil, "source" => "unavailable")
      end
    end

    it "samples real replica_count/region_count from the mission's provisioned instances" do
      # Reproduce the mission -> GoalPlan -> completed step -> last_outputs
      # chain the provisioning runner records, then point the mission at it.
      agent = create(:ai_agent, account: account)
      goal  = Ai::AgentGoal.create!(
        account: account, agent: agent, title: "provision",
        goal_type: "creation", status: "active", priority: 3, progress: 0.0
      )
      plan = Ai::GoalPlan.create!(
        account: account, goal: goal, agent: agent, status: "approved", version: 1
      )

      node   = create(:system_node, account: account)
      region = create(:system_provider_region)
      inst_a = create(:system_node_instance, :running, node: node, provider_region: region)
      inst_b = create(:system_node_instance, :running, node: node, provider_region: region)

      plan.steps.create!(
        step_number: 1, status: "completed", step_type: "provisioning_skill",
        metadata: { "last_outputs" => { "node_instance_ids" => [ inst_a.id, inst_b.id ] } }
      )

      mission = create(
        :ai_mission, account: account, created_by: user, mission_type: "infrastructure",
        custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ],
        configuration: { "plan" => { "plan_id" => plan.id } }
      )
      mission.update_columns(status: "active")

      described_class.collect!(mission: mission)

      replica    = System::ProjectMetric.where(mission_id: mission.id, metric_name: "replica_count").first
      region_row = System::ProjectMetric.where(mission_id: mission.id, metric_name: "region_count").first
      expect(replica.value).to include("observed" => 2, "source" => "live")
      # both instances share one provider region → 1 distinct region
      expect(region_row.value).to include("observed" => 1, "source" => "live")
    end

    it "threads the supplied correlation_id onto every row" do
      mission = build_active_infrastructure_mission
      corr = "tick:abc123"
      described_class.collect!(mission: mission, correlation_id: corr)

      correlation_ids = System::ProjectMetric.where(mission_id: mission.id).pluck(:correlation_id).uniq
      expect(correlation_ids).to eq([ corr ])
    end

    it "synthesizes a correlation_id when none is supplied (project_metrics:<mission_id>:<bucket>)" do
      mission = build_active_infrastructure_mission
      described_class.collect!(mission: mission)

      correlation = System::ProjectMetric.where(mission_id: mission.id).pluck(:correlation_id).first
      expect(correlation).to match(/\Aproject_metrics:#{mission.id}:\d+\z/)
    end

    it "stamps the same sampled_at for every row in a single batch" do
      mission = build_active_infrastructure_mission
      described_class.collect!(mission: mission)

      timestamps = System::ProjectMetric.where(mission_id: mission.id).pluck(:sampled_at).uniq
      expect(timestamps.size).to eq(1)
    end

    it "skips non-infrastructure missions" do
      m = create(:ai_mission, account: account, created_by: user, mission_type: "operations")
      m.update_columns(status: "active")

      expect {
        described_class.collect!(mission: m)
      }.not_to change(System::ProjectMetric, :count)
    end

    it "returns an empty array (not nil) when the mission is non-infrastructure" do
      m = create(:ai_mission, account: account, created_by: user, mission_type: "operations")
      m.update_columns(status: "active")

      expect(described_class.collect!(mission: m)).to eq([])
    end

    it "returns the array of created records" do
      mission = build_active_infrastructure_mission
      records = described_class.collect!(mission: mission)
      expect(records).to all(be_a(System::ProjectMetric))
      expect(records.size).to eq(described_class::METRIC_TYPE_MAP.size)
    end

    it "every metric_name maps to a metric_type accepted by the model" do
      described_class::METRIC_TYPE_MAP.each_value do |t|
        expect(System::ProjectMetric::METRIC_TYPES).to include(t),
          "metric_type #{t.inspect} from METRIC_TYPE_MAP not in model allow-list"
      end
    end
  end
end
