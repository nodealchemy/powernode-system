# frozen_string_literal: true

require "rails_helper"

# IMP-10c9b9634d4e — an instance nobody has heard from in weeks is not a
# remediation target, it is a machine that no longer exists.
#
# On 2026-09-08 an ops-cell instance created 2026-07-29 sat in `starting` with
# its last heartbeat on 2026-08-10. The fleet treated it as live: it raised
# system.instance_silent (critical) with a reprovision plan and a standing
# system.template_closure_drift re-detected 1416 times whose card warned about
# the template's provisioned nodes. Six more ops-cell rows sat in error/stopped
# since 2026-08-09. None of them should be remediated; they should be reaped.
#
# This sensor is the ONE authority on "abandoned": the reap lane, and the
# sensors that must stop proposing work on such a machine, all read it.
RSpec.describe System::Fleet::Sensors::AbandonedInstanceSensor do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:sensor)   { described_class.new(account: account) }
  let(:window)   { described_class::ABANDON_AFTER_SECONDS.seconds }

  def instance(status: "starting", heartbeat: 30.days.ago, created: 60.days.ago, owner_node: node, **attrs)
    inst = create(:system_node_instance, node: owner_node, status: status, **attrs)
    inst.update_columns(last_heartbeat_at: heartbeat, created_at: created)
    inst
  end

  def emitted_ids
    sensor.sense.map { |s| s.payload["instance_id"] }
  end

  it "declares its kind and tunable window" do
    expect(described_class::SIGNAL_KIND).to eq("system.instance_abandoned")
    expect(described_class.default_thresholds).to eq(
      "abandon_after_seconds" => described_class::ABANDON_AFTER_SECONDS,
      "max_per_tick" => described_class::MAX_PER_TICK,
      "max_parked_per_tick" => described_class::MAX_PARKED_PER_TICK
    )
    expect(described_class::ABANDON_AFTER_SECONDS).to eq(7 * 86_400)
  end

  describe "#sense — what is abandoned" do
    it "reports a non-pool instance stuck in starting whose last heartbeat is weeks old (the finding's shape)" do
      inst = instance(status: "starting", heartbeat: 29.days.ago)

      signals = sensor.sense

      expect(signals.size).to eq(1)
      signal = signals.first
      expect(signal.kind).to eq("system.instance_abandoned")
      expect(signal.fingerprint).to eq("instance_abandoned:#{inst.id}")
      expect(signal.payload).to include(
        "instance_id" => inst.id, "node_id" => node.id, "status" => "starting",
        "abandon_after_seconds" => described_class::ABANDON_AFTER_SECONDS
      )
      expect(Time.iso8601(signal.payload["last_sign_of_life_at"])).to be_within(1.second).of(inst.last_heartbeat_at)
    end

    it "reports running, error and stopped rows past the window" do
      ids = %w[running error stopped].map { |status| instance(status: status).id }

      expect(emitted_ids).to match_array(ids)
    end

    it "ages a never-enrolled row by its creation, since it has no heartbeat to age" do
      inst = instance(status: "error", heartbeat: nil, created: 30.days.ago)

      expect(emitted_ids).to eq([ inst.id ])
    end

    # A guest-lost row has no id left, and terminate finalizes it rather than
    # refusing, so it is still reapable.
    it "reports a row whose provider guest was lost, which terminate finalizes" do
      inst = instance(status: "error", cloud_instance_id: nil,
                      config: { "provider_guest_lost_at" => 10.days.ago.iso8601 })

      expect(emitted_ids).to eq([ inst.id ])
    end
  end

  # Review F1/F2: a terminate destroys every disk in the guest's config. Where
  # that can cost data or an address someone depends on, the reap still parks
  # ONE approval in any plane instead of proceeding on the tick.
  describe "#sense — data at stake parks the reap" do
    def signal_for(inst)
      sensor.sense.find { |s| s.payload["instance_id"] == inst.id }
    end

    it "does not ask for approval for a dead guest holding nothing" do
      inst = instance(status: "error")

      expect(signal_for(inst).payload).to include("requires_approval" => false, "approval_reasons" => [])
    end

    it "asks for approval for a powered-off guest, which may have been stopped on purpose" do
      inst = instance(status: "stopped")

      expect(signal_for(inst).payload).to include("requires_approval" => true,
                                                  "approval_reasons" => [ "stopped" ])
    end

    it "asks for approval for a guest with an attached volume" do
      inst = instance(status: "error")
      create(:system_provider_volume, :attached, account: account, node_instance_id: inst.id)

      expect(signal_for(inst).payload).to include("requires_approval" => true,
                                                  "approval_reasons" => [ "attached_volumes" ])
    end

    # Re-review F3: agent silence alone is not the provider's view. A guest the
    # platform last saw running may be a live VM with a broken agent.
    it "asks for approval for a guest the platform last saw running" do
      inst = instance(status: "running")

      expect(signal_for(inst).payload).to include("requires_approval" => true,
                                                  "approval_reasons" => [ "running" ])
    end

    # Round 3: excluding VIP holders left a dead failover standby on no lane
    # (VirtualIp#failover! puts the old holder there). It stays on this lane,
    # parked, with the reason on the card.
    it "asks for approval for a guest that holds a virtual IP through one of its peers" do
      inst = instance(status: "error")
      peer = create(:sdwan_peer, account: account, node_instance: inst)
      create(:sdwan_virtual_ip, network: peer.network, account: account, holder_peer_ids: [ peer.id ])

      expect(signal_for(inst).payload).to include("requires_approval" => true,
                                                  "approval_reasons" => [ "virtual_ip_holder" ])
    end

    it "asks for approval for a guest that is failover for a virtual IP" do
      inst = instance(status: "error")
      peer = create(:sdwan_peer, account: account, node_instance: inst)
      create(:sdwan_virtual_ip, network: peer.network, account: account, failover_holder_peer_ids: [ peer.id ])

      expect(signal_for(inst).payload).to include("requires_approval" => true,
                                                  "approval_reasons" => [ "virtual_ip_holder" ])
    end
  end

  describe "#sense — what is not" do
    it "leaves a row whose last heartbeat is inside the window" do
      instance(heartbeat: window.ago + 1.hour)

      expect(sensor.sense).to be_empty
    end

    it "leaves a never-enrolled row created inside the window" do
      instance(status: "starting", heartbeat: nil, created: 2.days.ago)

      expect(sensor.sense).to be_empty
    end

    it "leaves pool members to the pool's own reaper" do
      pool = System::InstancePool.create!(
        account: account, node_template: template, name: "pool-#{SecureRandom.hex(3)}",
        target_size: 1, min_size: 0, max_size: 3, lifecycle_class: "ephemeral", status: "active"
      )
      instance(status: "error", instance_pool_id: pool.id, pool_state: "errored")

      expect(sensor.sense).to be_empty
    end

    it "leaves physical machines, which are not provider guests to reap" do
      instance(status: "stopped", variety: "physical")

      expect(sensor.sense).to be_empty
    end

    it "leaves an instance under an operator hold" do
      inst = instance(status: "error")
      inst.update_columns(ops_hold_at: 1.day.ago)

      expect(sensor.sense).to be_empty
    end

    it "leaves rows in a status with another owner or none left to act on" do
      %w[pending provisioning stopping rebooting terminated].each { |status| instance(status: status) }

      expect(sensor.sense).to be_empty
    end

    # Review F3: a row terminate can only ever refuse would hold a slot of the
    # per-tick bound forever. It stays on the lanes that already report it.
    it "leaves a row with no provider identity, which terminate can only refuse" do
      instance(status: "error", cloud_instance_id: nil)

      expect(sensor.sense).to be_empty
    end

    it "leaves the platform's own hosting node, which the self-management fence refuses" do
      instance(status: "error")
      ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, node.id)

      expect(sensor.sense).to be_empty
    end

    # Review F4: a DR replace that holds a replacement is waiting on its own
    # system.instance_reap decision; this lane must not decide it instead.
    it "leaves the failed side of a DR replace in flight" do
      inst = instance(status: "error")
      System::FleetEvent.create!(account: account, kind: "system.instance_replace.acquire_replacement",
                                 severity: "low", node_instance_id: inst.id, emitted_at: 1.day.ago,
                                 payload: { "failed_instance_id" => inst.id, "operation_id" => "op-1" })

      expect(sensor.sense).to be_empty
    end

    it "never reports another account's instance" do
      other = create(:account)
      other_node = create(:system_node, account: other, node_template: create(:system_node_template, account: other))
      instance(owner_node: other_node)

      expect(sensor.sense).to be_empty
    end
  end

  describe "tuning" do
    it "reads the window from the account's sensor config" do
      inst = instance(heartbeat: 2.days.ago)
      expect(sensor.sense).to be_empty

      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "abandoned_instance",
                                             config: { "abandon_after_seconds" => 86_400 })

      expect(described_class.new(account: account).sense.map { |s| s.payload["instance_id"] }).to eq([ inst.id ])
    end

    it "bounds each tick, oldest sign of life first" do
      oldest = instance(heartbeat: 40.days.ago)
      instance(heartbeat: 20.days.ago)
      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "abandoned_instance",
                                             config: { "max_per_tick" => 1 })

      expect(described_class.new(account: account).sense.map { |s| s.payload["instance_id"] }).to eq([ oldest.id ])
    end
  end

  # Review F3: the other sensors stop reporting ONLY the rows this sensor
  # actually signals. A row past the per-tick bound keeps its old cards until
  # it is on the reap lane, instead of being on neither.
  describe ".claimed_relation" do
    it "is exactly the slice #sense signals" do
      oldest = instance(heartbeat: 40.days.ago)
      younger = instance(heartbeat: 20.days.ago)
      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "abandoned_instance",
                                             config: { "max_per_tick" => 1 })

      claimed = described_class.claimed_relation(account: account).pluck(:id)

      expect(claimed).to eq([ oldest.id ])
      expect(claimed).not_to include(younger.id)
      expect(described_class.new(account: account).sense.map { |s| s.payload["instance_id"] }).to eq(claimed)
    end

    # Re-review F1: the bound exists because each signal can become a terminate
    # on the tick. A reap that will park terminates nothing, so it does not
    # spend the bound — ten parked cards cannot stop every other reap.
    it "bounds only the reaps that would proceed without approval" do
      parked_old = instance(status: "stopped", heartbeat: 50.days.ago)
      parked_volume = instance(status: "error", heartbeat: 48.days.ago)
      create(:system_provider_volume, :attached, account: account, node_instance_id: parked_volume.id)
      auto_old = instance(status: "error", heartbeat: 40.days.ago)
      instance(status: "error", heartbeat: 30.days.ago)
      protected_env = create(:ai_environment, account: account, slug: "held-plane", is_protected: true)
      parked_protected = instance(status: "error", heartbeat: 45.days.ago, environment: protected_env)
      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "abandoned_instance",
                                             config: { "max_per_tick" => 1 })

      claimed = described_class.claimed_relation(account: account).pluck(:id)

      expect(claimed).to eq([ parked_old.id, parked_volume.id, parked_protected.id, auto_old.id ])
    end

    # Parked reaps terminate nothing, but each re-emits every tick, so they
    # have a bound of their own; one past it keeps its old cards.
    it "bounds the reaps that will park separately" do
      parked_old = instance(status: "stopped", heartbeat: 50.days.ago)
      instance(status: "stopped", heartbeat: 40.days.ago)
      auto = instance(status: "error", heartbeat: 30.days.ago)
      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "abandoned_instance",
                                             config: { "max_parked_per_tick" => 1 })

      expect(described_class.claimed_relation(account: account).pluck(:id)).to eq([ parked_old.id, auto.id ])
    end

    it "breaks a tie in last sign of life by id, so every reader draws the same slice" do
      stamp = 30.days.ago
      tied = [ instance(status: "error", heartbeat: stamp), instance(status: "error", heartbeat: stamp) ]
      System::Fleet::SensorConfig.upsert_for(account: account, sensor: "abandoned_instance",
                                             config: { "max_per_tick" => 1 })

      expect(described_class.claimed_relation(account: account).pluck(:id)).to eq([ tied.map(&:id).min ])
    end
  end

  # The SQL relation and the Ruby predicate are two spellings of one rule: the
  # relation drives the sensor and the other sensors' exclusions, the predicate
  # re-checks a row at reap time. They must answer alike on every arm, or a row
  # could be hidden from remediation without being reapable.
  describe ".abandoned? agrees with .abandoned_relation" do
    it "on every arm" do
      pool = System::InstancePool.create!(
        account: account, node_template: template, name: "pool-#{SecureRandom.hex(3)}",
        target_size: 1, min_size: 0, max_size: 3, lifecycle_class: "ephemeral", status: "active"
      )
      rows = {
        abandoned_starting: instance(status: "starting"),
        abandoned_never_enrolled: instance(status: "error", heartbeat: nil, created: 20.days.ago),
        fresh_heartbeat: instance(heartbeat: 1.hour.ago),
        young_never_enrolled: instance(heartbeat: nil, created: 1.day.ago),
        pooled: instance(status: "error", instance_pool_id: pool.id, pool_state: "errored"),
        physical: instance(status: "stopped", variety: "physical"),
        provisioning: instance(status: "provisioning"),
        terminated: instance(status: "terminated")
      }
      held = instance(status: "error")
      held.update_columns(ops_hold_at: 1.day.ago)
      rows[:held] = held
      rows[:no_identity] = instance(status: "error", cloud_instance_id: nil)
      rows[:guest_lost] = instance(status: "error", cloud_instance_id: nil,
                                   config: { "provider_guest_lost_at" => 10.days.ago.iso8601 })
      replacing = instance(status: "error")
      System::FleetEvent.create!(account: account, kind: "system.instance_replace.acquire_replacement",
                                 severity: "low", node_instance_id: replacing.id, emitted_at: 1.day.ago,
                                 payload: { "failed_instance_id" => replacing.id })
      rows[:replace_in_flight] = replacing
      self_node = create(:system_node, account: account, node_template: template)
      rows[:self_hosted] = instance(status: "error", owner_node: self_node)
      rows[:blank_identity] = instance(status: "error", cloud_instance_id: "")
      vip_holder = instance(status: "error")
      holder_peer = create(:sdwan_peer, account: account, node_instance: vip_holder)
      create(:sdwan_virtual_ip, network: holder_peer.network, account: account, holder_peer_ids: [ holder_peer.id ])
      rows[:vip_holder] = vip_holder
      vip_failover = instance(status: "error")
      failover_peer = create(:sdwan_peer, account: account, node_instance: vip_failover)
      create(:sdwan_virtual_ip, network: failover_peer.network, account: account,
                                failover_holder_peer_ids: [ failover_peer.id ])
      rows[:vip_failover] = vip_failover
      ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, self_node.id)

      in_sql = described_class.abandoned_relation(account: account).pluck(:id).to_set
      rows.each do |label, row|
        expect(described_class.abandoned?(row.reload, account: account)).to eq(in_sql.include?(row.id)),
          "#{label}: predicate and relation disagree"
      end
      expect(in_sql).to eq([ rows[:abandoned_starting].id, rows[:abandoned_never_enrolled].id,
                             rows[:guest_lost].id, rows[:vip_holder].id, rows[:vip_failover].id ].to_set)
    end
  end
end
