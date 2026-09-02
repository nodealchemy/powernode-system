# frozen_string_literal: true

require "rails_helper"

# APO-2c — the PRODUCER behind `system.project_cost_breach`.
#
# The breach lane was complete except for its input: ProjectSloSensor has a
# `cost_breach_signal` arm, DecisionEngine has a SIGNAL_BINDINGS entry and a
# remediation applier for it, and `cost_usd_mtd` was already in the metric
# vocabulary — but ProjectMetricsCollector had no branch for it, so every
# sample was `unavailable`, `month_to_date_cost_usd` was always nil, and
# `cost_breach_signal`'s `return nil if observed.nil?` meant the signal could
# never fire on any mission, at any budget.
#
# The catalog side already existed too: System::ProviderInstanceType carries
# hourly_price (and RegionInstanceType a per-region override). Nothing
# multiplied it by the mission's running instance-hours.
RSpec.describe System::ProjectMetricsCollector, "cost_usd_mtd" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  # Mid-month, so `beginning_of_month` and "created before this month" are
  # both unambiguous and the arithmetic below is exact rather than tolerant.
  let(:now)          { Time.zone.parse("2026-06-15 12:00:00") }
  let(:month_start)  { Time.zone.parse("2026-06-01 00:00:00") }

  around { |example| travel_to(now) { example.run } }

  def seed_provisioned_mission(instance_ids, configuration: {})
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
      configuration: { "plan" => { "plan_id" => plan.id } }.merge(configuration)
    )
    mission.update_columns(status: "active")

    step = plan.steps.create!(step_number: 1, status: "pending", step_type: "provisioning_skill")
    runner = ::Ai::Provisioning::SkillCompositionRunner.new(account: account, mission: mission, plan: plan)
    runner.send(
      :mark_completed, step,
      runner.send(:result_outputs,
                  { success: true,
                    data: { outputs: { node_instance_ids: instance_ids } } })
    )

    mission
  end

  def priced_type(hourly:, provider_type: "aws", currency: "USD")
    provider = create(:system_provider, account: account, provider_type: provider_type)
    create(:system_provider_instance_type,
           account: account, provider: provider, hourly_price: hourly, currency: currency)
  end

  # `created_at` is the only accrual start the platform records, so it is what
  # the sampler bills from (clamped to the start of the month).
  def running_instance(type:, region:, created_at:, node: nil)
    node ||= create(:system_node, account: account)
    inst = create(:system_node_instance, :running,
                  node: node, provider_region: region, provider_instance_type: type)
    inst.update_columns(created_at: created_at)
    inst
  end

  # Same as #running_instance but for an arbitrary lifecycle status: the
  # accrual question is which statuses a PROVIDER bills, which is not the same
  # set the capacity scope calls live.
  def instance_with_status(status, type:, region:, created_at:, node: nil)
    node ||= create(:system_node, account: account)
    inst = create(:system_node_instance,
                  node: node, provider_region: region,
                  provider_instance_type: type, status: status)
    inst.update_columns(created_at: created_at)
    inst
  end

  def cost_row(mission)
    System::ProjectMetric.where(mission_id: mission.id, metric_name: "cost_usd_mtd").first
  end

  it "multiplies the pricing catalog by month-to-date instance-hours" do
    region = create(:system_provider_region, account: account)
    type   = priced_type(hourly: 0.05)

    # A: 2026-06-10 12:00 -> now = 120h.
    # B: created BEFORE the month, so it accrues from month_start
    #    (2026-06-01 00:00 -> 2026-06-15 12:00) = 348h.
    # (120 + 348) * 0.05 = 23.40.
    a = running_instance(type: type, region: region, created_at: now - 5.days)
    b = running_instance(type: type, region: region, created_at: Time.zone.parse("2026-05-20 09:00:00"))

    mission = seed_provisioned_mission([ a.id, b.id ])

    described_class.collect!(mission: mission)

    row = cost_row(mission)
    expect(row.value).to include("source" => "live", "unit" => "usd", "currency" => "USD")
    expect(row.value["observed"]).to be_within(0.01).of(23.40)
    expect(row.value["window_start"]).to eq(month_start.iso8601)
    expect(row.metric_type).to eq("cost")
  end

  it "prices from the region override when the region carries its own rate" do
    region = create(:system_provider_region, account: account)
    type   = priced_type(hourly: 0.05)
    System::RegionInstanceType.create!(
      provider_region: region, provider_instance_type: type, hourly_price: 0.10, available: true
    )

    inst = running_instance(type: type, region: region, created_at: now - 10.hours)
    mission = seed_provisioned_mission([ inst.id ])

    described_class.collect!(mission: mission)

    # 10h at the REGION rate, not the base rate (which would be 0.50).
    expect(cost_row(mission).value["observed"]).to be_within(0.01).of(1.00)
  end

  # FULL COVERAGE OR NOTHING. A sum over only the replicas that happened to be
  # priceable UNDERSTATES month-to-date spend, and a ceiling breach fires on
  # `observed > target` — so a partial sum can only ever SUPPRESS a real
  # breach, silently, in exactly the case the budget guard exists for.
  it "reports unavailable when any live replica has no resolvable price" do
    region  = create(:system_provider_region, account: account)
    priced  = priced_type(hourly: 0.05)
    unknown = priced_type(hourly: nil)

    a = running_instance(type: priced, region: region, created_at: now - 10.hours)
    b = running_instance(type: unknown, region: region, created_at: now - 10.hours)
    mission = seed_provisioned_mission([ a.id, b.id ])

    described_class.collect!(mission: mission)

    row = cost_row(mission)
    expect(row.value).to include("observed" => nil, "source" => "unavailable")
    expect(row.value["unpriced_instance_count"]).to eq(1)
    expect(row.value["instance_count"]).to eq(2)
  end

  # A non-USD SKU is a price we cannot put in a metric named `cost_usd_mtd`;
  # publishing the number unconverted would compare euros to a dollar ceiling.
  it "treats a SKU priced in another currency as unpriced" do
    region = create(:system_provider_region, account: account)
    eur    = priced_type(hourly: 0.05, currency: "EUR")

    inst = running_instance(type: eur, region: region, created_at: now - 10.hours)
    mission = seed_provisioned_mission([ inst.id ])

    described_class.collect!(mission: mission)

    row = cost_row(mission)
    expect(row.value).to include("observed" => nil, "source" => "unavailable")
    expect(row.value["unpriced_instance_count"]).to eq(1)
  end

  # Local hypervisor capacity accrues no provider charge — a REAL zero, not an
  # unknown, and it must not poison the priced replicas alongside it. The
  # free-provider set is core's (CostEstimatorService::LOCAL_PROVIDER_TYPES)
  # rather than a second opinion declared here.
  it "bills a local-hypervisor replica at zero without going unavailable" do
    region = create(:system_provider_region, account: account)
    cloud  = priced_type(hourly: 0.05)
    local  = priced_type(hourly: nil, provider_type: "local_qemu")

    a = running_instance(type: cloud, region: region, created_at: now - 10.hours)
    b = running_instance(type: local, region: region, created_at: now - 10.hours)
    mission = seed_provisioned_mission([ a.id, b.id ])

    described_class.collect!(mission: mission)

    row = cost_row(mission)
    expect(row.value).to include("source" => "live")
    expect(row.value["observed"]).to be_within(0.01).of(0.50)
    expect(row.value["unpriced_instance_count"]).to eq(0)
  end

  # ZERO IS NOT A PRICE on a billed provider — compute costs something, so a
  # 0.0 rate is an unpopulated catalog row. Treating it as free would let a
  # whole uncosted fleet publish $0.00 wearing `source: "live"`, which is the
  # fabricated zero every other sampler in this collector refuses.
  it "treats a zero rate on a billed provider as unpriced, not as free" do
    region = create(:system_provider_region, account: account)
    free   = priced_type(hourly: 0.0)

    inst = running_instance(type: free, region: region, created_at: now - 10.hours)
    mission = seed_provisioned_mission([ inst.id ])

    described_class.collect!(mission: mission)

    row = cost_row(mission)
    expect(row.value).to include("observed" => nil, "source" => "unavailable")
    expect(row.value["unpriced_instance_count"]).to eq(1)
  end

  # A replica whose created_at is in the future (clock skew between the
  # provider adapter and this host) bills nothing. Without the guard the
  # elapsed hours go NEGATIVE and that replica CREDITS the mission, pulling
  # the whole fleet's accrual down below its true value.
  it "bills nothing for a replica whose start is in the future" do
    region = create(:system_provider_region, account: account)
    type   = priced_type(hourly: 0.05)

    a = running_instance(type: type, region: region, created_at: now - 10.hours) # 0.50
    b = running_instance(type: type, region: region, created_at: now + 10.hours)
    mission = seed_provisioned_mission([ a.id, b.id ])

    described_class.collect!(mission: mission)

    expect(cost_row(mission).value["observed"]).to be_within(0.01).of(0.50)
  end

  it "reports unavailable when the mission has no live replicas" do
    region = create(:system_provider_region, account: account)
    type   = priced_type(hourly: 0.05)
    node   = create(:system_node, account: account)
    dead   = create(:system_node_instance, node: node, provider_region: region,
                                           provider_instance_type: type, status: "terminated")

    mission = seed_provisioned_mission([ dead.id ])
    described_class.collect!(mission: mission)

    row = cost_row(mission)
    expect(row.value).to include("observed" => nil, "source" => "unavailable")
  end

  # END TO END — collector -> ProjectMetric row -> ProjectSloSensor. The
  # silence this task fixes was a property of the PAIR: a collector-only
  # example would still pass if the sensor stopped reading the row, and the
  # sensor's own specs already pass by hand-authoring the observation the
  # collector never wrote.
  it "lets ProjectSloSensor fire a project_cost_breach off the sampled cost" do
    region = create(:system_provider_region, account: account)
    type   = priced_type(hourly: 0.05)
    inst   = running_instance(type: type, region: region, created_at: now - 5.days) # 120h -> 6.00

    mission = seed_provisioned_mission(
      [ inst.id ], configuration: { "slo_targets" => { "cost_ceiling_usd" => 4.0 } }
    )

    described_class.collect!(mission: mission)

    breach = System::Fleet::Sensors::ProjectSloSensor.new(account: account).sense
                                                     .find { |s| s.kind == "system.project_cost_breach" }
    expect(breach).not_to be_nil
    expect(breach.payload).to include("observed_usd" => 6.0, "target_usd" => 4.0)
  end

  # A CAPACITY scope is not a BILLING scope. NodeInstance::LIVE_REPLICA_STATUSES
  # deliberately spans pending/provisioning/stopped/rebooting so replica_count
  # and the utilization means describe ONE fleet — but a provider bills compute
  # for none of the first three: `pending`/`provisioning` may have no VM at the
  # provider at all, and a `stopped` instance is powered off. Billing them at
  # the full catalog rate OVERSTATES spend and fabricates exactly the breach
  # this metric exists to report honestly: a fleet stopped on the 2nd TO SAVE
  # MONEY would trip its own ceiling on the 30th.
  it "bills nothing for replicas the provider charges no compute for" do
    region = create(:system_provider_region, account: account)
    type   = priced_type(hourly: 0.05)

    up      = running_instance(type: type, region: region, created_at: now - 10.hours) # 0.50
    stopped = instance_with_status("stopped", type: type, region: region, created_at: now - 20.days)
    pending = instance_with_status("pending", type: type, region: region, created_at: now - 20.days)

    mission = seed_provisioned_mission([ up.id, stopped.id, pending.id ])
    described_class.collect!(mission: mission)

    row = cost_row(mission)
    expect(row.value).to include("source" => "live")
    expect(row.value["observed"]).to be_within(0.01).of(0.50)
    expect(row.value["instance_count"]).to eq(3)
    expect(row.value["non_accruing_instance_count"]).to eq(2)
  end

  # FULL COVERAGE OR NOTHING is a rule about the replicas that CONTRIBUTE. A
  # replica the provider bills nothing for contributes a real zero whatever the
  # catalog says about its SKU, so an unpriced stopped replica must not blank a
  # sample the running fleet can be priced for.
  it "does not blank the sample because a non-accruing replica is unpriced" do
    region  = create(:system_provider_region, account: account)
    priced  = priced_type(hourly: 0.05)
    unknown = priced_type(hourly: nil)

    up      = running_instance(type: priced, region: region, created_at: now - 10.hours)
    stopped = instance_with_status("stopped", type: unknown, region: region, created_at: now - 10.hours)

    mission = seed_provisioned_mission([ up.id, stopped.id ])
    described_class.collect!(mission: mission)

    row = cost_row(mission)
    expect(row.value).to include("source" => "live")
    expect(row.value["observed"]).to be_within(0.01).of(0.50)
    expect(row.value["unpriced_instance_count"]).to eq(0)
    expect(row.value["non_accruing_instance_count"]).to eq(1)
  end

  # The disclosure IS the thing that makes a knowingly-incomplete accrual
  # publishable, so it is pinned rather than promised: without the note and the
  # standing-vs-provisioned gap on the row, an operator reads the number as a
  # complete bill.
  it "publishes the accrual's disclosure note and the standing-vs-provisioned gap" do
    region = create(:system_provider_region, account: account)
    type   = priced_type(hourly: 0.05)

    up   = running_instance(type: type, region: region, created_at: now - 10.hours)
    gone = instance_with_status("terminated", type: type, region: region, created_at: now - 10.days)
    also = instance_with_status("terminated", type: type, region: region, created_at: now - 10.days)

    mission = seed_provisioned_mission([ up.id, gone.id, also.id ])
    described_class.collect!(mission: mission)

    row = cost_row(mission)
    expect(row.value["provisioned_instance_count"]).to eq(3)
    expect(row.value["instance_count"]).to eq(1)
    expect(row.value["note"]).to eq(described_class::COST_ACCRUAL_NOTE)
  end

  # A sample that could not be denominated must not claim a denomination: the
  # non-USD row's whole reason for being unavailable is that USD is not the
  # currency the catalog quotes, so stamping "currency" => "USD" on it tells the
  # operator the opposite of the truth.
  it "does not stamp a currency on a sample it could not denominate" do
    region = create(:system_provider_region, account: account)
    eur    = priced_type(hourly: 0.05, currency: "EUR")

    inst = running_instance(type: eur, region: region, created_at: now - 10.hours)
    mission = seed_provisioned_mission([ inst.id ])
    described_class.collect!(mission: mission)

    row = cost_row(mission)
    expect(row.value).to include("source" => "unavailable")
    expect(row.value).not_to have_key("currency")
  end
end
