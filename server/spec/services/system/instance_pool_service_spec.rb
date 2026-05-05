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
  def seed_pool_member(state:, warming_started_at: 1.minute.ago)
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
           pool_warming_started_at: warming_started_at)
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

      it "no-ops cleanly when worker dispatch is unavailable (missing WorkerDispatch class)" do
        # WorkerDispatch is not loaded in test env; provision step is best-effort.
        result = described_class.replenish!(pool: pool)
        expect(result[:deficit]).to eq(3)
        # Even without worker dispatch, the placeholder NodeInstance + Node rows are created.
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
