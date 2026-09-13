# frozen_string_literal: true

require "rails_helper"

# Campaign 01a07025 increment app-2 — the lane for errored EPHEMERAL pool
# members. IMP-4e24a37fdd40 — and who owns it.
#
# THE DEFECT, measured on ops-hub 2026-09-05: 12 NodeInstances sat in status
# `error`, 9 of them ephemeral `ci-native-builders-*` pool members dating to
# 2026-08-09. Not one was reachable by any lane. InstanceStatusSensor scans
# running/starting, so it never saw them. InstanceUnrecoverableSensor's `error`
# arm admitted only rows the presumed-dead reaper had retired, and no
# `system.instance_presumed_dead` event existed for these. Four weeks, invisible.
# App-2 made the unrecoverable sensor admit them.
#
# THE SECOND DEFECT, 2026-09-08: admitted, each one minted a
# `system.instance_replace` approval, which claims a warm member of the same
# pool as a "replacement" and asks for the terminate as a second approval. For a
# dead CI builder there is nothing to replace. 10 of 17 pending approvals were
# those cards, and rejecting one only bought a cooldown.
#
# OPERATOR DIRECTION: reap, do not replace. A member the pool reaper will
# collect — on a churn plane, unclaimed, in a pool the reaper sweeps, with
# retention on — is left to it: a name-verified provider terminate, then the
# row. Everything else keeps the approval lane: a claimed member (the claimed
# arms flag and never terminate), a protected plane, an unswept pool, retention
# off — and a member the reaper has let go OVERDUE, so a reaper that fails a
# member hands it back instead of hiding it.
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
  let(:plane)        { "ci" }
  let(:member_plane) { plane }

  def template_in(slug)
    create(:system_node_template, account: account, node_platform: platform,
                                  environment: account.environments.find_by!(slug: slug))
  end

  let(:pool) do
    System::InstancePool.create!(
      account: account, name: "ci-native-builders-#{SecureRandom.hex(3)}",
      node_template: template_in(plane), target_size: 0, min_size: 0, max_size: 5,
      lifecycle_class: "ephemeral", status: "active"
    )
  end
  let(:sensor) { System::Fleet::Sensors::InstanceUnrecoverableSensor.new(account: account) }

  # Dead 3 days: past the sensor's 24h grace, inside the 7-day retention window,
  # so not yet overdue.
  let(:dead_for) { 3.days }

  def dead_member(pool_state: "errored", age: dead_for, plane_slug: member_plane)
    node = create(:system_node, account: account, node_template: template_in(plane_slug))
    inst = create(:system_node_instance, node: node, status: "error")
    inst.update!(instance_pool_id: pool.id, pool_state: pool_state)
    age!(inst, age)
    inst
  end

  let!(:dead_builder) { dead_member }

  def age!(inst, age)
    inst.update_columns(last_heartbeat_at: age.ago, pool_warming_started_at: age.ago, created_at: age.ago)
  end

  def collects?(inst)
    System::InstancePoolService.reaper_collects_dead_member?(inst.reload)
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

  def signalled_ids
    sensor.sense.map { |s| s.payload["instance_id"] }
  end

  describe "a member the pool reaper collects" do
    it "raises no unrecoverable signal, so no replace card" do
      expect(collects?(dead_builder)).to be(true)
      expect(sensor.sense).to be_empty
    end

    it "includes a member of a DRAINING pool — the reaper sweeps those too" do
      pool.update!(status: "draining")

      expect(collects?(dead_builder)).to be(true)
      expect(sensor.sense).to be_empty
    end

    it "is reaped by the pool reaper instead: one terminate, verified by its guest name, then the row, and no approval" do
      pool.update!(metadata: pool.metadata.merge("record_retention_days" => 1))
      # Out of circulation already, so only the retention phase acts on it.
      dead_builder.update_columns(pool_state: "draining")
      age!(dead_builder, 36.hours)
      expect(sensor.sense).to be_empty
      allow(System::ProvisioningService).to receive(:terminate_instance)
        .and_return(System::Runtime::Result.ok)

      System::InstancePoolService.recycle_stale_members!(pool: pool)

      expect(System::ProvisioningService).to have_received(:terminate_instance)
        .with(instance: having_attributes(id: dead_builder.id, provider_guest_name: dead_builder.name))
        .once
      expect(System::NodeInstance.where(id: dead_builder.id)).not_to exist
      expect(fleet_approvals).to be_empty
    end

    # Excluded before the per-tick limit, not after it: a burst of reaper-owned
    # rows must not crowd a real candidate out of the slice. Each owned member is
    # kept inside its window by a DIFFERENT single column, so the SQL clock is
    # pinned column by column too: a column missing from it would let that
    # member into the slice.
    it "never occupies the sensor's per-tick slice" do
      %i[last_heartbeat_at pool_warming_started_at pool_acquired_at created_at].each do |column|
        owned = dead_member(age: 30.days)
        owned.update_columns(column => 2.days.ago)
      end
      real = dead_member(pool_state: "claimed")
      allow(sensor).to receive(:threshold).and_call_original
      allow(sensor).to receive(:threshold).with("max_per_tick").and_return(1)

      # The slice is a random draw, so an owned row reaching it would miss the
      # real candidate on some tick; ten ticks make that near-certain.
      10.times { expect(signalled_ids).to eq([ real.id ]) }
    end
  end

  # The reaper's clock is the member's last sign of life. Each column counts on
  # its own, so a fixture with ONE recent column pins every one of them.
  describe "the last sign of life, column by column" do
    {
      "a recent heartbeat" => :last_heartbeat_at,
      "a recent warm start" => :pool_warming_started_at,
      "a recent claim" => :pool_acquired_at,
      "a recent creation" => :created_at
    }.each do |label, column|
      it "#{label} alone keeps an otherwise-overdue member the reaper's" do
        age!(dead_builder, 30.days)
        dead_builder.update_columns(column => 2.days.ago)

        expect(collects?(dead_builder)).to be(true)
        expect(sensor.sense).to be_empty
      end
    end
  end

  describe "a member the reaper has let go overdue" do
    it "is signalled again once its last sign of life passes the retention window plus the slack" do
      age!(dead_builder, 7.days + System::InstancePoolService::REAPER_OVERDUE_SLACK + 1.hour)

      expect(collects?(dead_builder)).to be(false)
      expect(signalled_ids).to eq([ dead_builder.id ])
    end

    it "is still the reaper's inside the slack" do
      age!(dead_builder, 7.days + 1.hour)

      expect(sensor.sense).to be_empty
    end
  end

  describe "a member the pool reaper does not collect keeps the approval lane" do
    it "a CLAIMED member — the claimed arms flag and never terminate, and the reaper leaves it" do
      dead_builder.update_columns(pool_state: "claimed", pool_acquired_at: dead_for.ago)
      allow(System::ProvisioningService).to receive(:terminate_instance)

      signals = sensor.sense
      expect(signals.size).to eq(1)
      expect(signals.first.payload["reason"]).to eq("ephemeral_pool_error")
      expect(signals.first.payload["instance_pool_id"]).to eq(pool.id)

      pool.update!(metadata: pool.metadata.merge("record_retention_days" => 1))
      System::InstancePoolService.recycle_stale_members!(pool: pool)
      expect(System::ProvisioningService).not_to have_received(:terminate_instance)
      expect(System::NodeInstance.where(id: dead_builder.id)).to exist
    end

    context "on a protected plane" do
      let(:plane) { "ops" }

      it "senses it" do
        expect(signalled_ids).to eq([ dead_builder.id ])
      end

      it "never reaps without an approval — the instance is still alive and a row is open" do
        Ai::InterventionPolicy.create!(
          account: account, ai_agent_id: agent.id, scope: "agent",
          action_category: "system.instance_replace", policy: "require_approval", is_active: true
        )
        expect(System::ProvisioningService).not_to receive(:terminate_instance)

        engine.decide(sensor.sense.first)

        alive = System::NodeInstance.find_by(id: dead_builder.id)
        expect(alive).to be_present, "the destructive half stays approval-gated on a protected plane"
        expect(alive.status).to eq("error")
        expect(fleet_approvals.count).to eq(1)
        expect(fleet_approvals.first.request_data["action_category"]).to eq("system.instance_replace")
      end
    end

    context "when the member sits on a protected plane its churn-plane pool does not" do
      let(:member_plane) { "ops" }

      it "senses it" do
        expect(signalled_ids).to eq([ dead_builder.id ])
      end
    end

    context "when the pool sits on a protected plane its churn-plane member does not" do
      let(:plane)        { "ops" }
      let(:member_plane) { "ci" }

      it "senses it" do
        expect(signalled_ids).to eq([ dead_builder.id ])
      end
    end

    it "a member of a PAUSED pool — the reaper does not sweep it" do
      pool.update!(status: "paused")

      expect(signalled_ids).to eq([ dead_builder.id ])
    end

    it "a member of a pool whose record retention is off" do
      pool.update!(metadata: pool.metadata.merge("record_retention_days" => 0))
      # Recent enough that only the retention guard can say no.
      dead_builder.update_columns(pool_warming_started_at: 12.hours.ago)

      expect(collects?(dead_builder)).to be(false)
      expect(signalled_ids).to eq([ dead_builder.id ])
    end

    it "a member of a pool whose retention override is not a whole number the SQL can read" do
      pool.update!(metadata: pool.metadata.merge("record_retention_days" => "a week"))

      expect(signalled_ids).to eq([ dead_builder.id ])
    end

    it "a member whose reaper check raises" do
      allow(System::InstancePoolService).to receive(:reaper_owned_members_sql).and_return(nil)
      allow(System::InstancePoolService).to receive(:reaper_collects_dead_member?).and_raise(ActiveRecord::StatementInvalid)

      expect(signalled_ids).to eq([ dead_builder.id ])
    end
  end

  # The SQL the sensor drops rows with BEFORE its limit must match a subset of
  # what the Ruby predicate collects — a row it matches that Ruby refuses would
  # be neither signalled nor reaped. So every refusal is asserted on BOTH halves.
  describe "the reaper-owned SQL and the Ruby predicate agree" do
    def sql_matches?(inst)
      owned = System::InstancePoolService.reaper_owned_members_sql(account: account)
      owned.present? && System::NodeInstance.where(id: inst.id).where(owned[:sql], owned[:binds]).exists?
    end

    it "both take the member the reaper collects" do
      expect(collects?(dead_builder)).to be(true)
      expect(sql_matches?(dead_builder)).to be(true)
    end

    {
      "a member that is not dead" => ->(ctx) { ctx.dead_builder.update_columns(status: "running") },
      "a member of another account's pool" => ->(ctx) { ctx.dead_builder.update_columns(account_id: ctx.create(:account).id) },
      "a member of a spot pool" => ->(ctx) { ctx.pool.update_columns(lifecycle_class: "spot") },
      "a claimed member" => ->(ctx) { ctx.dead_builder.update_columns(pool_state: "claimed") },
      "a member of a paused pool" => ->(ctx) { ctx.pool.update_columns(status: "paused") },
      "a member inside its window when fleet retention is off" => lambda { |ctx|
        SiteSetting.set("system.instance_pool.dead_record_retention_days", "0")
        ctx.dead_builder.update_columns(pool_warming_started_at: 12.hours.ago)
      },
      "an overdue member" => ->(ctx) { ctx.age!(ctx.dead_builder, 9.days) }
    }.each do |label, refuse|
      it "both refuse #{label}" do
        refuse.call(self)

        expect(collects?(dead_builder)).to be(false)
        expect(sql_matches?(dead_builder)).to be(false)
      end
    end

    # A retention far past any real window must not break the sensor's query
    # (the relation is lazy, so a SQL error would surface in #sense and blind
    # the sensor to every instance, not just pool members).
    it "survives an absurd fleet retention setting" do
      SiteSetting.set("system.instance_pool.dead_record_retention_days", "99999999999")

      expect { sensor.sense }.not_to raise_error
    end
  end

  describe "InstancePoolService.reaper_collects_dead_member?" do
    it "never claims a member that is not dead" do
      dead_builder.update_columns(status: "running")

      expect(collects?(dead_builder)).to be(false)
    end

    it "never claims a member of another account's pool" do
      dead_builder.update_columns(account_id: create(:account).id)

      expect(collects?(dead_builder)).to be(false)
    end

    it "never claims a member of a spot pool" do
      pool.update!(lifecycle_class: "spot")

      expect(collects?(dead_builder)).to be(false)
    end
  end

  it "leaves a fresh errored ephemeral member alone until the grace window passes" do
    dead_builder.update_columns(pool_state: "claimed")
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
end
