# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::InstancePoolService, type: :service do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  let(:pool) do
    System::InstancePool.create!(
      account: account,
      node_template: node_template,
      name: "test-pool",
      target_size: 3,
      min_size: 1,
      max_size: 5,
      lifecycle_class: "ephemeral",
      status: "active",
      provider_region: provider_region,
      provider_instance_type: provider_instance_type
    )
  end

  # Helper — seed a fully-warm pool member at a given state, bypassing
  # the standard provisioning flow (which would dispatch worker jobs).
  def seed_pool_member(state:, warming_started_at: 1.minute.ago, acquired_at: nil, last_heartbeat_at: nil)
    node = create(:system_node, account: account, node_template: node_template,
                                 lifecycle_class: "ephemeral")
    create(:system_node_instance,
           node: node,
           name: "member-#{SecureRandom.hex(3)}",
           variety: "cloud",
           status: state == "ready" ? "running" : "pending",
           provider_region: provider_region,
           provider_instance_type: provider_instance_type,
           instance_pool_id: pool.id,
           pool_state: state,
           pool_warming_started_at: warming_started_at,
           pool_acquired_at: acquired_at,
           last_heartbeat_at: last_heartbeat_at)
  end

  describe ".acquire!" do
    context "when pool has ready members" do
      let!(:older) { seed_pool_member(state: "ready", warming_started_at: 5.minutes.ago) }
      let!(:newer) { seed_pool_member(state: "ready", warming_started_at: 1.minute.ago) }

      it "claims the oldest ready member (FIFO)" do
        member = described_class.acquire!(account: account, pool_name: "test-pool")
        expect(member.id).to eq(older.id)
      end

      it "transitions claimed member to pool_state=claimed + sets pool_acquired_at" do
        member = described_class.acquire!(account: account, pool_name: "test-pool")
        expect(member.reload.pool_state).to eq("claimed")
        expect(member.pool_acquired_at).to be_within(2.seconds).of(Time.current)
      end

      it "consecutive acquires return different members" do
        first = described_class.acquire!(account: account, pool_name: "test-pool")
        second = described_class.acquire!(account: account, pool_name: "test-pool")
        expect(first.id).not_to eq(second.id)
      end
    end

    context "when pool has no ready members" do
      before { seed_pool_member(state: "warming") }

      it "raises NoReadyMembersError" do
        expect {
          described_class.acquire!(account: account, pool_name: "test-pool")
        }.to raise_error(System::InstancePoolService::NoReadyMembersError)
      end
    end

    context "when pool name doesn't exist" do
      it "raises PoolError" do
        expect {
          described_class.acquire!(account: account, pool_name: "missing-pool")
        }.to raise_error(System::InstancePoolService::PoolError, /not found/)
      end
    end

    context "when pool is paused" do
      before { pool.update!(status: "paused"); seed_pool_member(state: "ready") }

      it "raises PoolNotActiveError" do
        expect {
          described_class.acquire!(account: account, pool_name: "test-pool")
        }.to raise_error(System::InstancePoolService::PoolNotActiveError)
      end
    end

    context "when pool is draining (F2-02)" do
      # drain! terminates all ready members immediately, so any member
      # still acquirable from a draining pool only exists via the
      # drain/acquire race or a warming member that ripened post-drain —
      # both of which must not be handed to an agent.
      before { pool.update!(status: "draining"); seed_pool_member(state: "ready") }

      it "raises PoolNotActiveError instead of handing out a member being drained" do
        expect {
          described_class.acquire!(account: account, pool_name: "test-pool")
        }.to raise_error(System::InstancePoolService::PoolNotActiveError)
      end
    end

    context "fallback by lifecycle_class" do
      let!(:other_pool) do
        System::InstancePool.create!(
          account: account, node_template: node_template,
          name: "other-pool", target_size: 1, min_size: 0, max_size: 2,
          lifecycle_class: "ephemeral", status: "active"
        )
      end

      it "finds any active pool with ready members of matching lifecycle_class" do
        # Seed ready in test-pool, not other-pool
        seed_pool_member(state: "ready")

        member = described_class.acquire!(account: account, lifecycle_class: "ephemeral")
        expect(member.instance_pool_id).to eq(pool.id)
      end

      it "raises NoReadyMembersError when no pool has ready members" do
        expect {
          described_class.acquire!(account: account, lifecycle_class: "ephemeral")
        }.to raise_error(System::InstancePoolService::NoReadyMembersError)
      end
    end
  end

  describe ".replenish!" do
    context "when pool is below target" do
      it "computes deficit correctly" do
        seed_pool_member(state: "ready") # 1 ready
        seed_pool_member(state: "warming") # 1 warming
        # target=3, ready+warming=2, deficit=1
        expect(pool.deficit).to eq(1)
      end

      # The replenish path calls ProvisioningService.provision_instance
      # synchronously per deficit slot (see instance_pool_service.rb:251
      # comment — the old WorkerDispatch async path was broken on three
      # layers). In specs we don't want to exercise the real cloud
      # adapter chain, so stub ProvisioningService to return a successful
      # Runtime::Result with a stubbed NodeInstance per call.
      before do
        allow(::System::ProvisioningService).to receive(:provision_instance) do |node:, **|
          stub_instance = create(:system_node_instance,
                                  node: node,
                                  name: "warming-#{SecureRandom.hex(3)}",
                                  variety: "cloud",
                                  status: "pending",
                                  provider_region: provider_region,
                                  provider_instance_type: provider_instance_type)
          ::System::Runtime::Result.ok(data: { instance: stub_instance })
        end
      end

      it "provisions deficit slots via ProvisioningService" do
        result = described_class.replenish!(pool: pool)
        expect(result[:deficit]).to eq(3)
        expect(result[:provisioned]).to eq(3)
        expect(pool.reload.warming_count).to eq(3)
      end

      it "stamps pool.last_replenished_at after successful replenish" do
        described_class.replenish!(pool: pool)
        expect(pool.reload.last_replenished_at).to be_within(2.seconds).of(Time.current)
      end
    end

    context "when pool is at capacity" do
      it "no-ops when ready+warming >= target_size" do
        3.times { seed_pool_member(state: "ready") }
        result = described_class.replenish!(pool: pool)
        expect(result[:deficit]).to eq(0)
        expect(result[:provisioned]).to eq(0)
      end
    end

    context "when pool is paused" do
      before { pool.update!(status: "paused") }

      it "raises PoolNotActiveError" do
        expect {
          described_class.replenish!(pool: pool)
        }.to raise_error(System::InstancePoolService::PoolNotActiveError)
      end
    end
  end

  describe ".drain!" do
    let!(:ready_a) { seed_pool_member(state: "ready") }
    let!(:ready_b) { seed_pool_member(state: "ready") }
    let!(:claimed) { seed_pool_member(state: "claimed") }

    it "transitions pool to draining + ready members to draining state" do
      result = described_class.drain!(pool: pool)
      expect(pool.reload.status).to eq("draining")
      expect(ready_a.reload.pool_state).to eq("draining")
      expect(ready_b.reload.pool_state).to eq("draining")
      expect(result[:drained]).to eq(2)
    end

    it "leaves claimed members untouched (operator finishes their work)" do
      described_class.drain!(pool: pool)
      expect(claimed.reload.pool_state).to eq("claimed")
    end

    # F2-02 — drain! must not clobber a member a concurrent acquire!
    # claimed after drain's ready snapshot was taken. Deterministic
    # interleaving: the terminate_instance stub fires mid-iteration and
    # claims the OTHER ready member, simulating an agent acquiring it
    # between drain's member list and drain reaching that member.
    context "racing a concurrent acquire (F2-02)" do
      before do
        allow(::System::ProvisioningService).to receive(:terminate_instance) do |instance:|
          other = [ ready_a, ready_b ].find { |m| m.id != instance.id }
          if other && other.reload.pool_state == "ready"
            other.update!(pool_state: "claimed", pool_acquired_at: Time.current)
          end
          true
        end
      end

      it "does not clobber or terminate the member claimed mid-drain" do
        result = described_class.drain!(pool: pool)

        states = [ ready_a.reload.pool_state, ready_b.reload.pool_state ].sort
        expect(states).to eq(%w[claimed draining])
        expect(::System::ProvisioningService).to have_received(:terminate_instance).once
        expect(result[:drained]).to eq(1)
      end
    end
  end

  describe ".recycle_stale_members!" do
    it "transitions stale warming members to errored" do
      m = seed_pool_member(state: "warming", warming_started_at: 2.hours.ago)
      result = described_class.recycle_stale_members!(pool: pool)
      expect(m.reload.pool_state).to eq("errored")
      expect(result[:warming_to_errored]).to eq(1)
    end

    it "transitions stale ready members to draining" do
      m = seed_pool_member(state: "ready", warming_started_at: 5.hours.ago)
      result = described_class.recycle_stale_members!(pool: pool)
      expect(m.reload.pool_state).to eq("draining")
      expect(result[:ready_to_draining]).to eq(1)
    end

    it "does not touch fresh members" do
      m = seed_pool_member(state: "warming", warming_started_at: 5.minutes.ago)
      described_class.recycle_stale_members!(pool: pool)
      expect(m.reload.pool_state).to eq("warming")
    end

    it "respects per-pool warming_timeout_seconds metadata override" do
      pool.update!(metadata: { "warming_timeout_seconds" => 60 }) # 1min
      m = seed_pool_member(state: "warming", warming_started_at: 2.minutes.ago)
      described_class.recycle_stale_members!(pool: pool)
      expect(m.reload.pool_state).to eq("errored")
    end

    # Audit F1-10 — claimed members had no TTL: a consumer that crashed
    # after acquire! leaked the member forever, and because replenish!
    # counts claimed members against max_size headroom, each leak
    # permanently shrank the pool's effective capacity.
    context "stale claimed members (F1-10)" do
      it "flags a claimed member past claimed_ttl and emits a fleet event, without terminating it" do
        m = seed_pool_member(state: "claimed", warming_started_at: 25.hours.ago,
                             acquired_at: 25.hours.ago)
        allow(::System::ProvisioningService).to receive(:terminate_instance)

        result = described_class.recycle_stale_members!(pool: pool)

        expect(result[:claimed_flagged]).to eq(1)
        m.reload
        expect(m.pool_state).to eq("claimed") # operator decision, not auto-terminate
        expect(m.config["pool_claimed_stale_flagged_at"]).to be_present
        expect(::System::ProvisioningService).not_to have_received(:terminate_instance)

        event = System::FleetEvent.where(account: account, kind: "system.pool.claimed_stale").last
        expect(event).to be_present
        expect(event.node_instance_id).to eq(m.id)
      end

      it "does not flag claimed members within claimed_ttl" do
        m = seed_pool_member(state: "claimed", warming_started_at: 1.hour.ago,
                             acquired_at: 1.hour.ago)

        result = described_class.recycle_stale_members!(pool: pool)

        expect(result[:claimed_flagged]).to eq(0)
        expect(m.reload.config["pool_claimed_stale_flagged_at"]).to be_nil
      end

      it "does not re-emit for a claim already flagged this cycle" do
        seed_pool_member(state: "claimed", warming_started_at: 25.hours.ago,
                         acquired_at: 25.hours.ago)
        described_class.recycle_stale_members!(pool: pool)

        result = described_class.recycle_stale_members!(pool: pool)

        expect(result[:claimed_flagged]).to eq(0)
        expect(System::FleetEvent.where(account: account, kind: "system.pool.claimed_stale").count).to eq(1)
      end

      it "respects per-pool claimed_ttl_seconds metadata override" do
        pool.update!(metadata: { "claimed_ttl_seconds" => 60 })
        m = seed_pool_member(state: "claimed", warming_started_at: 5.minutes.ago,
                             acquired_at: 5.minutes.ago)

        result = described_class.recycle_stale_members!(pool: pool)

        expect(result[:claimed_flagged]).to eq(1)
        expect(m.reload.pool_state).to eq("claimed")
      end
    end

    # A4 — pool-side glue composing NodeInstance#stale_heartbeat? with the
    # existing TTL-driven recycle paths: a member whose on-node agent has
    # stopped heartbeating gets reaped even while still within its TTL
    # window.
    context "stale on-node agent heartbeat" do
      it "does not recycle a ready member with a fresh heartbeat" do
        m = seed_pool_member(state: "ready", warming_started_at: 1.minute.ago,
                             last_heartbeat_at: 30.seconds.ago)
        described_class.recycle_stale_members!(pool: pool)
        expect(m.reload.pool_state).to eq("ready")
      end

      it "recycles a ready member with a stale heartbeat even within its ready TTL" do
        m = seed_pool_member(state: "ready", warming_started_at: 1.minute.ago,
                             last_heartbeat_at: 5.minutes.ago)
        allow(::System::ProvisioningService).to receive(:terminate_instance)

        result = described_class.recycle_stale_members!(pool: pool)

        expect(m.reload.pool_state).to eq("draining")
        expect(result[:ready_to_draining]).to eq(1)
        expect(::System::ProvisioningService).to have_received(:terminate_instance).with(instance: m)

        # Observability parity with the claimed-flag event — surfaces a
        # heartbeat-driven ready recycle distinctly from a plain ready_ttl one.
        event = System::FleetEvent.where(account: account, kind: "system.pool.ready_stale_heartbeat_recycled").last
        expect(event).to be_present
        expect(event.node_instance_id).to eq(m.id)
      end

      it "flags (not terminates) a claimed member with a stale heartbeat, same as the claimed_ttl path" do
        m = seed_pool_member(state: "claimed", warming_started_at: 5.minutes.ago,
                             acquired_at: 5.minutes.ago, last_heartbeat_at: 5.minutes.ago)
        allow(::System::ProvisioningService).to receive(:terminate_instance)

        result = described_class.recycle_stale_members!(pool: pool)

        expect(m.reload.pool_state).to eq("claimed") # never auto-terminated
        expect(result[:claimed_heartbeat_flagged]).to eq(1)
        expect(result[:claimed_flagged]).to eq(0) # within claimed_ttl — flagged via the heartbeat path, not the TTL path
        expect(m.config["pool_claimed_stale_flagged_at"]).to be_present
        expect(::System::ProvisioningService).not_to have_received(:terminate_instance)

        event = System::FleetEvent.where(account: account, kind: "system.pool.claimed_stale_heartbeat_flagged").last
        expect(event).to be_present
        expect(event.node_instance_id).to eq(m.id)
      end

      it "does not recycle a warming member with no heartbeat — still governed by warming TTL" do
        m = seed_pool_member(state: "warming", warming_started_at: 5.minutes.ago, last_heartbeat_at: nil)
        described_class.recycle_stale_members!(pool: pool)
        expect(m.reload.pool_state).to eq("warming")
      end

      it "does not recycle a ready member that has never heartbeated" do
        m = seed_pool_member(state: "ready", warming_started_at: 1.minute.ago, last_heartbeat_at: nil)
        described_class.recycle_stale_members!(pool: pool)
        expect(m.reload.pool_state).to eq("ready")
      end

      it "is disabled via pool.metadata[reap_on_stale_heartbeat] = false" do
        pool.update!(metadata: { "reap_on_stale_heartbeat" => false })
        ready = seed_pool_member(state: "ready", warming_started_at: 1.minute.ago,
                                 last_heartbeat_at: 10.minutes.ago)
        claimed = seed_pool_member(state: "claimed", warming_started_at: 5.minutes.ago,
                                   acquired_at: 5.minutes.ago, last_heartbeat_at: 10.minutes.ago)

        result = described_class.recycle_stale_members!(pool: pool)

        expect(ready.reload.pool_state).to eq("ready")
        expect(claimed.reload.pool_state).to eq("claimed")
        expect(result[:claimed_heartbeat_flagged]).to eq(0)
      end

      it "is disabled via pool.metadata[reap_on_stale_heartbeat] = \"false\" (JSON string form)" do
        pool.update!(metadata: { "reap_on_stale_heartbeat" => "false" })
        ready = seed_pool_member(state: "ready", warming_started_at: 1.minute.ago,
                                 last_heartbeat_at: 10.minutes.ago)
        claimed = seed_pool_member(state: "claimed", warming_started_at: 5.minutes.ago,
                                   acquired_at: 5.minutes.ago, last_heartbeat_at: 10.minutes.ago)

        result = described_class.recycle_stale_members!(pool: pool)

        expect(ready.reload.pool_state).to eq("ready")
        expect(claimed.reload.pool_state).to eq("claimed")
        expect(result[:claimed_heartbeat_flagged]).to eq(0)
      end

      it "respects per-pool heartbeat_stale_after_seconds metadata override" do
        pool.update!(metadata: { "heartbeat_stale_after_seconds" => 30 })
        m = seed_pool_member(state: "ready", warming_started_at: 1.minute.ago,
                             last_heartbeat_at: 45.seconds.ago)
        allow(::System::ProvisioningService).to receive(:terminate_instance)

        described_class.recycle_stale_members!(pool: pool)

        expect(m.reload.pool_state).to eq("draining")
      end

      # Coercion (HIGH) — a garbage or non-positive heartbeat_stale_after_seconds
      # override must fall back to the built-in default rather than being taken
      # literally as a threshold of ~0 seconds, which would treat virtually every
      # heartbeated member as stale.
      context "heartbeat_stale_after_seconds coercion" do
        it "falls back to the default when the override is a non-numeric string" do
          pool.update!(metadata: { "heartbeat_stale_after_seconds" => "abc" })
          # Fresher than the 3min default, but would be "stale" under a
          # buggy ~0-second threshold.
          m = seed_pool_member(state: "ready", warming_started_at: 1.minute.ago,
                               last_heartbeat_at: 30.seconds.ago)

          described_class.recycle_stale_members!(pool: pool)

          expect(m.reload.pool_state).to eq("ready")
        end

        it "falls back to the default when the override is literal 0" do
          pool.update!(metadata: { "heartbeat_stale_after_seconds" => 0 })
          m = seed_pool_member(state: "ready", warming_started_at: 1.minute.ago,
                               last_heartbeat_at: 30.seconds.ago)

          described_class.recycle_stale_members!(pool: pool)

          expect(m.reload.pool_state).to eq("ready")
        end

        it "falls back to the default when the override is negative" do
          pool.update!(metadata: { "heartbeat_stale_after_seconds" => -30 })
          m = seed_pool_member(state: "ready", warming_started_at: 1.minute.ago,
                               last_heartbeat_at: 30.seconds.ago)

          described_class.recycle_stale_members!(pool: pool)

          expect(m.reload.pool_state).to eq("ready")
        end
      end

      # Coercion (HIGH) — reap_on_stale_heartbeat must never raise, even when
      # it holds a boolean false (a naive `.to_i` coercion on that value would
      # raise NoMethodError and kill every recycle phase in the transaction).
      it "never raises when reap_on_stale_heartbeat is boolean false" do
        pool.update!(metadata: { "reap_on_stale_heartbeat" => false })
        seed_pool_member(state: "warming", warming_started_at: 2.hours.ago)

        expect {
          described_class.recycle_stale_members!(pool: pool)
        }.not_to raise_error
      end
    end

    # F2-02 — same race as drain!: the reaper runs this every 60s, so a
    # stale-but-ready member acquired mid-tick must not be recycled out
    # from under the agent that just claimed it.
    context "racing a concurrent acquire (F2-02)" do
      let!(:stale_a) { seed_pool_member(state: "ready", warming_started_at: 5.hours.ago) }
      let!(:stale_b) { seed_pool_member(state: "ready", warming_started_at: 6.hours.ago) }

      before do
        allow(::System::ProvisioningService).to receive(:terminate_instance) do |instance:|
          other = [ stale_a, stale_b ].find { |m| m.id != instance.id }
          if other && other.reload.pool_state == "ready"
            other.update!(pool_state: "claimed", pool_acquired_at: Time.current)
          end
          true
        end
      end

      it "does not recycle the member claimed mid-tick" do
        result = described_class.recycle_stale_members!(pool: pool)

        states = [ stale_a.reload.pool_state, stale_b.reload.pool_state ].sort
        expect(states).to eq(%w[claimed draining])
        expect(::System::ProvisioningService).to have_received(:terminate_instance).once
        expect(result[:ready_to_draining]).to eq(1)
      end
    end
  end

  # Reaper-driven deferred cloud-init seed reload for Proxmox uefi_disk
  # builders — the retry loop that replaced the ineffective immediate
  # in-create power cycle (create_uefi_disk_vm_instance used to call
  # reload_cloudinit_seed! once, synchronously, right after finalize_create;
  # PVE task-log evidence showed that fired ~8s into boot, mid-UEFI, long
  # before the cicustom seed ever materializes, so it never worked). See
  # System::Providers::ProxmoxProvider#power_cycle_instance for the provider
  # side this delegates to.
  describe ".reload_pending_seeds!" do
    let(:provider_double) { instance_double(System::Providers::ProxmoxProvider, power_cycle_instance: true) }

    # Seeds a warming member with a cloud_instance_id already present (VM
    # created) — the minimum shape reload_pending_seeds! considers.
    def seed_warming_with_cloud_id(warming_started_at:, last_heartbeat_at: nil, config_extra: {})
      m = seed_pool_member(state: "warming", warming_started_at: warming_started_at,
                           last_heartbeat_at: last_heartbeat_at)
      m.update!(config: m.config.merge({ "cloud_instance_id" => "dna/qemu/#{SecureRandom.hex(3)}" }.merge(config_extra)))
      m
    end

    before do
      allow(::System::Providers::Registry).to receive(:for_instance).and_return(provider_double)
    end

    it "power-cycles an eligible warming member (never enrolled, past seed_reload_after, cloud VM exists) and records the attempt" do
      m = seed_warming_with_cloud_id(warming_started_at: 3.minutes.ago)
      cloud_instance_id = m.config["cloud_instance_id"]

      count = described_class.reload_pending_seeds!(pool: pool)

      expect(count).to eq(1)
      expect(provider_double).to have_received(:power_cycle_instance).with(cloud_instance_id)
      expect(m.reload.config["seed_reload_count"]).to eq(1)
      expect(m.config["last_seed_reload_at"]).to be_present
    end

    it "(a) does not cycle a member that already has a heartbeat" do
      m = seed_warming_with_cloud_id(warming_started_at: 3.minutes.ago, last_heartbeat_at: 1.minute.ago)

      count = described_class.reload_pending_seeds!(pool: pool)

      expect(count).to eq(0)
      expect(provider_double).not_to have_received(:power_cycle_instance)
      expect(m.reload.config["seed_reload_count"]).to be_nil
    end

    it "(b) does not cycle a member younger than seed_reload_after (default 120s)" do
      m = seed_warming_with_cloud_id(warming_started_at: 10.seconds.ago)

      count = described_class.reload_pending_seeds!(pool: pool)

      expect(count).to eq(0)
      expect(provider_double).not_to have_received(:power_cycle_instance)
      expect(m.reload.config["seed_reload_count"]).to be_nil
    end

    it "(c) does not re-cycle a member cycled within seed_reload_interval (default 240s)" do
      m = seed_warming_with_cloud_id(
        warming_started_at: 10.minutes.ago,
        config_extra: { "seed_reload_count" => 1, "last_seed_reload_at" => 30.seconds.ago.iso8601 }
      )

      count = described_class.reload_pending_seeds!(pool: pool)

      expect(count).to eq(0)
      expect(provider_double).not_to have_received(:power_cycle_instance)
      expect(m.reload.config["seed_reload_count"]).to eq(1)
    end

    it "(d) does not cycle a member that has hit seed_reload_max (default 6)" do
      m = seed_warming_with_cloud_id(
        warming_started_at: 10.minutes.ago,
        config_extra: { "seed_reload_count" => 6, "last_seed_reload_at" => 1.hour.ago.iso8601 }
      )

      count = described_class.reload_pending_seeds!(pool: pool)

      expect(count).to eq(0)
      expect(provider_double).not_to have_received(:power_cycle_instance)
      expect(m.reload.config["seed_reload_count"]).to eq(6)
    end

    it "does not cycle a warming member with no cloud_instance_id yet (VM not created)" do
      m = seed_pool_member(state: "warming", warming_started_at: 3.minutes.ago)

      count = described_class.reload_pending_seeds!(pool: pool)

      expect(count).to eq(0)
      expect(provider_double).not_to have_received(:power_cycle_instance)
      expect(m.reload.config["seed_reload_count"]).to be_nil
    end

    it "skips a member whose resolved provider doesn't support power_cycle_instance (non-proxmox)" do
      m = seed_warming_with_cloud_id(warming_started_at: 3.minutes.ago)
      allow(::System::Providers::Registry).to receive(:for_instance).with(m).and_return(double("NonProxmoxProvider"))

      count = described_class.reload_pending_seeds!(pool: pool)

      expect(count).to eq(0)
      expect(m.reload.config["seed_reload_count"]).to be_nil
    end

    it "skips (without raising) a member with no resolvable provider connection" do
      m = seed_warming_with_cloud_id(warming_started_at: 3.minutes.ago)
      allow(::System::Providers::Registry).to receive(:for_instance).with(m)
        .and_raise(System::Providers::Registry::UnknownProviderError, "no connection")

      expect { described_class.reload_pending_seeds!(pool: pool) }.not_to raise_error
      expect(m.reload.config["seed_reload_count"]).to be_nil
    end

    it "logs + continues when power_cycle_instance raises for one member, without blocking the others" do
      failing = seed_warming_with_cloud_id(warming_started_at: 3.minutes.ago)
      healthy = seed_warming_with_cloud_id(warming_started_at: 3.minutes.ago)
      failing_cloud_id = failing.config["cloud_instance_id"]
      allow(provider_double).to receive(:power_cycle_instance) do |cloud_id|
        raise Timeout::Error, "PVE unreachable" if cloud_id == failing_cloud_id
      end

      count = described_class.reload_pending_seeds!(pool: pool)

      expect(count).to eq(1)
      expect(failing.reload.config["seed_reload_count"]).to be_nil
      expect(healthy.reload.config["seed_reload_count"]).to eq(1)
    end

    it "respects a SiteSetting override for seed_reload_after_seconds" do
      allow(::SiteSetting).to receive(:get).and_call_original
      allow(::SiteSetting).to receive(:get).with("system.ci_builder.seed_reload_after_seconds").and_return("30")
      m = seed_warming_with_cloud_id(warming_started_at: 45.seconds.ago)

      count = described_class.reload_pending_seeds!(pool: pool)

      expect(count).to eq(1)
      expect(m.reload.config["seed_reload_count"]).to eq(1)
    end

    # The power cycle is a slow external PVE call; running it inside
    # recycle_stale_members!'s FOR UPDATE transaction would serialize
    # unrelated pool operations (acquire!, other reaper phases) behind it.
    it "runs power_cycle_instance calls BEFORE recycle_stale_members!'s FOR UPDATE transaction opens (no added lock contention)" do
      seed_warming_with_cloud_id(warming_started_at: 3.minutes.ago)
      baseline = ::ActiveRecord::Base.connection.open_transactions
      observed = nil
      allow(provider_double).to receive(:power_cycle_instance) do
        observed = ::ActiveRecord::Base.connection.open_transactions
      end

      described_class.recycle_stale_members!(pool: pool)

      expect(observed).to eq(baseline)
    end

    it "folds the cycled count into recycle_stale_members!'s returned counts under :seed_reloads" do
      seed_warming_with_cloud_id(warming_started_at: 3.minutes.ago)

      result = described_class.recycle_stale_members!(pool: pool)

      expect(result[:seed_reloads]).to eq(1)
    end
  end
end

RSpec.describe System::InstancePool, type: :model do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:pool) do
    described_class.create!(
      account: account,
      node_template: node_template,
      name: "p1",
      target_size: 2,
      min_size: 0,
      max_size: 4,
      lifecycle_class: "ephemeral"
    )
  end

  describe "validations" do
    it "rejects max_size < target_size" do
      pool.max_size = 1
      pool.target_size = 5
      expect(pool).not_to be_valid
      expect(pool.errors[:max_size]).to include("must be >= target_size")
    end

    it "rejects target_size < min_size" do
      pool.min_size = 5
      pool.target_size = 1
      expect(pool).not_to be_valid
      expect(pool.errors[:target_size]).to include("must be >= min_size")
    end

    it "rejects invalid lifecycle_class" do
      pool.lifecycle_class = "persistent"
      expect(pool).not_to be_valid
    end

    it "name uniqueness scoped to account" do
      other = create(:account)
      described_class.create!(account: other, node_template: node_template,
                              name: "p1", target_size: 0, min_size: 0, max_size: 0,
                              lifecycle_class: "ephemeral")
      expect(pool).to be_valid
    end
  end

  describe "DB-level constraints" do
    it "rejects negative target_size at the DB layer" do
      pool.save!
      # Negative target_size violates both target_size_nonneg AND target_gte_min;
      # PG fires the first matching constraint. Match either to be tolerant.
      expect {
        pool.update_column(:target_size, -1)
      }.to raise_error(ActiveRecord::CheckViolation, /chk_instance_pools_(target_size_nonneg|target_gte_min)/)
    end

    it "rejects unknown status at the DB layer" do
      pool.save!
      expect {
        pool.update_column(:status, "unknown")
      }.to raise_error(ActiveRecord::CheckViolation, /chk_instance_pools_status/)
    end
  end

  describe "deficit + surplus" do
    it "deficit = target_size - (ready + warming)" do
      pool.save!
      expect(pool.deficit).to eq(2)

      node = create(:system_node, account: account, node_template: node_template)
      create(:system_node_instance,
             node: node, name: "m", variety: "cloud", status: "running",
             instance_pool_id: pool.id, pool_state: "warming",
             pool_warming_started_at: 1.minute.ago)
      expect(pool.deficit).to eq(1)
    end
  end

  describe "to_summary" do
    it "returns operator-facing fields" do
      pool.save!
      summary = pool.to_summary
      expect(summary).to include(
        :id, :name, :status, :lifecycle_class,
        :target_size, :min_size, :max_size,
        :ready_count, :warming_count, :claimed_count, :errored_count,
        :deficit, :last_replenished_at
      )
    end
  end
end

RSpec.describe System::NodeInstance, "pool methods (slice 7)", type: :model do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }

  describe "pool predicates" do
    it "in_pool? returns true when instance_pool_id is set" do
      pool = create(:system_node_template, account: account).then do |t|
        System::InstancePool.create!(account: account, node_template: t,
                                     name: "p", target_size: 0, min_size: 0, max_size: 0,
                                     lifecycle_class: "ephemeral")
      end
      i = create(:system_node_instance, node: node, instance_pool_id: pool.id, pool_state: "ready")
      expect(i.in_pool?).to be true
      expect(i.pool_ready?).to be true
      expect(i.pool_claimed?).to be false
    end

    it "non-pool instance has all pool predicates false" do
      i = create(:system_node_instance, node: node)
      expect(i.in_pool?).to be false
      expect(i.pool_ready?).to be false
    end
  end

  describe "mark_pool_ready!" do
    let(:pool) do
      template = create(:system_node_template, account: account)
      System::InstancePool.create!(account: account, node_template: template,
                                   name: "p", target_size: 0, min_size: 0, max_size: 0,
                                   lifecycle_class: "ephemeral")
    end

    it "transitions warming → ready" do
      i = create(:system_node_instance, node: node,
                 instance_pool_id: pool.id, pool_state: "warming")
      expect(i.mark_pool_ready!).to be true
      expect(i.reload.pool_state).to eq("ready")
    end

    it "is idempotent — already-ready returns false without error" do
      i = create(:system_node_instance, node: node,
                 instance_pool_id: pool.id, pool_state: "ready")
      expect(i.mark_pool_ready!).to be false
      expect(i.reload.pool_state).to eq("ready")
    end

    it "non-pool instance returns false" do
      i = create(:system_node_instance, node: node)
      expect(i.mark_pool_ready!).to be false
    end
  end

  describe "DB-level pool_state CHECK constraint" do
    it "rejects pool_state without instance_pool_id (consistency violation)" do
      i = create(:system_node_instance, node: node)
      expect {
        i.update_columns(pool_state: "ready")
      }.to raise_error(ActiveRecord::CheckViolation, /chk_node_instances_pool_consistency/)
    end

    it "rejects unknown pool_state value" do
      template = create(:system_node_template, account: account)
      pool = System::InstancePool.create!(
        account: account, node_template: template,
        name: "p", target_size: 0, min_size: 0, max_size: 0,
        lifecycle_class: "ephemeral"
      )
      i = create(:system_node_instance, node: node,
                 instance_pool_id: pool.id, pool_state: "ready")
      expect {
        i.update_columns(pool_state: "bogus_state")
      }.to raise_error(ActiveRecord::CheckViolation, /chk_node_instances_pool_state/)
    end
  end
end
