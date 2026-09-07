# frozen_string_literal: true

require "rails_helper"

# IMP-787c95be55a0 — #acquire! selected the OLDEST ready member with no
# liveness input at all:
#
#     pool.node_instances.where(pool_state: "ready")
#         .order(Arel.sql("pool_warming_started_at NULLS LAST"))
#         .lock("FOR UPDATE SKIP LOCKED").first
#
# Ordering ascending by the warming anchor means the member most likely to
# have gone silent while sitting in the pool is the one handed out FIRST. Two
# on-node task producers (FulfillmentAdvanceOrchestrator#ensure_template_applied!
# and ModuleSmokeVerifyExecutor#compose_pairing!) were left ungated in
# spec/lint/on_node_task_producer_census_spec.rb on the reasoning that each
# targets an instance the same flow just provisioned — true of the
# fresh_provision branch, and false of the pool branch that runs BEFORE it
# (and absent entirely on the smoke executor's standalone path).
#
# The reaper's heartbeat arm does not close this: it is asynchronous (it races
# acquire!) and, by its own comment, EXCLUDES members that have never
# heartbeated.
RSpec.describe "System::InstancePoolService#acquire! liveness gate", type: :service do
  let(:account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  let(:pool) do
    System::InstancePool.create!(
      account: account,
      node_template: node_template,
      name: "liveness-pool",
      target_size: 3,
      min_size: 1,
      max_size: 5,
      lifecycle_class: "ephemeral",
      status: "active",
      provider_region: provider_region,
      provider_instance_type: provider_instance_type
    )
  end

  # A ready member as production actually produces one: NodeInstance
  # #mark_pool_ready! is reached ONLY from #promote_pool_ready!, whose sole
  # caller is the agent heartbeat endpoint — so a ready member has always
  # reported at least once. `last_heartbeat_at` is therefore a required
  # argument here rather than a defaulted one: an example must SAY which
  # liveness shape it is seeding.
  def seed_ready(last_heartbeat_at:, warming_started_at: 1.minute.ago, status: "running")
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance,
           node: node,
           name: "member-#{SecureRandom.hex(3)}",
           variety: "cloud",
           status: status,
           provider_region: provider_region,
           provider_instance_type: provider_instance_type,
           instance_pool_id: pool.id,
           pool_state: "ready",
           pool_warming_started_at: warming_started_at,
           last_heartbeat_at: last_heartbeat_at)
  end

  def acquire
    described_class = System::InstancePoolService
    described_class.acquire!(account: account, pool_name: "liveness-pool")
  end

  describe "a silent member is skipped rather than handed out" do
    # The silent one is OLDER, so FIFO alone would pick it.
    let!(:silent) do
      seed_ready(last_heartbeat_at: 30.minutes.ago, warming_started_at: 20.minutes.ago)
    end
    let!(:live) do
      seed_ready(last_heartbeat_at: 10.seconds.ago, warming_started_at: 1.minute.ago)
    end

    it "hands out the live member even though the silent one sorts first" do
      expect(acquire.id).to eq(live.id)
    end

    it "leaves the silent member ready rather than claiming it" do
      acquire
      expect(silent.reload.pool_state).to eq("ready")
      expect(silent.pool_acquired_at).to be_nil
    end

    it "opens no claim ledger record for the skipped member" do
      acquire
      expect(
        System::FleetEvent.where(node_instance_id: silent.id,
                                 kind: System::InstancePoolService::CLAIM_EVENT_KIND)
      ).to be_empty
    end
  end

  describe "when every ready member is silent" do
    let!(:silent) { seed_ready(last_heartbeat_at: 45.minutes.ago) }

    it "refuses rather than handing one out" do
      expect { acquire }
        .to raise_error(System::InstancePoolService::NoLiveReadyMembersError, /went silent/)
    end

    it "refuses through a subclass of NoReadyMembersError so existing rescues still catch it" do
      expect(System::InstancePoolService::NoLiveReadyMembersError.ancestors)
        .to include(System::InstancePoolService::NoReadyMembersError)
      expect { acquire }.to raise_error(System::InstancePoolService::NoReadyMembersError)
    end

    it "claims nothing" do
      # Rescuing the SPECIFIC class, not a bare `rescue nil`: a bare rescue is
      # satisfied by any StandardError, so a broken `acquire` helper (a wrong
      # pool name raising PoolError) would make this example green for a
      # reason that has nothing to do with the gate.
      begin
        acquire
      rescue System::InstancePoolService::NoLiveReadyMembersError
        nil
      end
      expect(silent.reload.pool_state).to eq("ready")
    end

    it "names EVERY member it refused, not just the first" do
      second = seed_ready(last_heartbeat_at: nil)

      expect { acquire }.to raise_error(
        System::InstancePoolService::NoLiveReadyMembersError
      ) { |e|
        expect(e.message).to include(silent.id, second.id)
        expect(e.message).to include("went silent").and include("never reported")
      }
    end
  end

  describe "an empty pool is still a different answer from a dead one" do
    # The `refused.empty?` branch — the whole reason two error classes exist.
    # Without it an empty pool would report "every ready member failed the
    # liveness gate", which sends an operator after a pool that only needs to
    # replenish.
    before { seed_ready(last_heartbeat_at: Time.current).update!(pool_state: "warming") }

    it "raises the plain NoReadyMembersError, not the liveness subclass" do
      # Asserting the class EXACTLY rather than `not_to raise_error(Subclass)`:
      # that negative form passes on any other error, NameError included.
      raised = begin
        acquire
        nil
      rescue System::InstancePoolService::NoReadyMembersError => e
        e
      end

      expect(raised).to be_a(System::InstancePoolService::NoReadyMembersError)
      expect(raised).not_to be_a(System::InstancePoolService::NoLiveReadyMembersError)
      expect(raised.message).to match(/Reaper will replenish/)
    end
  end

  describe "the walk skips more than one member" do
    # Pins the `refused` accumulator and the where.not(id: ...) exclusion at
    # N>1: at N=1 a broken accumulation or a broken exclusion still looks
    # right, and an exclusion that never grew would spin on the first refusal
    # rather than reach the live member behind it.
    let!(:dead_a) { seed_ready(last_heartbeat_at: 40.minutes.ago, warming_started_at: 30.minutes.ago) }
    let!(:dead_b) { seed_ready(last_heartbeat_at: nil,            warming_started_at: 20.minutes.ago) }
    let!(:dead_c) { seed_ready(last_heartbeat_at: 10.seconds.ago, warming_started_at: 15.minutes.ago, status: "stopped") }
    let!(:live)   { seed_ready(last_heartbeat_at: 5.seconds.ago,  warming_started_at: 1.minute.ago) }

    it "walks past three refusals of three different arms and lands on the live member" do
      expect(acquire.id).to eq(live.id)
      expect([ dead_a, dead_b, dead_c ].map { |m| m.reload.pool_state }).to all(eq("ready"))
    end
  end

  describe "the other refusal arms of the shared predicate" do
    it "refuses a running member that has never reported (never_reported)" do
      seed_ready(last_heartbeat_at: nil)
      expect { acquire }
        .to raise_error(System::InstancePoolService::NoLiveReadyMembersError, /never reported/)
    end

    it "refuses a member whose status left LIVE_REPLICA_STATUSES (offline arm)" do
      seed_ready(last_heartbeat_at: 10.seconds.ago, status: "error")
      expect { acquire }
        .to raise_error(System::InstancePoolService::NoLiveReadyMembersError, /no agent will pull/)
    end

    it "refuses a member that is live-for-capacity but running no agent (dormant arm)" do
      seed_ready(last_heartbeat_at: 10.seconds.ago, status: "stopped")
      expect { acquire }
        .to raise_error(System::InstancePoolService::NoLiveReadyMembersError, /no agent is running/)
    end
  end

  describe "a heartbeating member is still handed out" do
    let!(:live) { seed_ready(last_heartbeat_at: 5.seconds.ago) }

    it "acquires normally" do
      expect(acquire.id).to eq(live.id)
      expect(live.reload.pool_state).to eq("claimed")
    end
  end
end
