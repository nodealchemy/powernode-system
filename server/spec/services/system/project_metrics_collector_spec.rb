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

    # THE WRITER'S THREE SHAPES (IMP-9978fcf23a27).
    #
    # SkillCompositionRunner#result_outputs is
    #   result[:data] || result["data"] || result[:outputs] || result["outputs"] || result.to_h
    # and whatever it returns is stored VERBATIM as metadata["last_outputs"]
    # (#record_outputs). So the envelope an executor returns decides how deep the
    # ids sit, and the three branches put them in two different places:
    #
    #   :data present  -> last_outputs is the payload; ids under its "outputs" key
    #   :outputs only  -> last_outputs IS the outputs hash; ids at the TOP level
    #   neither        -> last_outputs is result.to_h; ids at the TOP level
    #
    # Enumerated rather than assumed, per this task's direction: every executor
    # resolvable by SkillCompositionRunner.resolve_executor today (58 under
    # System::Ai::Skills, 2 under Ai::Skills) returns BaseSkillExecutor#success,
    # i.e. { success: true, data: payload } — CrudFactory subclasses included.
    # So only the first branch is reached in production right now, and the
    # collector was not silently broken. The other two are live branches of the
    # writer with no executor behind them, and a reader that handles one shape of
    # a three-shape writer is one commit away from the original defect.
    def data_envelope(instance_ids)
      { success: true,
        data: { dry_run: false, count: instance_ids.size, planned_actions: [],
                outputs: { node_ids: [], node_instance_ids: instance_ids,
                           sdwan_peer_ids: [], storage_volume_ids: [] },
                failures: [], partial: false } }
    end

    def outputs_envelope(instance_ids)
      { success: true, outputs: { node_instance_ids: instance_ids } }
    end

    def flat_envelope(instance_ids)
      { success: true, node_instance_ids: instance_ids, count: instance_ids.size }
    end

    # Builds mission -> GoalPlan -> completed step, recording the step's outputs
    # through the PRODUCTION writer (SkillCompositionRunner#result_outputs +
    # #record_outputs) fed the envelope BaseSkillExecutor#success actually
    # returns. A hand-written metadata literal is exactly what let IMP-3431f73dabe6
    # survive: this spec used to author `last_outputs.node_instance_ids` — the
    # shape the collector dug for and nothing ever wrote — so it went green while
    # production never reached the live branch at all.
    def seed_provisioned_mission(instance_ids, result: nil)
      agent = create(:ai_agent, account: account)
      goal  = Ai::AgentGoal.create!(
        account: account, agent: agent, title: "provision",
        goal_type: "creation", status: "active", priority: 3, progress: 0.0
      )
      plan = Ai::GoalPlan.create!(
        account: account, goal: goal, agent: agent, status: "approved", version: 1
      )

      mission = create(
        :ai_mission, account: account, created_by: user, mission_type: "infrastructure",
        custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ],
        configuration: { "plan" => { "plan_id" => plan.id } }
      )
      mission.update_columns(status: "active")

      step = plan.steps.create!(step_number: 1, status: "pending", step_type: "provisioning_skill")

      # The literal an executor hands back: { success:, data: <payload> }, the
      # payload carrying its node ids under a NESTED `outputs` key.
      executor_result = result || data_envelope(instance_ids)

      # mark_completed, not record_outputs directly: it is the method the
      # runner's success arm calls (skill_composition_runner.rb:195), and it
      # persists through Ai::GoalPlanStep#complete! the way production does.
      runner = ::Ai::Provisioning::SkillCompositionRunner.new(account: account, mission: mission, plan: plan)
      runner.send(:mark_completed, step, runner.send(:result_outputs, executor_result))

      [ mission, plan, step.reload ]
    end

    it "samples real replica_count/region_count from the mission's provisioned instances" do
      node   = create(:system_node, account: account)
      region = create(:system_provider_region)
      inst_a = create(:system_node_instance, :running, node: node, provider_region: region)
      inst_b = create(:system_node_instance, :running, node: node, provider_region: region)

      mission, = seed_provisioned_mission([ inst_a.id, inst_b.id ])

      described_class.collect!(mission: mission)

      replica    = System::ProjectMetric.where(mission_id: mission.id, metric_name: "replica_count").first
      region_row = System::ProjectMetric.where(mission_id: mission.id, metric_name: "region_count").first
      expect(replica.value).to include("observed" => 2, "source" => "live")
      # both instances share one provider region → 1 distinct region
      expect(region_row.value).to include("observed" => 1, "source" => "live")
    end

    # IMP-797a87dbd0bd. `error` is in NodeInstance::STATUSES, and both samplers
    # used to filter on `where.not(status: "terminated")` alone — so a replica
    # the control plane had marked FAILED still counted toward capacity. The
    # mission reported its full replica count, ProjectSloSensor#detect_drift
    # compares observed != expected and so stayed silent, and the one case the
    # drift signal most needs to catch produced nothing.
    #
    # Asserted end to end (collector -> metric row -> sensor) rather than on the
    # sampler alone: the silence was a property of the PAIR, and a collector-only
    # example would still pass if the sensor stopped reading the row.
    it "excludes an errored instance from replica_count and drifts on the shortfall" do
      node   = create(:system_node, account: account)
      region = create(:system_provider_region)
      inst_a = create(:system_node_instance, :running, node: node, provider_region: region)
      inst_b = create(:system_node_instance, :running, node: node, provider_region: region)
      inst_c = create(:system_node_instance, node: node, provider_region: region, status: "error")

      mission, = seed_provisioned_mission([ inst_a.id, inst_b.id, inst_c.id ])
      mission.update_columns(
        configuration: mission.configuration.merge(
          "brief" => { "scale" => { "initial" => 3 }, "regions" => [ "us-east-1" ] }
        )
      )

      described_class.collect!(mission: mission)

      replica = System::ProjectMetric.where(mission_id: mission.id, metric_name: "replica_count").first
      expect(replica.value).to include("observed" => 2, "source" => "live")

      drift = System::Fleet::Sensors::ProjectSloSensor.new(account: account).sense
                                                      .find { |s| s.kind == "system.project_drift" }
      expect(drift).not_to be_nil
      expect(drift.payload).to include(
        "drift_type" => "replica_count",
        "observed"   => 2,
        "target"     => 3
      )
    end

    # region_count carries the SAME filter and the same failure: a region whose
    # only instance has errored is a region the mission no longer occupies, and
    # counting it reports full geographic coverage the fleet does not have.
    # Two live instances in one region plus a lone errored instance in another
    # separates the two samplers — replica_count drops by one, region_count
    # drops the whole region.
    it "drops a region whose only instance has errored from region_count" do
      node     = create(:system_node, account: account)
      region_a = create(:system_provider_region)
      region_b = create(:system_provider_region)
      inst_a = create(:system_node_instance, :running, node: node, provider_region: region_a)
      inst_b = create(:system_node_instance, :running, node: node, provider_region: region_a)
      inst_c = create(:system_node_instance, node: node, provider_region: region_b, status: "error")

      mission, = seed_provisioned_mission([ inst_a.id, inst_b.id, inst_c.id ])

      described_class.collect!(mission: mission)

      region_row = System::ProjectMetric.where(mission_id: mission.id, metric_name: "region_count").first
      expect(region_row.value).to include("observed" => 1, "source" => "live")
    end

    # The transitional states are the other half of the decision. `starting`,
    # `stopping` and `rebooting` are mid-lifecycle, not failed — a replica
    # rebooting is still a replica the mission expects back within seconds.
    # Excluding them (which the model's own `active` scope does — it is
    # pending/provisioning/running/stopped) would make every routine reboot
    # emit capacity drift and provoke a replacement provision, which is why
    # this sampler does NOT reuse that scope. Pinned so a later "just use
    # .active" simplification fails here instead of in production.
    it "still counts instances in transitional states as live replicas" do
      node   = create(:system_node, account: account)
      region = create(:system_provider_region)
      instances = %w[pending provisioning starting running stopping stopped rebooting].map do |status|
        create(:system_node_instance, node: node, provider_region: region, status: status)
      end

      mission, = seed_provisioned_mission(instances.map(&:id))

      described_class.collect!(mission: mission)

      replica = System::ProjectMetric.where(mission_id: mission.id, metric_name: "replica_count").first
      expect(replica.value).to include("observed" => 7, "source" => "live")
    end

    # The other terminal exclusion, kept alongside `error` so the pair is one
    # readable statement of what "live" means here.
    it "excludes terminated instances from replica_count" do
      node   = create(:system_node, account: account)
      region = create(:system_provider_region)
      inst_a = create(:system_node_instance, :running, node: node, provider_region: region)
      inst_b = create(:system_node_instance, node: node, provider_region: region, status: "terminated")

      mission, = seed_provisioned_mission([ inst_a.id, inst_b.id ])

      described_class.collect!(mission: mission)

      replica = System::ProjectMetric.where(mission_id: mission.id, metric_name: "replica_count").first
      expect(replica.value).to include("observed" => 1, "source" => "live")
    end

    # Divergence guard. Several readers dig this one envelope independently, and
    # the defect was possible only because its shape is re-derived in each of
    # them. Compare against AdaptationDispatchService#produced_instance_ids
    # (core) — it performs its OWN dig, so this asserts agreement between two
    # real readers rather than against a path spelled out in the spec.
    it "resolves the same instance ids a core reader digs out of the same step" do
      node   = create(:system_node, account: account)
      inst_a = create(:system_node_instance, :running, node: node)
      inst_b = create(:system_node_instance, :running, node: node)

      mission, _plan, step = seed_provisioned_mission([ inst_a.id, inst_b.id ])

      core_ids = ::Ai::Provisioning::AdaptationDispatchService
                 .new(account: account, mission: mission)
                 .send(:produced_instance_ids, step)

      collector_ids = described_class.new(mission: mission).send(:resolvable_instance_ids).map(&:to_s)

      expect(core_ids).to match_array([ inst_a.id, inst_b.id ])
      expect(collector_ids).to match_array(core_ids)
    end

    # One example per writer branch, each fed through the PRODUCTION writer
    # (#result_outputs -> #mark_completed) rather than a hand-written metadata
    # literal — the mistake that let the original defect go green.
    #
    # The first is the shape production reaches today; it is here so the three
    # sit side by side and a future reader can see which branch each pins.
    describe "every shape SkillCompositionRunner#result_outputs can store" do
      def resolved_ids_for(envelope, ids)
        mission, = seed_provisioned_mission(ids, result: envelope)
        described_class.new(mission: mission).send(:resolvable_instance_ids).map(&:to_s)
      end

      it "reads ids from a :data envelope (nested under 'outputs')" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))

        expect(resolved_ids_for(data_envelope([ inst.id ]), [ inst.id ])).to eq([ inst.id ])
      end

      it "reads ids from an :outputs envelope, where last_outputs IS the outputs hash" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))

        expect(resolved_ids_for(outputs_envelope([ inst.id ]), [ inst.id ])).to eq([ inst.id ])
      end

      it "reads ids from a bare envelope that falls through to result.to_h" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))

        expect(resolved_ids_for(flat_envelope([ inst.id ]), [ inst.id ])).to eq([ inst.id ])
      end

      # The union must not double-count a step carrying the id at both depths.
      #
      # NOTE THE ENVELOPE. An earlier version of this example put :outputs
      # BESIDE :data at the envelope level — which pins nothing, because
      # #result_outputs returns result[:data] FIRST and throws the sibling key
      # away, so only one depth ever reached last_outputs. A mutation test
      # (dropping the caller's .uniq) killed no example and exposed it.
      #
      # Both depths can only coexist INSIDE the stored payload, which is a real
      # shape: a composing executor whose data echoes its own ids alongside the
      # nested outputs block it assembled.
      it "dedupes an id that appears at both levels" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        both = { success: true,
                 data: { node_instance_ids: [ inst.id ],
                         outputs: { node_instance_ids: [ inst.id ] } } }

        expect(resolved_ids_for(both, [ inst.id ])).to eq([ inst.id ])
      end
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
