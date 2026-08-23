# frozen_string_literal: true

require "rails_helper"

# IMP-02b4bc9f8bd8 (INC-3) — cross-boundary contract spec.
#
# `Ai::Provisioning::AdaptationProposerService` (CORE) composes a
# `scale_project` step; `System::Ai::Skills::ScaleProjectExecutor` (this
# extension) is the actuator that step names. Core may not reference the
# executor, so nothing in core can prove the composition is well-formed
# against it — that proof belongs here, on the extension side of the seam.
#
# What this asserts (ground truth, never a returned :success flag):
#
#   1. The composed step's inputs BIND to the executor: every descriptor
#      input marked required and every required keyword of #perform is
#      present, so neither #validate_inputs! nor the keyword binding raises.
#   2. `target_count` is honoured as the DELTA the executor documents
#      ("number of new instances"), not an absolute replica count — the
#      executor's own reported count must equal the gap being closed.
#   3. A composed scale-out carries `network_id` and `with_storage_gb` all
#      the way into the underlying provisioning primitive's plan, which is
#      the precondition for `sdwan_peer_ids` / `storage_volume_ids` ever
#      appearing in the outputs envelope.
RSpec.describe "AdaptationProposer → ScaleProjectExecutor contract", type: :integration do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:ai_provider) { create(:ai_provider, account: account, is_active: true) }
  let!(:agent) do
    create(:ai_agent, account: account, provider: ai_provider, creator: user, status: "active")
  end

  # Real substrate records so the executor's lookups resolve for real.
  let(:template) { create(:system_node_template, account: account) }
  let(:region) { create(:system_provider_region, account: account) }
  let(:instance_type) { create(:system_provider_instance_type, account: account) }
  let(:network) { create(:sdwan_network, account: account) }

  let(:brief) do
    {
      "intent" => "small web stack",
      "scale" => { "initial" => 2, "target" => 4, "growth_profile" => "linear" },
      "regions" => %w[us-east-1],
      "budget_cap_usd_monthly" => 200.0
    }
  end

  # The mission's original provisioning plan — the authoritative record of
  # the footprint a scale-out must replicate.
  let(:mission) do
    goal = Ai::AgentGoal.create!(
      account: account, agent: agent,
      title: "Provision", description: "initial provisioning",
      goal_type: "improvement", status: "pending", priority: 3, progress: 0.0,
      success_criteria: {}, metadata: {}
    )
    plan = Ai::GoalPlan.create!(
      account: account, goal: goal, agent: agent,
      status: "draft", version: 1, plan_data: { "kind" => "provisioning" }
    )
    plan.steps.create!(
      step_number: 1, step_type: "provisioning_skill", status: "pending",
      description: "Provision full stack",
      execution_config: {
        "skill" => "provision_full_stack",
        "inputs" => {
          "template_id" => template.id,
          "provider_region_id" => region.id,
          "provider_instance_type_id" => instance_type.id,
          "network_id" => network.id,
          "with_storage_gb" => 50
        },
        "on_failure" => "rollback"
      },
      dependencies: []
    )

    m = create(
      :ai_mission,
      account: account, created_by: user, mission_type: "infrastructure",
      custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ],
      configuration: {
        "brief" => brief,
        "slo_targets" => { "availability_pct" => 99.5, "p99_latency_ms" => 250,
                           "cost_ceiling_usd" => 200.0 },
        "watch_policies" => { "auto_scale_max_replicas" => 8 },
        "plan" => { "plan_id" => plan.id }
      }
    )
    m.update_columns(status: "active")
    m.reload
  end

  # observed 1, target 2 → the composer must close a gap of exactly 1.
  let(:drift) do
    double(
      "Signal",
      kind: "system.project_drift",
      severity: :medium,
      payload: {
        "mission_id" => mission.id,
        "drift_type" => "replica_count",
        "observed" => 1,
        "target" => 2,
        "correlation_id" => "project_slo:#{mission.id}:contract"
      },
      fingerprint: "project_drift:#{mission.id}:replica_count"
    )
  end

  # The composed step's inputs, exactly as the runner would hand them over
  # (`executor.execute(**symbolize(inputs))`).
  let(:composed_inputs) do
    allow_any_instance_of(Ai::Provisioning::AdaptationProposerService)
      .to receive(:diff_from_llm).and_return(nil)

    plan = Ai::Provisioning::AdaptationProposerService
      .new(account: account, mission: mission)
      .propose_from_signals(signals: [ drift ])

    raise "composer produced no plan — the contract cannot be checked" if plan.nil?

    plan.steps.in_order.first.execution_config.deep_stringify_keys["inputs"]
      .symbolize_keys
  end

  let(:executor_class) { System::Ai::Skills::ScaleProjectExecutor }

  # The SLO path has no replica count in its own `observed` field — that is
  # the breached metric. ProjectSloSensor therefore stamps `replica_count`
  # onto the SLO payload, and the proposer reads ONLY that. This keeps one
  # reader of the telemetry: core never queries metrics itself (which would
  # make core depend on this extension), and the sensor and the proposer
  # cannot disagree about the fleet within a single tick.
  describe "SLO baseline arrives on the signal the sensor emits" do
    # The collector writes a ROW PER METRIC, and the sensor prefers the DB
    # wholesale once any row exists — so a breach seeded here must seed the
    # latency row too, exactly as a real tick would.
    def seed_live_metrics!(replica_count:, p99: 500.0)
      System::ProjectMetric.create!(
        mission: mission, metric_name: "p99_latency_ms", metric_type: "latency",
        sampled_at: Time.current, value: { "observed" => p99 }
      )
      System::ProjectMetric.create!(
        mission: mission, metric_name: "replica_count", metric_type: "capacity",
        sampled_at: Time.current, value: { "observed" => replica_count }
      )
    end

    def sensed_slo_signal
      System::Fleet::Sensors::ProjectSloSensor.new(account: account)
                                              .sense
                                              .find { |sig| sig.kind == "system.project_slo_violation" }
    end

    before do
      allow_any_instance_of(Ai::Provisioning::AdaptationProposerService)
        .to receive(:diff_from_llm).and_return(nil)
      # Breach p99 so the sensor emits an SLO violation at all.
      mission.update!(configuration: mission.configuration.merge(
        "latest_observations" => { "p99_latency_ms" => 500.0, "availability_pct" => 99.9 }
      ))
    end

    it "carries the observed replica count onto the SLO payload" do
      seed_live_metrics!(replica_count: 6)

      signal = sensed_slo_signal
      expect(signal).not_to be_nil
      expect(signal.payload["metric"]).to eq("p99_latency_ms")
      # The fleet size rides alongside the breached metric.
      expect(signal.payload["replica_count"]).to eq(6)
    end

    it "steps the composition up from the count the sensor observed" do
      seed_live_metrics!(replica_count: 6)

      plan = Ai::Provisioning::AdaptationProposerService
        .new(account: account, mission: mission.reload)
        .propose_from_signals(signals: [ sensed_slo_signal ])

      inputs = plan.steps.in_order.first.execution_config.deep_stringify_keys["inputs"]
      # breach 100 → +2 off the LIVE 6 → 8. Off brief.scale.initial (2) it
      # would be a constant 4 no matter how large the fleet had grown.
      expect(inputs["desired_replica_count"]).to eq(8)
      expect(inputs["target_count"]).to eq(2)
    end

    it "DECLINES when the fleet is unobservable rather than falling back to the brief" do
      # No replica_count metric at all → the sensor reports nil → the
      # proposer must decline. Substituting the brief here would restore the
      # constant baseline (and with it the auto-apply ratchet), because
      # `auto_apply?` gates on exactly this number.
      signal = sensed_slo_signal
      expect(signal).not_to be_nil
      expect(signal.payload["replica_count"]).to be_nil

      expect(
        Ai::Provisioning::AdaptationProposerService
          .new(account: account, mission: mission.reload)
          .propose_from_signals(signals: [ signal ])
      ).to be_nil
    end
  end

  # The SCALE-IN half of the same seam (IMP-e68a93c47106). Core's own specs can
  # only check the composed step against SCALE_PROJECT_REQUIRED_INPUTS — core's
  # RESTATEMENT of the contract. This checks it against the contract, and it is
  # the only place the removal's `target_count` semantic ("a count to REMOVE",
  # the opposite direction from the additive arm above) is pinned to the
  # actuator that honours it.
  describe "a composed cost_control step actuates as a REMOVAL" do
    let(:prefix) { "contract-costctl" }

    let(:cost_breach) do
      double(
        "Signal",
        kind: "system.project_cost_breach",
        severity: :medium,
        payload: {
          "mission_id" => mission.id,
          "observed_usd" => 280.0,
          "target_usd" => 200.0,
          "breach_pct" => 40.0,
          "correlation_id" => "project_slo:#{mission.id}:contract-cost"
        },
        fingerprint: "project_cost_breach:#{mission.id}"
      )
    end

    let(:composed_removal_inputs) do
      allow_any_instance_of(Ai::Provisioning::AdaptationProposerService)
        .to receive(:diff_from_llm).and_return(nil)

      plan = Ai::Provisioning::AdaptationProposerService
        .new(account: account, mission: mission)
        .propose_from_signals(signals: [ cost_breach ])

      raise "composer produced no scale-in plan — the contract cannot be checked" if plan.nil?

      plan.steps.in_order.first.execution_config.deep_stringify_keys["inputs"]
        .symbolize_keys
    end

    # The production naming chain ProvisionFullStackExecutor#create_node!
    # stamps: mission provenance in node.config plus a prefixed node name the
    # instance name derives from. Both containment rails read one of those.
    def replica!(minutes_old:)
      node = create(:system_node, account: account, node_template: template,
                                  name: "#{prefix}-web-#{SecureRandom.hex(3)}",
                                  config: { "mission_id" => mission.id })
      create(:system_node_instance, :running, node: node,
             provider_region: region, provider_instance_type: instance_type,
             name: "#{node.name}-instance-#{SecureRandom.hex(2)}",
             created_at: minutes_old.minutes.ago)
    end

    before do
      mission.update!(configuration: mission.configuration.merge("name_prefix" => prefix))
    end

    it "names the removal strategy the executor advertises" do
      # Core holds the strategy as a plain string behind the skill seam; only
      # this side can check it against the executor's own list.
      expect(executor_class::STRATEGIES)
        .to include(Ai::Provisioning::AdaptationProposerService::REMOVAL_STRATEGY)
    end

    it "composes a target_count inside the executor's accepted bound" do
      # The executor hard-rejects anything outside 1..MAX_DELTA. Core does not
      # clamp the removal ladder — it relies on both rungs being small — so if
      # that ever stops being true, this is what notices.
      count = composed_removal_inputs[:target_count]
      expect(count).to be_between(1, executor_class::MAX_DELTA)
    end

    it "binds to #perform without an ArgumentError" do
      required_kwargs = executor_class.instance_method(:perform).parameters
        .filter_map { |type, name| name if type == :keyreq }

      missing = required_kwargs.reject { |k| composed_removal_inputs.key?(k) }
      expect(missing).to be_empty,
                         "composed removal misses required keywords: #{missing.inspect}"

      replica!(minutes_old: 30)
      replica!(minutes_old: 5)

      expect {
        executor_class.new(account: account)
          .send(:perform, **composed_removal_inputs.merge(dry_run: true))
      }.not_to raise_error
    end

    it "treats target_count as a count to REMOVE, not a target to reach" do
      # Three live replicas, a composed target_count of 1 (breach_pct 40 is
      # below the severe rung). If the executor read it as an absolute target
      # it would plan to remove TWO — the opposite-direction version of the
      # delta/absolute confusion the additive arm above pins.
      3.times { |i| replica!(minutes_old: (i + 1) * 10) }
      expect(composed_removal_inputs[:target_count]).to eq(1)

      result = executor_class.new(account: account)
        .execute(**composed_removal_inputs.merge(dry_run: true))

      expect(result[:error]).to be_nil
      expect(result[:data][:scaling_strategy])
        .to eq(Ai::Provisioning::AdaptationProposerService::REMOVAL_STRATEGY)
      expect(result[:data][:count]).to eq(1)
    end

    it "cannot empty the fleet — the executor floors the composed removal" do
      # Core composes blind (the cost-breach payload carries no replica count),
      # so the ONLY thing standing between a composed removal and a scaled-to-
      # zero mission is the executor's own floor. Prove it holds against a
      # composed step rather than a hand-built one.
      replica!(minutes_old: 10)

      result = executor_class.new(account: account)
        .execute(**composed_removal_inputs.merge(dry_run: true))

      expect(result[:error]).to be_nil
      expect(result[:data][:count]).to eq(0)
      expect(result.dig(:data, :outputs, :floor_reached)).to be true
    end
  end

  it "keeps the composer's per-step ceiling within the executor's own bound" do
    # Core cannot reference the executor, so it mirrors this bound as a
    # documented constant. Nothing but this assertion notices if the two
    # drift apart — and if the composer's ceiling ever exceeds the
    # executor's, every clamped step composes a delta the actuator refuses.
    expect(Ai::Provisioning::AdaptationProposerService::DEFAULT_MAX_SCALE_OUT_DELTA)
      .to be <= executor_class::MAX_DELTA
  end

  it "mirrors the executor's required-input list exactly" do
    # Core cannot read the descriptor across the skill seam, so it mirrors
    # this list to guard every composed scale_project step. If the executor
    # adds a required input and this list is not updated, core would keep
    # composing steps that no longer bind — nothing but this notices.
    declared = executor_class.descriptor[:inputs]
      .select { |_k, spec| spec.is_a?(Hash) && spec[:required] }
      .keys
      .map(&:to_s)

    expect(Ai::Provisioning::AdaptationProposerService::SCALE_PROJECT_REQUIRED_INPUTS)
      .to match_array(declared)
  end

  it "supplies every input the executor declares required" do
    required = executor_class.descriptor[:inputs]
      .select { |_k, spec| spec.is_a?(Hash) && spec[:required] }
      .keys

    missing = required.reject { |k| composed_inputs[k].present? }
    expect(missing).to be_empty,
                       "composer omitted required executor inputs: #{missing.inspect}"
  end

  it "binds to #perform without an ArgumentError" do
    required_kwargs = executor_class.instance_method(:perform).parameters
      .filter_map { |type, name| name if type == :keyreq }

    missing = required_kwargs.reject { |k| composed_inputs.key?(k) }
    expect(missing).to be_empty,
                       "composed inputs miss required keywords: #{missing.inspect}"

    # Bind for real — a keyword mismatch raises here rather than being
    # swallowed by BaseSkillExecutor#execute's rescue.
    expect {
      executor_class.new(account: account)
        .send(:perform, **composed_inputs.merge(dry_run: true))
    }.not_to raise_error
  end

  it "treats target_count as a DELTA — the executor plans exactly the gap" do
    # dry_run is a harness concern (no real cloud resources); every other
    # input is verbatim from the composer.
    result = executor_class.new(account: account)
      .execute(**composed_inputs.merge(dry_run: true))

    expect(result[:error]).to be_nil
    data = result[:data]

    # Ground truth: the executor's own reported count is the gap (1), not
    # the absolute target (2). Passing the absolute here would have
    # provisioned 2 NEW instances on top of the 1 already running.
    expect(data[:count]).to eq(1)
    expect(data[:scaling_strategy]).to eq("add_replicas")
  end

  it "threads network + storage into the provisioning plan so peer/volume ids can appear" do
    result = executor_class.new(account: account)
      .execute(**composed_inputs.merge(dry_run: true))

    expect(result[:error]).to be_nil
    steps = Array(result.dig(:data, :planned_actions))

    # The provisioning primitive only emits these plan steps when
    # with_storage_gb / network_id are actually present — their appearance
    # is the ground-truth evidence that both were threaded through.
    storage_step = steps.find { |s| s[:step] == "provision_storage" }
    expect(storage_step).not_to be_nil,
                               "no provision_storage step — scale-out is volume-less: #{steps.inspect}"
    expect(storage_step[:size_gb]).to eq(50)

    # IMP-94f778f92dba — the step to look for is the ENROLLMENT, not the
    # old compile_sdwan_topology: that one read back the network's
    # pre-existing peers, so its presence never meant the scale-out itself
    # put anything on the fabric.
    sdwan_step = steps.find { |s| s[:step] == "attach_sdwan_peer" }
    expect(sdwan_step).not_to be_nil,
                             "no attach_sdwan_peer step — scale-out is peer-less: #{steps.inspect}"
    expect(sdwan_step[:network_id]).to eq(network.id)

    # And the outputs envelope exposes the keys the runner records.
    expect(result.dig(:data, :outputs)).to include(:sdwan_peer_ids, :storage_volume_ids)
  end
end
