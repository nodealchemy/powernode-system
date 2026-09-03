# frozen_string_literal: true

require "rails_helper"

# IMP-e025722ef14e — APO-5 remainder, door 2: a project's declared snapshot
# interval / retention is EVALUATED against its volumes.
#
# APO-5 shipped the snapshot verbs and nothing that ever asked "is this
# project's snapshot overdue?" — a declared interval was decorative. This is
# the read-side half: given a mission (the platform's project), answer which
# of its volumes are DUE a scheduled snapshot and which completed snapshots
# exceed the retention count and are PRUNABLE. Pure read, in the BaseSensor
# contract's sense — it mutates nothing, so the sensor that emits from it and
# the appliers that act on its answer can each be reasoned about alone.
#
# The sensor and the DecisionEngine bindings are deliberately NOT here: a
# binding for a kind no sensor emits reds the FLEET_SENSORS.md signal-kind
# reconciliation (spec/docs/fleet_sensors_signal_kinds_spec.rb), and the
# sensors directory belongs to another lane this batch. This seam is what
# that sensor calls.
RSpec.describe System::VolumeManagementService, ".snapshot_schedule_for" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }
  let(:now)     { Time.zone.parse("2026-09-03 12:00:00 UTC") }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  # mission -> GoalPlan -> completed provisioning step, recorded through the
  # PRODUCTION writer, exactly as project_metrics_collector_spec.rb does — a
  # hand-written metadata literal is how a resolver can go green against a
  # shape nothing ever writes.
  def provisioned_mission(instance_ids, watch_policies: {})
    agent = create(:ai_agent, account: account)
    goal  = Ai::AgentGoal.create!(
      account: account, agent: agent, title: "provision",
      goal_type: "creation", status: "active", priority: 3, progress: 0.0
    )
    plan = Ai::GoalPlan.create!(account: account, goal: goal, agent: agent, status: "approved", version: 1)

    mission = create(
      :ai_mission, account: account, created_by: user, mission_type: "infrastructure",
      custom_phases: [ { "key" => "adapting", "label" => "Adapting", "order" => 0 } ],
      configuration: { "plan" => { "plan_id" => plan.id }, "watch_policies" => watch_policies }
    )
    mission.update_columns(status: "active")

    step = plan.steps.create!(step_number: 1, status: "pending", step_type: "provisioning_skill")
    envelope = { success: true,
                 data: { dry_run: false, count: instance_ids.size, planned_actions: [],
                         outputs: { node_ids: [], node_instance_ids: instance_ids,
                                    sdwan_peer_ids: [], storage_volume_ids: [] },
                         failures: [], partial: false } }
    runner = ::Ai::Provisioning::SkillCompositionRunner.new(account: account, mission: mission, plan: plan)
    runner.send(:mark_completed, step, runner.send(:result_outputs, envelope))

    mission
  end

  def attached_volume(name, inst = instance)
    create(:system_provider_volume, account: account, name: name, status: "in-use",
                                    external_id: "vol-#{name}", node_instance: inst, device_name: "/dev/sdb")
  end

  def completed_snapshot(volume, at:, name: "#{volume.name}-#{at.to_i}")
    create(:system_provider_volume_snapshot, account: account, volume: volume, name: name,
                                             status: "completed", external_id: "snap-#{name}",
                                             created_at: at)
  end

  let(:schedule) { { "snapshot_interval_hours" => 6, "snapshot_retention_count" => 2 } }

  it "answers nothing for a project that declares no schedule and no retention" do
    volume = attached_volume("plain")
    mission = provisioned_mission([ instance.id ])

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.due).to be_empty
    expect(answer.prunable).to be_empty
    expect(answer.policy).not_to be_scheduled
    expect(volume.snapshots.count).to eq(0), "the evaluator must not write"
  end

  it "names a volume that has never been snapshotted as due" do
    volume = attached_volume("fresh")
    mission = provisioned_mission([ instance.id ], watch_policies: schedule)

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.due.map { |d| d[:volume].id }).to eq([ volume.id ])
    expect(answer.due.first[:last_snapshot_at]).to be_nil
    expect(answer.due.first[:interval_hours]).to eq(6)
  end

  it "names a volume whose latest completed snapshot is older than the interval, and not one within it" do
    stale = attached_volume("stale")
    completed_snapshot(stale, at: now - 7.hours)
    current = attached_volume("current")
    completed_snapshot(current, at: now - 5.hours)
    mission = provisioned_mission([ instance.id ], watch_policies: schedule)

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.due.map { |d| d[:volume].id }).to eq([ stale.id ])
    expect(answer.due.first[:last_snapshot_at]).to eq(now - 7.hours)
  end

  # A row still "creating" is a snapshot in flight; issuing another on the
  # next tick would double the provider's work for the same restore point.
  it "does not treat a volume with a snapshot in flight as due" do
    volume = attached_volume("inflight")
    create(:system_provider_volume_snapshot, account: account, volume: volume, status: "creating",
                                             progress: 10, created_at: now - 5.minutes)
    mission = provisioned_mission([ instance.id ], watch_policies: schedule)

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.due).to be_empty
  end

  # An "error" row is an attempt that failed; it is not a restore point and
  # must not satisfy the schedule.
  it "treats a volume whose only snapshot errored as due" do
    volume = attached_volume("errored")
    create(:system_provider_volume_snapshot, account: account, volume: volume, status: "error",
                                             progress: 0, created_at: now - 1.hour)
    mission = provisioned_mission([ instance.id ], watch_policies: schedule)

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.due.map { |d| d[:volume].id }).to eq([ volume.id ])
  end

  it "names the completed snapshots beyond the retention count as prunable, oldest first" do
    volume = attached_volume("kept")
    oldest = completed_snapshot(volume, at: now - 30.hours)
    older  = completed_snapshot(volume, at: now - 20.hours)
    completed_snapshot(volume, at: now - 10.hours)
    completed_snapshot(volume, at: now - 1.hour)
    mission = provisioned_mission([ instance.id ], watch_policies: schedule)

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.prunable.map { |p| p[:snapshot].id }).to eq([ oldest.id, older.id ])
    expect(answer.prunable.first[:retention_count]).to eq(2)
    expect(answer.due).to be_empty
  end

  it "prunes nothing when retention is undeclared, however many snapshots exist" do
    volume = attached_volume("unbounded")
    3.times { |i| completed_snapshot(volume, at: now - (i + 1).hours) }
    mission = provisioned_mission([ instance.id ], watch_policies: { "snapshot_interval_hours" => 6 })

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.prunable).to be_empty
  end

  it "counts only completed snapshots toward retention" do
    volume = attached_volume("mixed")
    completed_snapshot(volume, at: now - 3.hours)
    completed_snapshot(volume, at: now - 2.hours)
    create(:system_provider_volume_snapshot, account: account, volume: volume, status: "error",
                                             progress: 0, created_at: now - 1.hour)
    mission = provisioned_mission([ instance.id ], watch_policies: schedule)

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.prunable).to be_empty
  end

  it "ignores volumes that cannot be snapshotted or never reached a provider" do
    creating = create(:system_provider_volume, account: account, name: "creating", status: "creating",
                                               external_id: "vol-creating", node_instance: instance)
    phantom  = create(:system_provider_volume, account: account, name: "phantom", status: "in-use",
                                               external_id: nil, node_instance: instance)
    mission = provisioned_mission([ instance.id ], watch_policies: schedule)

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.due.map { |d| d[:volume].id }).not_to include(creating.id, phantom.id)
  end

  it "reads only the volumes attached to the project's own instances" do
    other_instance = create(:system_node_instance, :running, node: node)
    attached_volume("theirs", other_instance)
    mine = attached_volume("mine")
    mission = provisioned_mission([ instance.id ], watch_policies: schedule)

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.due.map { |d| d[:volume].id }).to eq([ mine.id ])
  end

  it "resolves nothing for a project whose plan recorded no instances" do
    attached_volume("orphan")
    mission = provisioned_mission([], watch_policies: schedule)

    answer = described_class.snapshot_schedule_for(mission: mission, now: now)

    expect(answer.due).to be_empty
    expect(answer.prunable).to be_empty
  end
end
