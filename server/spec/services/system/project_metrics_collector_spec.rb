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

    # IMP-25e75f960dee — the "lands dark" ratchet. Offer 01a02bfb-84bd is the
    # precedent: ProjectSloSensor maps only 5 of the 7 KNOWN_METRIC_NAMES, so
    # cpu_pct/memory_pct would land dark even if perfectly produced. The same
    # divergence one step earlier — a name in the model's vocabulary that this
    # collector never samples, or a sampled name the model rejects — is
    # invisible to every other example in this file, because each one asserts
    # against METRIC_TYPE_MAP alone. Pin the two lists to each other.
    it "samples exactly the vocabulary System::ProjectMetric declares" do
      expect(described_class::METRIC_TYPE_MAP.keys)
        .to match_array(System::ProjectMetric::KNOWN_METRIC_NAMES)
    end

    # ---------------------------------------------------------------------
    # IMP-25e75f960dee — sdwan_throughput_bytes_per_s
    #
    # ATTRIBUTION under test: mission -> resolvable_instance_ids -> peers.
    # These examples deliberately go through seed_provisioned_mission (the
    # production writer path) rather than stubbing the instance set, because
    # the whole attribution claim is that the peers reached are exactly the
    # peers of the instances THIS mission provisioned.
    # ---------------------------------------------------------------------
    describe "sdwan_throughput_bytes_per_s" do
      let(:metric) { described_class::THROUGHPUT_METRIC }

      def throughput_row(mission)
        System::ProjectMetric.where(mission_id: mission.id, metric_name: metric)
                             .order(sampled_at: :desc, id: :desc).first
      end

      def measure!(peer, rx:, tx:, at:)
        peer.update_columns(rx_bytes: rx, tx_bytes: tx, counters_sampled_at: at)
      end

      def peer_on(instance)
        create(:sdwan_peer, account: account,
               network: create(:sdwan_network, account: account),
               node_instance: instance)
      end

      it "reports unavailable (observed nil) when the mission has no resolvable instances" do
        mission = build_active_infrastructure_mission
        described_class.collect!(mission: mission)

        expect(throughput_row(mission).value).to include("observed" => nil, "source" => "unavailable")
      end

      it "reports unavailable when the mission's instances carry no SDWAN peers" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        mission, = seed_provisioned_mission([ inst.id ])

        described_class.collect!(mission: mission)

        row = throughput_row(mission)
        expect(row.value["observed"]).to be_nil
        expect(row.value["peer_count"]).to be_nil
      end

      # NOT MEASURED vs MEASURED-ZERO, at the collector boundary. A peer that
      # has never reported carries three NULLs; counting it as a zero-byte
      # contributor would report an unobserved tunnel as an idle one.
      it "reports unavailable when the mission's peers have never reported counters" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        peer_on(inst)
        mission, = seed_provisioned_mission([ inst.id ])

        described_class.collect!(mission: mission)

        row = throughput_row(mission)
        expect(row.value["observed"]).to be_nil
        expect(row.value["source"]).to eq("unavailable")
        # The peer is COUNTED (it is part of the fabric) but not RATED.
        expect(row.value["peer_count"]).to eq(1)
        expect(row.value["rated_peer_count"]).to eq(0)
        # ...and nothing was banked, because nothing was observed.
        expect(row.value[described_class::PEER_COUNTERS_KEY]).to be_nil
      end

      it "reports unavailable on the FIRST measured tick — one cumulative sample is not a rate" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        measure!(peer_on(inst), rx: 1_000, tx: 2_000, at: Time.current)
        mission, = seed_provisioned_mission([ inst.id ])

        described_class.collect!(mission: mission)

        row = throughput_row(mission)
        expect(row.value["observed"]).to be_nil
        expect(row.value["source"]).to eq("unavailable")
        # ...but it banked the baseline, which is what makes tick 2 measurable.
        expect(row.value[described_class::PEER_COUNTERS_KEY].keys.size).to eq(1)
      end

      it "computes bytes/s from two observations of the same peer" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        peer = peer_on(inst)
        t0   = Time.current - 60
        measure!(peer, rx: 1_000, tx: 2_000, at: t0)
        mission, = seed_provisioned_mission([ inst.id ])
        described_class.collect!(mission: mission)

        # +3000 rx, +3000 tx over 60s -> 100 bytes/s
        measure!(peer, rx: 4_000, tx: 5_000, at: t0 + 60)
        described_class.collect!(mission: mission)

        row = throughput_row(mission)
        expect(row.value["source"]).to eq("live")
        expect(row.value["observed"]).to be_within(0.01).of(100.0)
        expect(row.metric_type).to eq("utilization")
        expect(row.value["unit"]).to eq("bytes_per_s")
      end

      # MEASURED AND IDLE. This is the example that separates this metric from
      # a gauge: an up-but-silent tunnel really does report the same cumulative
      # counter twice, and that is a REAL 0.0 — the exact reading a throughput
      # floor exists to fire on. It must not be turned into `unavailable`.
      it "reports a REAL 0.0 for a peer that was up and moved nothing" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        peer = peer_on(inst)
        t0   = Time.current - 60
        measure!(peer, rx: 7_000, tx: 7_000, at: t0)
        mission, = seed_provisioned_mission([ inst.id ])
        described_class.collect!(mission: mission)

        measure!(peer, rx: 7_000, tx: 7_000, at: t0 + 60)
        described_class.collect!(mission: mission)

        row = throughput_row(mission)
        expect(row.value["source"]).to eq("live")
        expect(row.value["observed"]).to eq(0.0)
      end

      # RESET SEMANTICS. WireGuard restarts the counter at zero when the
      # interface is recreated, so newer < older is a reset and the interval's
      # traffic is `newer` itself. Differencing would go negative; clamping to
      # zero would lose the traffic; a monotonic guard would pin the peer at
      # its pre-reset high-water mark forever.
      it "treats a counter that went BACKWARDS as a reset and counts the newer value" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        peer = peer_on(inst)
        t0   = Time.current - 60
        measure!(peer, rx: 900_000, tx: 900_000, at: t0)
        mission, = seed_provisioned_mission([ inst.id ])
        described_class.collect!(mission: mission)

        # interface recreated: counters restart, 1200 + 1800 bytes since
        measure!(peer, rx: 1_200, tx: 1_800, at: t0 + 60)
        described_class.collect!(mission: mission)

        row = throughput_row(mission)
        expect(row.value["source"]).to eq("live")
        expect(row.value["observed"]).to be_within(0.01).of(50.0) # (1200+1800)/60
      end

      # A stalled agent freezes counters_sampled_at, so the tick sees the same
      # observation twice with zero elapsed. That peer is UNOBSERVED over the
      # interval, not quiet — it must contribute nothing rather than a 0.0.
      it "excludes a peer whose observation clock did not advance" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        peer = peer_on(inst)
        t0   = Time.current - 60
        measure!(peer, rx: 5_000, tx: 5_000, at: t0)
        mission, = seed_provisioned_mission([ inst.id ])
        described_class.collect!(mission: mission)

        described_class.collect!(mission: mission) # nothing changed at all

        row = throughput_row(mission)
        expect(row.value["observed"]).to be_nil
        expect(row.value["source"]).to eq("unavailable")
        expect(row.value["rated_peer_count"]).to eq(0)
      end

      it "sums per-peer rates across the mission's peers" do
        node  = create(:system_node, account: account)
        inst_a = create(:system_node_instance, :running, node: node)
        inst_b = create(:system_node_instance, :running, node: node)
        peer_a = peer_on(inst_a)
        peer_b = peer_on(inst_b)
        t0 = Time.current - 60
        measure!(peer_a, rx: 0, tx: 0, at: t0)
        measure!(peer_b, rx: 0, tx: 0, at: t0)
        mission, = seed_provisioned_mission([ inst_a.id, inst_b.id ])
        described_class.collect!(mission: mission)

        measure!(peer_a, rx: 600, tx: 0,   at: t0 + 60) # 10 B/s
        measure!(peer_b, rx: 0,   tx: 1_200, at: t0 + 60) # 20 B/s
        described_class.collect!(mission: mission)

        row = throughput_row(mission)
        expect(row.value["observed"]).to be_within(0.01).of(30.0)
        expect(row.value["rated_peer_count"]).to eq(2)
        expect(row.value["peer_count"]).to eq(2)
      end

      # ============================================================
      # THE AGGREGATE'S OWN NULL-VS-ZERO RULE.
      #
      # Per-peer discipline is not enough. A sum over whichever peers happened
      # to be ratable, published as `live`, is a fabricated zero one level up:
      # the unrated peers contribute nothing to the numerator while the FLOOR
      # is declared against the whole fabric. An incomplete sum can only
      # understate, and a floor fires on `observed < target`, so partial
      # coverage can only ever FABRICATE a breach.
      # ============================================================
      describe "coverage gate" do
        def two_peer_mission(t0)
          node   = create(:system_node, account: account)
          inst_a = create(:system_node_instance, :running, node: node)
          inst_b = create(:system_node_instance, :running, node: node)
          [ peer_on(inst_a), peer_on(inst_b), seed_provisioned_mission([ inst_a.id, inst_b.id ]).first ]
        end

        it "refuses to publish a partial sum as a live observation" do
          t0 = Time.current - 60
          rated, stalled, mission = two_peer_mission(t0)
          measure!(rated,   rx: 0, tx: 0, at: t0)
          measure!(stalled, rx: 0, tx: 0, at: t0)
          described_class.collect!(mission: mission)

          measure!(rated, rx: 600, tx: 0, at: t0 + 60) # 10 B/s
          # `stalled` keeps its frozen clock — unobserved over this interval
          described_class.collect!(mission: mission)

          row = throughput_row(mission)
          expect(row.value["observed"]).to be_nil,
            "a sum covering 1 of 2 peers must not be published as this mission's throughput"
          expect(row.value["source"]).to eq("unavailable")
          expect(row.value["rated_peer_count"]).to eq(1)
          expect(row.value["peer_count"]).to eq(2)
          expect(row.value["note"]).to include("partial coverage")
        end

        # A peer that has NEVER reported is not in the measured set at all, so
        # it cannot be caught by comparing rates against the measured set —
        # the denominator has to be the mission's WHOLE fabric.
        it "counts a never-reporting peer against coverage" do
          t0 = Time.current - 60
          rated, silent, mission = two_peer_mission(t0)
          measure!(rated, rx: 0, tx: 0, at: t0)
          described_class.collect!(mission: mission)

          measure!(rated, rx: 600, tx: 0, at: t0 + 60)
          expect(silent.reload.rx_bytes).to be_nil # never heard from
          described_class.collect!(mission: mission)

          row = throughput_row(mission)
          expect(row.value["observed"]).to be_nil
          expect(row.value["peer_count"]).to eq(2)
          expect(row.value["rated_peer_count"]).to eq(1)
        end

        # The three counter columns are independently nullable, so "has a
        # stamp" does NOT imply "has counters". Defaulting the byte columns
        # would hand this peer a real elapsed interval and a fabricated 0-byte
        # delta — full apparent coverage over a peer that never reported.
        it "counts a peer with a fresh stamp but NULL byte counters against coverage" do
          t0 = Time.current - 60
          rated, half, mission = two_peer_mission(t0)
          measure!(rated, rx: 0, tx: 0, at: t0)
          half.update_columns(rx_bytes: nil, tx_bytes: nil, counters_sampled_at: t0)
          described_class.collect!(mission: mission)

          measure!(rated, rx: 600, tx: 0, at: t0 + 60)
          half.update_columns(rx_bytes: nil, tx_bytes: nil, counters_sampled_at: t0 + 60)
          described_class.collect!(mission: mission)

          row = throughput_row(mission)
          expect(row.value["observed"]).to be_nil
          expect(row.value["peer_count"]).to eq(2)
          expect(row.value["rated_peer_count"]).to eq(1)
        end

        # The positive control for the three above: the SAME two-peer fabric
        # publishes a live sum the moment coverage is complete. Without this,
        # a collector that never published anything would pass them all.
        it "publishes live the moment every peer is rated" do
          t0 = Time.current - 60
          a, b, mission = two_peer_mission(t0)
          measure!(a, rx: 0, tx: 0, at: t0)
          measure!(b, rx: 0, tx: 0, at: t0)
          described_class.collect!(mission: mission)

          measure!(a, rx: 600, tx: 0, at: t0 + 60)
          measure!(b, rx: 600, tx: 0, at: t0 + 60)
          described_class.collect!(mission: mission)

          row = throughput_row(mission)
          expect(row.value["source"]).to eq("live")
          expect(row.value["observed"]).to be_within(0.01).of(20.0)
        end
      end

      # The attribution boundary, asserted rather than assumed: a peer on an
      # instance this mission did NOT provision must not appear in its number
      # — nor in its coverage denominator.
      it "ignores peers on instances the mission did not provision" do
        node  = create(:system_node, account: account)
        mine  = create(:system_node_instance, :running, node: node)
        other = create(:system_node_instance, :running, node: node)
        peer_mine  = peer_on(mine)
        peer_other = peer_on(other)
        t0 = Time.current - 60
        measure!(peer_mine,  rx: 0, tx: 0, at: t0)
        measure!(peer_other, rx: 0, tx: 0, at: t0)
        mission, = seed_provisioned_mission([ mine.id ])
        described_class.collect!(mission: mission)

        measure!(peer_mine,  rx: 600,     tx: 0, at: t0 + 60)   # 10 B/s
        measure!(peer_other, rx: 600_000, tx: 0, at: t0 + 60)   # not ours
        described_class.collect!(mission: mission)

        row = throughput_row(mission)
        expect(row.value["observed"]).to be_within(0.01).of(10.0)
        expect(row.value["peer_count"]).to eq(1)
      end

      it "does not aggregate another account's peer even on a matching instance id" do
        other_account = create(:account)
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        foreign = create(:sdwan_peer, account: other_account,
                         network: create(:sdwan_network, account: other_account),
                         node_instance: inst)
        t0 = Time.current - 60
        measure!(foreign, rx: 0, tx: 0, at: t0)
        mission, = seed_provisioned_mission([ inst.id ])
        described_class.collect!(mission: mission)

        measure!(foreign, rx: 600_000, tx: 0, at: t0 + 60)
        described_class.collect!(mission: mission)

        row = throughput_row(mission)
        expect(row.value["observed"]).to be_nil
        expect(row.value["peer_count"]).to be_nil
      end

      # The peer snapshot is computation state, not history. Only the newest
      # row may carry it, or a 60s-cadence collector grows the table by
      # peer_count x 1440 map entries per mission per day, forever.
      it "keeps the peer counter snapshot on exactly one row" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        peer = peer_on(inst)
        t0 = Time.current - 120
        mission, = seed_provisioned_mission([ inst.id ])

        3.times do |i|
          measure!(peer, rx: 1_000 * (i + 1), tx: 0, at: t0 + (60 * i))
          described_class.collect!(mission: mission)
        end

        rows = System::ProjectMetric.where(mission_id: mission.id, metric_name: metric)
        carriers = rows.select { |r| r.value.key?(described_class::PEER_COUNTERS_KEY) }
        expect(carriers.size).to eq(1)
        expect(carriers.first.id).to eq(throughput_row(mission).id)
        # the measurements themselves survive the prune
        expect(rows.count).to eq(3)
      end

      # A tick with nothing to measure writes NO snapshot. If the prune ran
      # anyway, or if the baseline lookup keyed off "most recent row" instead
      # of "most recent row carrying a snapshot", the standing baseline would
      # be stranded on an older row — never read again, never pruned again —
      # and the metric would stay dark for an extra tick after the fabric
      # came back.
      it "survives a tick that measures nothing without losing or orphaning the baseline" do
        inst = create(:system_node_instance, :running, node: create(:system_node, account: account))
        peer = peer_on(inst)
        t0 = Time.current - 180
        mission, = seed_provisioned_mission([ inst.id ])

        measure!(peer, rx: 1_000, tx: 0, at: t0)
        described_class.collect!(mission: mission) # banks the baseline

        peer.update_columns(rx_bytes: nil, tx_bytes: nil, counters_sampled_at: nil) # fabric goes dark
        described_class.collect!(mission: mission)

        measure!(peer, rx: 7_000, tx: 0, at: t0 + 120) # 6000 bytes over 120s
        described_class.collect!(mission: mission)

        row = throughput_row(mission)
        expect(row.value["source"]).to eq("live"),
          "the baseline banked before the gap must still be reachable after it"
        expect(row.value["observed"]).to be_within(0.01).of(50.0)

        carriers = System::ProjectMetric.where(mission_id: mission.id, metric_name: metric)
                                        .select { |r| r.value.key?(described_class::PEER_COUNTERS_KEY) }
        expect(carriers.size).to eq(1), "a gap tick must not orphan a snapshot"
      end
    end
  end
end
