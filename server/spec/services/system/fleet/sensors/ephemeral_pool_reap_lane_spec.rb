# frozen_string_literal: true

require "rails_helper"

# Campaign 01a07025 increment app-2 — the reap lane for errored EPHEMERAL pool
# members.
#
# THE DEFECT, measured on ops-hub 2026-09-05: 12 NodeInstances sat in status
# `error`, 9 of them ephemeral `ci-native-builders-*` pool members dating to
# 2026-08-09. Not one was reachable by any lane. InstanceStatusSensor scans
# running/starting, so it never saw them. InstanceUnrecoverableSensor's `error`
# arm admitted only rows the presumed-dead reaper had retired, and no
# `system.instance_presumed_dead` event existed for these. With no
# instance_silent remediation ever attempted, their ineffective streak was 0, so
# #reboot_exhausted would have declined them anyway. Four weeks, invisible.
#
# THE DESTRUCTIVE HALF STAYS APPROVAL-GATED. Per the ratified rule in
# docs/operations/autonomous-infrastructure-readiness-2026-08-12.md §7, removals
# never auto-apply. This lane's job is to SURFACE and PREPARE: the sensor emits,
# the binding plans a replace under `system.instance_replace`
# (seeded require_approval), and the terminate is a SECOND approval on
# `system.instance_reap` replaying ReapInstanceExecutor. Nothing here shortens
# that path, and the last example asserts it on ROWS.
RSpec.describe "the ephemeral pool reap lane" do
  let(:account)   { create(:account) }
  let!(:operator) { create(:user, account: account) }
  let(:agent)     { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)   { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }
  let(:engine)    { System::Fleet::DecisionEngine.new(autonomy_service: service) }
  let!(:chain) do
    create(:ai_approval_chain, account: account, trigger_type: "autonomy_action",
                               status: "active", name: "Fleet Autonomy Chain")
  end

  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:pool) do
    System::InstancePool.create!(
      account: account, name: "ci-native-builders-#{SecureRandom.hex(3)}",
      node_template: template, target_size: 1, min_size: 0, max_size: 5,
      lifecycle_class: "ephemeral", status: "active"
    )
  end
  let(:sensor) { System::Fleet::Sensors::InstanceUnrecoverableSensor.new(account: account) }

  let!(:dead_builder) do
    inst = create(:system_node_instance, node: node, status: "error")
    inst.update!(last_heartbeat_at: 27.days.ago, instance_pool_id: pool.id, pool_state: "errored")
    inst
  end

  before do
    Rails.cache.clear
    # Absence of provider state must stay UNKNOWN — this lane must not be a
    # repackaged provider probe, so every example runs with no adapter at all.
    allow(System::Providers::Registry).to receive(:for_instance).and_return(nil)
  end

  def fleet_approvals
    Ai::ApprovalRequest.where(account_id: account.id)
  end

  it "senses an errored ephemeral pool member that no other classification reaches" do
    signals = sensor.sense

    expect(signals.size).to eq(1)
    expect(signals.first.kind).to eq("system.instance_unrecoverable")
    expect(signals.first.payload["reason"]).to eq("ephemeral_pool_error")
    expect(signals.first.payload["instance_pool_id"]).to eq(pool.id)
  end

  it "leaves a fresh errored ephemeral member alone until the grace window passes" do
    dead_builder.update!(last_heartbeat_at: 5.minutes.ago)

    expect(sensor.sense).to be_empty
  end

  # REAPABLE_LIFECYCLE_CLASSES excludes `spot` on purpose — an errored spot
  # member may be a provider reclaim, which has a different answer and no ruling
  # behind it. Pinned so widening the list stays a decision.
  it "leaves an errored SPOT pool member alone" do
    pool.update!(lifecycle_class: "spot")

    expect(sensor.sense).to be_empty
  end

  it "leaves an errored instance that belongs to NO pool alone" do
    dead_builder.update!(instance_pool_id: nil, pool_state: nil)

    expect(sensor.sense).to be_empty
  end

  it "never reaps without an approval — the instance is still alive and a row is open" do
    Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: agent.id, scope: "agent",
      action_category: "system.instance_replace", policy: "require_approval", is_active: true
    )
    expect(System::ProvisioningService).not_to receive(:terminate_instance)

    engine.decide(sensor.sense.first)

    alive = System::NodeInstance.find_by(id: dead_builder.id)
    expect(alive).to be_present,
                     "the destructive half stays approval-gated (ratified rule §7)"
    expect(alive.status).to eq("error"),
                            "nothing may transition the instance before an operator releases the reap"
    expect(fleet_approvals.count).to eq(1)
    expect(fleet_approvals.first.request_data["action_category"]).to eq("system.instance_replace")
  end
end
