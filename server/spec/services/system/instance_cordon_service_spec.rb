# frozen_string_literal: true

require "rails_helper"

# IMP-0467eee9fc57 — System::InstanceCordonService: the reversible
# "unschedulable" mode for a NodeInstance.
#
# The mode is a `config["cordon"]` marker PLUS, for a pool member that is
# acquirable, the allocator fence: `pool_state` "ready" → "draining", which is
# the ONE state InstancePoolService#acquire! never picks and the reaper never
# touches. Every scheduler that hands a NodeInstance new work today —
# InstancePoolService#acquire! itself, AgentFleetMissionService#acquire_member,
# CiRunnerLeaseService#acquire_instance, system_acquire_pooled_instance — goes
# through that one query, so fencing the pool_state fences all four without a
# second reader. The marker is what makes the fence REVERSIBLE: a bare
# "draining" is indistinguishable from a drain or a recycle in progress, and
# an uncordon must never resurrect one of those.
#
# THE ORACLE IS THE ALLOCATOR, not the column: the fence examples call the real
# acquire! so a marker with no allocator reader — the exact defect the drain_*
# markers had — cannot pass here.
RSpec.describe System::InstanceCordonService do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account: account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:pool) do
    ::System::InstancePool.create!(
      account: account, node_template: template, name: "cordon-pool",
      target_size: 1, min_size: 0, max_size: 2, lifecycle_class: "ephemeral"
    )
  end

  def ready_member(status: "running")
    create(:system_node_instance, node: node, account: account, status: status,
                                  instance_pool_id: pool.id, pool_state: "ready",
                                  pool_warming_started_at: 1.minute.ago)
  end

  describe ".cordon!" do
    it "fences a ready pool member out of the real allocator and leaves it running" do
      member = ready_member

      result = described_class.cordon!(instance: member, user: user, reason: "kernel patch")

      expect(result).to be_ok
      expect(result.cordon_state).to eq("fenced")
      expect(member.reload.pool_state).to eq("draining")
      expect(member.status).to eq("running")
      expect(described_class.cordoned?(member)).to be(true)
      expect {
        ::System::InstancePoolService.acquire!(account: account, pool_id: pool.id)
      }.to raise_error(::System::InstancePoolService::NoReadyMembersError)
    end

    it "records who, why and when, and what pool_state it will restore" do
      member = ready_member

      described_class.cordon!(instance: member, user: user, reason: "kernel patch")

      marker = member.reload.config.fetch("cordon")
      expect(marker["by_user_id"]).to eq(user.id)
      expect(marker["reason"]).to eq("kernel patch")
      expect(marker["cordoned_at"]).to be_present
      expect(marker["pool_state_before"]).to eq("ready")
    end

    it "emits a system.instance.cordoned fleet event on the instance" do
      member = ready_member

      expect {
        described_class.cordon!(instance: member, user: user, reason: "kernel patch")
      }.to change { ::System::FleetEvent.where(kind: "system.instance.cordoned", node_instance_id: member.id).count }
        .by(1)
    end

    it "marks a non-pool instance without touching pool_state" do
      instance = create(:system_node_instance, :running, node: node, account: account)

      result = described_class.cordon!(instance: instance, user: user, reason: "isolate")

      expect(result).to be_ok
      expect(result.cordon_state).to eq("not_pooled")
      expect(instance.reload.pool_state).to be_nil
      expect(described_class.cordoned?(instance)).to be(true)
    end

    # A claimed member is already un-acquirable; both release paths guard on
    # pool_state == "claimed", so flipping it would strand it (the drain's
    # :claimed arm, same reasoning).
    it "marks a CLAIMED member without flipping its pool_state" do
      member = ready_member
      member.update!(pool_state: "claimed", pool_acquired_at: Time.current)

      result = described_class.cordon!(instance: member, user: user, reason: "isolate")

      expect(result).to be_ok
      expect(result.cordon_state).to eq("claimed")
      expect(member.reload.pool_state).to eq("claimed")
      expect(member.config.dig("cordon", "pool_state_before")).to eq("claimed")
    end

    # The fence is a CONDITIONAL write: acquire! claims under a row lock, and a
    # plain update! after a stale read would overwrite "claimed" with
    # "draining" and strand the consumer's member.
    it "does not clobber a member the allocator claimed between the read and the fence" do
      member = ready_member
      ::System::NodeInstance.where(id: member.id).update_all(pool_state: "claimed", pool_acquired_at: Time.current)

      result = described_class.cordon!(instance: member, user: user, reason: "race")

      expect(result).to be_ok
      expect(result.cordon_state).to eq("claimed")
      expect(member.reload.pool_state).to eq("claimed")
    end

    it "refuses a warming member — promote_pool_ready! would re-admit it behind the marker" do
      member = ready_member
      member.update!(pool_state: "warming")

      result = described_class.cordon!(instance: member, user: user, reason: "x")

      expect(result).not_to be_ok
      expect(result.error).to match(/warming/)
      expect(described_class.cordoned?(member.reload)).to be(false)
    end

    it "refuses a terminated instance" do
      instance = create(:system_node_instance, node: node, account: account, status: "terminated")

      result = described_class.cordon!(instance: instance, user: user, reason: "x")

      expect(result).not_to be_ok
      expect(result.error).to match(/terminated/)
    end

    it "refuses an already-cordoned instance" do
      member = ready_member
      described_class.cordon!(instance: member, user: user, reason: "first")

      result = described_class.cordon!(instance: member.reload, user: user, reason: "second")

      expect(result).not_to be_ok
      expect(result.error).to match(/already cordoned/)
      expect(member.reload.config.dig("cordon", "reason")).to eq("first")
    end

    it "requires a reason" do
      result = described_class.cordon!(instance: ready_member, user: user, reason: " ")

      expect(result).not_to be_ok
      expect(result.error).to match(/reason/)
    end
  end

  describe ".uncordon!" do
    it "hands a fenced running member back to the allocator with a fresh ready-TTL anchor" do
      member = ready_member
      described_class.cordon!(instance: member, user: user, reason: "patch")
      member.reload.update_columns(pool_warming_started_at: 3.hours.ago)

      result = described_class.uncordon!(instance: member.reload, user: user)

      expect(result).to be_ok
      expect(result.cordon_state).to eq("restored")
      expect(member.reload.pool_state).to eq("ready")
      expect(member.pool_warming_started_at).to be > 1.minute.ago
      expect(described_class.cordoned?(member)).to be(false)
      expect(::System::InstancePoolService.acquire!(account: account, pool_id: pool.id).id).to eq(member.id)
    end

    it "emits a system.instance.uncordoned fleet event" do
      member = ready_member
      described_class.cordon!(instance: member, user: user, reason: "patch")

      expect {
        described_class.uncordon!(instance: member.reload, user: user)
      }.to change { ::System::FleetEvent.where(kind: "system.instance.uncordoned", node_instance_id: member.id).count }
        .by(1)
    end

    # Fail closed: a "ready" member that is not running would be handed to a
    # consumer as a dead VM. The cordon stays until the instance is back.
    it "refuses to re-admit a fenced member that is not running" do
      member = ready_member
      described_class.cordon!(instance: member, user: user, reason: "patch")
      member.reload.update_columns(status: "stopped")

      result = described_class.uncordon!(instance: member.reload, user: user)

      expect(result).not_to be_ok
      expect(result.error).to match(/not running/)
      expect(member.reload.pool_state).to eq("draining")
      expect(described_class.cordoned?(member)).to be(true)
    end

    it "clears the marker on a claimed member without touching its pool_state" do
      member = ready_member
      member.update!(pool_state: "claimed", pool_acquired_at: Time.current)
      described_class.cordon!(instance: member, user: user, reason: "patch")

      result = described_class.uncordon!(instance: member.reload, user: user)

      expect(result).to be_ok
      expect(result.cordon_state).to eq("cleared")
      expect(member.reload.pool_state).to eq("claimed")
      expect(described_class.cordoned?(member)).to be(false)
    end

    # A member that was recycled or errored while cordoned is not "ours" to
    # restore: the conditional flip finds no "draining" row and the uncordon
    # reports it rather than writing "ready" over whatever state it is in.
    it "does not write ready over a member that left draining while cordoned" do
      member = ready_member
      described_class.cordon!(instance: member, user: user, reason: "patch")
      ::System::NodeInstance.where(id: member.id).update_all(pool_state: "errored")

      result = described_class.uncordon!(instance: member.reload, user: user)

      expect(result).to be_ok
      expect(result.cordon_state).to eq("cleared")
      expect(member.reload.pool_state).to eq("errored")
      expect(described_class.cordoned?(member)).to be(false)
    end

    it "refuses an instance that is not cordoned" do
      result = described_class.uncordon!(instance: ready_member, user: user)

      expect(result).not_to be_ok
      expect(result.error).to match(/not cordoned/)
    end
  end

  describe ".cordoned?" do
    it "is false for a bare draining pool_state — a drain or recycle in progress is not a cordon" do
      member = ready_member
      member.update!(pool_state: "draining")

      expect(described_class.cordoned?(member)).to be(false)
    end
  end

  # ── review hardening (both arms are ABSENCE-of-a-bad-state properties, so
  # each is stated as an observable the old shape would fail) ────────────────
  describe "the fence and the marker are one write" do
    # The pair is what is meaningful: a fenced member with NO marker is
    # unrecoverable through this service's own doors — uncordon refuses it
    # ("is not cordoned"), and a re-cordon reads pool_state "draining" and
    # records pool_state_before "draining", whose uncordon never writes "ready"
    # back. So the fence must not survive a failed marker write.
    it "leaves the member acquirable when the marker write fails" do
      member = ready_member
      allow_any_instance_of(::System::NodeInstance)
        .to receive(:merge_config!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect {
        described_class.cordon!(instance: member, user: user, reason: "kernel patch")
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(member.reload.pool_state).to eq("ready")
      expect(described_class.cordoned?(member)).to be(false)
      expect(pool.ready_members.pluck(:id)).to include(member.id)
    end

    # The mirror, and the one that fails UNSAFE: a restored-but-still-marked
    # member is acquirable while every reader still calls it cordoned.
    it "leaves the member fenced when the uncordon's marker clear fails" do
      member = ready_member
      described_class.cordon!(instance: member, user: user, reason: "kernel patch")
      allow_any_instance_of(::System::NodeInstance)
        .to receive(:delete_config_keys!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect {
        described_class.uncordon!(instance: member, user: user)
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(member.reload.pool_state).to eq("draining")
      expect(described_class.cordoned?(member)).to be(true)
    end
  end

  describe "the fence retry is bounded" do
    # A lost conditional flip means the row moved; the state it moved to can be
    # "ready" again (acquire! claims it, a reuse_without_reset release re-marks
    # it ready), so the re-classify arm has no terminal case of its own. An
    # unbounded self-call would spin here instead of returning.
    it "refuses rather than spinning when the flip keeps losing the race" do
      member = ready_member
      relation = ::System::NodeInstance.where(id: member.id, pool_state: "ready")
      attempts = 0
      allow(::System::NodeInstance).to receive(:where).and_wrap_original do |orig, *args|
        rel = orig.call(*args)
        next rel unless args.first.is_a?(Hash) && args.first[:pool_state] == "ready"

        attempts += 1
        instance_double(ActiveRecord::Relation).tap { |d| allow(d).to receive(:update_all).and_return(0) }
      end

      result = described_class.cordon!(instance: member, user: user, reason: "kernel patch")

      expect(result).not_to be_ok
      expect(result.error).to include("cordon attempts")
      expect(attempts).to eq(described_class::FENCE_ATTEMPTS)
      expect(relation.count).to eq(1)
    end
  end
end
