# frozen_string_literal: true

require "rails_helper"

# IMP-25e75f960dee — the per-peer WireGuard byte counters IMP-ab73cc2fca65
# landed were measured by `wg`, carried on the wire, persisted with nullable
# columns plus their own `counters_sampled_at`, and published on four
# caller-facing surfaces — and then reached NOTHING. No sensor read them, and
# System::ProjectMetric::KNOWN_METRIC_NAMES had no slot to put them in.
#
# The failure mode this file exists to prevent is a HALF-LANDED chain: offer
# 01a02bfb-84bd is the precedent, where ProjectSloSensor maps 5 of the 7
# metric names so cpu_pct/memory_pct land dark however well they are produced.
# Each unit spec covers one link:
#
#   spec/models/sdwan/peer_spec.rb                       .counter_delta rules
#   spec/services/system/project_metrics_collector_spec  peers -> ProjectMetric
#   .../sensors/project_slo_sensor_spec.rb               ProjectMetric -> signal
#
# ...and every one of them can be green while the chain is broken, because a
# link is only real if the NEXT one consumes it. This spec runs the whole
# thing, from a `wg`-shaped counter write on a peer row through to a decision
# returned by DecisionEngine, with nothing between the links stubbed.
#
# The live chain (cron `* * * * *` -> SystemFleetReconcileJob ->
# worker_api/fleet/reconcile -> FleetAutonomyService.tick!) is the same one
# collect_project_metrics! and collect_signals run inside; this spec enters at
# collect!/sense/decide so the assertions name the link, not the tick.
RSpec.describe "SDWAN peer counters -> fleet autonomy chain (IMP-25e75f960dee)" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }
  let(:agent)   { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service) { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)  { System::Fleet::DecisionEngine.new(autonomy_service: service) }

  let(:metric) { System::ProjectMetricsCollector::THROUGHPUT_METRIC }

  # mission -> Ai::GoalPlan -> completed provisioning step whose recorded
  # outputs name the NodeInstance ids. This is the production writer path
  # (SkillCompositionRunner#result_outputs + #mark_completed) and the exact
  # derivation System::ProjectMetricsCollector#resolvable_instance_ids reads —
  # the attribution this increment reuses rather than inventing.
  def provisioned_mission(instance_ids, slo_targets:)
    goal = Ai::AgentGoal.create!(
      account: account, agent: agent, title: "provision",
      goal_type: "creation", status: "active", priority: 3, progress: 0.0
    )
    plan = Ai::GoalPlan.create!(
      account: account, goal: goal, agent: agent, status: "approved", version: 1
    )
    mission = create(
      :ai_mission, account: account, created_by: user, mission_type: "infrastructure",
      custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ],
      configuration: { "plan" => { "plan_id" => plan.id }, "slo_targets" => slo_targets }
    )
    mission.update_columns(status: "active")

    step = plan.steps.create!(step_number: 1, status: "pending", step_type: "provisioning_skill")
    result = { success: true, data: { outputs: { node_instance_ids: instance_ids } } }
    runner = ::Ai::Provisioning::SkillCompositionRunner.new(account: account, mission: mission, plan: plan)
    runner.send(:mark_completed, step, runner.send(:result_outputs, result))

    mission
  end

  def peer_on(instance)
    create(:sdwan_peer, account: account,
           network: create(:sdwan_network, account: account),
           node_instance: instance)
  end

  # The shape the node_api SDWAN status endpoint writes on a heartbeat:
  # update_columns (so updated_at is deliberately untouched), raw cumulative
  # counters, and the observation's own stamp.
  def heartbeat!(peer, rx:, tx:, at:)
    peer.update_columns(rx_bytes: rx, tx_bytes: tx, counters_sampled_at: at)
  end

  let(:instance) { create(:system_node_instance, :running, node: create(:system_node, account: account)) }
  let(:peer)     { peer_on(instance) }

  describe "a starved fabric reaches DecisionEngine" do
    let(:t0) { Time.current - 120 }

    # 60 bytes over 60s = 1 B/s against a declared floor of 1000 B/s.
    let!(:mission) do
      m = provisioned_mission([ instance.id ], slo_targets: { "min_throughput_bytes_per_s" => 1_000 })
      heartbeat!(peer, rx: 10_000, tx: 10_000, at: t0)
      System::ProjectMetricsCollector.collect!(mission: m)
      heartbeat!(peer, rx: 10_030, tx: 10_030, at: t0 + 60)
      System::ProjectMetricsCollector.collect!(mission: m)
      m
    end

    # LINK 1 — peers -> System::ProjectMetric. Executed: the row is read back
    # from the table, not from the collector's return value.
    it "LINK 1: the collector persists a live sample derived from the peer's counters" do
      row = System::ProjectMetric.where(mission_id: mission.id, metric_name: metric)
                                 .order(sampled_at: :desc, id: :desc).first

      expect(row).not_to be_nil
      expect(row.value["source"]).to eq("live")
      expect(row.observed).to be_within(0.01).of(1.0)
      expect(row.metric_type).to eq("utilization")
    end

    # LINK 2 — System::ProjectMetric -> signal. Executed through the real
    # sensor against the real rows; nothing injects an observation.
    it "LINK 2: ProjectSloSensor turns that row into a system.project_slo_violation" do
      signal = System::Fleet::Sensors::ProjectSloSensor.new(account: account).sense
                                                       .find { |s| s.kind == "system.project_slo_violation" }

      expect(signal).not_to be_nil
      expect(signal.payload["metric"]).to eq(metric)
      expect(signal.payload["observed"]).to be_within(0.01).of(1.0)
      expect(signal.payload["target"]).to eq(1_000.0)
      expect(signal.payload["mission_id"]).to eq(mission.id)
    end

    # LINK 3 — signal -> DecisionEngine. The discriminator that matters is
    # `:skipped`: that is decide()'s "no binding for kind" arm, i.e. the signal
    # falling off the end of the lane. A decision carrying action_category
    # "project.adapt" proves SIGNAL_BINDINGS resolved OUR signal. With no
    # intervention policy seeded the gate blocks it (not_permitted) — which is
    # the correct default posture and still proves the routing.
    it "LINK 3: DecisionEngine routes the signal to the project.adapt category" do
      signal = System::Fleet::Sensors::ProjectSloSensor.new(account: account).sense
                                                       .find { |s| s.kind == "system.project_slo_violation" }

      decision = engine.decide(signal)

      expect(decision[:decision]).not_to eq(:skipped)
      expect(decision[:action_category]).to eq("project.adapt")
      expect(decision[:signal_kind]).to eq("system.project_slo_violation")
      expect(decision[:fingerprint]).to eq("project_slo_violation:#{mission.id}:#{metric}")
    end

    # LINK 4 — DecisionEngine -> REMEDIATION_APPLIERS. With a permitting
    # policy the gate proceeds and apply_remediation! invokes the project
    # adaptation applier FOR THIS SIGNAL. The proposer itself is stubbed to
    # decline (it composes GoalPlan versions and is not what is under test);
    # the assertion is that the applier ran and received our mission.
    it "LINK 4: a permitted decision invokes the project adaptation applier" do
      Ai::InterventionPolicy.create!(
        account: account, action_category: "project.adapt", scope: "agent",
        ai_agent_id: agent.id, policy: "notify_and_proceed", priority: 5, is_active: true
      )
      proposer = instance_double(Ai::Provisioning::AdaptationProposerService, propose_from_signals: nil)
      allow(Ai::Provisioning::AdaptationProposerService).to receive(:new).and_return(proposer)

      signal = System::Fleet::Sensors::ProjectSloSensor.new(account: account).sense
                                                       .find { |s| s.kind == "system.project_slo_violation" }
      decision = engine.decide(signal)

      expect(decision[:decision]).to eq(:proceed)
      expect(Ai::Provisioning::AdaptationProposerService)
        .to have_received(:new).with(hash_including(mission: mission))
      expect(proposer).to have_received(:propose_from_signals).with(signals: [ signal ])
      expect(decision[:remediation]).to include(proposal: true, mission_id: mission.id)
    end
  end

  # THE ORACLE THAT MAKES THE REST WORTH ANYTHING. Zero is a legitimate
  # measurement for a counter — an idle peer really does move zero bytes — so
  # a chain that cannot tell "not measured" from "measured and idle" fires
  # critical breaches on fabrics it never observed. NULL must stay NULL for the
  # whole length of the chain, and the proof has to be end to end because each
  # link defaults separately (the producer's own mutation testing found four
  # surfaces each coercing on its own).
  describe "an UNMEASURED peer never reaches DecisionEngine" do
    it "stays dark from the peer row all the way to the decision" do
      mission = provisioned_mission([ instance.id ], slo_targets: { "min_throughput_bytes_per_s" => 1_000 })
      peer # created, never heard from: rx_bytes/tx_bytes/counters_sampled_at all NULL

      2.times { System::ProjectMetricsCollector.collect!(mission: mission) }

      row = System::ProjectMetric.where(mission_id: mission.id, metric_name: metric)
                                 .order(sampled_at: :desc, id: :desc).first
      expect(row.observed).to be_nil, "an unmeasured peer must not produce an observation"
      expect(row.value["source"]).to eq("unavailable")

      signals = System::Fleet::Sensors::ProjectSloSensor.new(account: account).sense
      expect(signals.select { |s| s.kind == "system.project_slo_violation" }).to be_empty

      decisions = engine.decide_all(signals)
      expect(decisions.map { |d| d[:signal_kind] }).not_to include("system.project_slo_violation")
    end

    # The counterpart, and the whole reason the columns are nullable: a peer
    # that WAS measured and moved nothing is a real breach and must reach the
    # engine. Same fixture, same floor — only the measurement differs.
    it "but a peer measured at zero traffic DOES reach the decision" do
      t0 = Time.current - 120
      mission = provisioned_mission([ instance.id ], slo_targets: { "min_throughput_bytes_per_s" => 1_000 })
      heartbeat!(peer, rx: 4_096, tx: 4_096, at: t0)
      System::ProjectMetricsCollector.collect!(mission: mission)
      heartbeat!(peer, rx: 4_096, tx: 4_096, at: t0 + 60) # up, idle, same totals
      System::ProjectMetricsCollector.collect!(mission: mission)

      row = System::ProjectMetric.where(mission_id: mission.id, metric_name: metric)
                                 .order(sampled_at: :desc, id: :desc).first
      expect(row.observed).to eq(0.0)
      expect(row.value["source"]).to eq("live")

      signals = System::Fleet::Sensors::ProjectSloSensor.new(account: account).sense
      decisions = engine.decide_all(signals)

      breach = decisions.find { |d| d[:signal_kind] == "system.project_slo_violation" }
      expect(breach).not_to be_nil
      expect(breach[:action_category]).to eq("project.adapt")
    end
  end
end
