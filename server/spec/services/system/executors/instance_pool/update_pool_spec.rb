# frozen_string_literal: true

require "rails_helper"

# IMP-24daa05e7a22 — UpdatePool stopped being a producerless sibling when
# InstancePoolsController#update started gating a CEILING RAISE and the ARCHIVE
# transition through it. Bringing a dead executor live is the moment its
# tenancy and replay seams have to be checked: before this it was reachable
# from nothing, so nothing exercised them.
#
# The request spec pins the gate; this file pins the executor's own contract —
# the class name the controller dispatches by STRING, the account anchor, and
# the approval card.
RSpec.describe System::Executors::InstancePool::UpdatePool do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }

  let!(:pool) do
    System::InstancePool.create!(
      account: account, name: "ceiling-pool", node_template: node_template,
      target_size: 2, min_size: 0, max_size: 5,
      lifecycle_class: "ephemeral", status: "active"
    )
  end

  it "is resolvable from the exact string the controller dispatches" do
    expect("System::Executors::InstancePool::UpdatePool".constantize)
      .to eq(described_class)
  end

  describe ".replay_baseline_attributes" do
    # The opt-in guard is declared on the EXECUTOR because both ends read it.
    # min_size/description/metadata are deliberately absent: they have
    # concurrent writers (the status sensor merges metadata) and a parked
    # ceiling raise must not be invalidated by a change it never named.
    it "fingerprints the spend and teardown columns only" do
      expect(described_class.replay_baseline_attributes)
        .to contain_exactly(:target_size, :max_size, :status)
    end
  end

  describe ".execute" do
    it "applies the attributes to the pool the params name" do
      result = described_class.execute(
        { pool_id: pool.id, attributes: { target_size: 4 } },
        deferred_operation: deferred_operation
      )

      expect(result[:success]).to be true
      expect(pool.reload.target_size).to eq(4)
    end

    # resolve_scoped, not a bare find: params reach the executor
    # caller-supplied, stored verbatim and replayed with no re-validation.
    it "refuses a pool outside the operation's account" do
      foreign = System::InstancePool.create!(
        account: other_account, name: "foreign-pool",
        node_template: create(:system_node_template, account: other_account),
        target_size: 1, min_size: 0, max_size: 2,
        lifecycle_class: "ephemeral", status: "active"
      )

      expect {
        described_class.execute({ pool_id: foreign.id, attributes: { target_size: 9 } },
                                deferred_operation: deferred_operation)
      }.to raise_error(::Ai::DeferredOperation::CrossAccountError)

      expect(foreign.reload.target_size).to eq(1)
    end

    it "refuses the replay when a fingerprinted column moved since the request" do
      params = {
        pool_id: pool.id,
        attributes: { target_size: 4 },
        replay_baseline: described_class.replay_baseline(pool, { target_size: 4 })
      }
      pool.update!(target_size: 1) # the ungated inline DECREASE

      expect {
        described_class.execute(params, deferred_operation: deferred_operation)
      }.to raise_error(::System::Executors::Base::ReplayBaselineError)

      expect(pool.reload.target_size).to eq(1)
    end

    it "applies the replay when nothing moved" do
      params = {
        pool_id: pool.id,
        attributes: { target_size: 4 },
        replay_baseline: described_class.replay_baseline(pool, { target_size: 4 })
      }

      described_class.execute(params, deferred_operation: deferred_operation)

      expect(pool.reload.target_size).to eq(4)
    end
  end

  describe ".preview" do
    it "names the pool on the approval card" do
      preview = described_class.preview({ pool_id: pool.id, attributes: { target_size: 4 } },
                                        deferred_operation: deferred_operation)

      expect(preview[:summary]).to include("ceiling-pool")
    end

    # scoped_label_record fails CLOSED with no anchor and never raises, so the
    # card degrades to the id rather than blowing up the approval queue.
    it "falls back to the id when the row cannot be labelled" do
      preview = described_class.preview({ pool_id: "00000000-0000-0000-0000-000000000000" },
                                        deferred_operation: deferred_operation)

      expect(preview[:summary]).to include("00000000-0000-0000-0000-000000000000")
    end
  end
end
