# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc9 (Part A) — System::ModuleBuildBatch AASM state
# machine, .create_for, #member_tasks, and #recompute_counts!. Mirrors
# spec/models/system/ci_runner_lease_spec.rb's structure (the AASM precedent
# this model follows).
RSpec.describe System::ModuleBuildBatch, type: :model do
  let(:account) { create(:account) }

  def build_batch(status: "planning", **attrs)
    System::ModuleBuildBatch.create!(
      account: account,
      status: status,
      trigger: "push",
      base_sha: "a" * 40,
      head_sha: "b" * 40,
      **attrs
    )
  end

  describe "defaults" do
    it "starts in :planning (AASM initial state)" do
      batch = build_batch
      expect(batch).to be_planning
      expect(batch.status).to eq("planning")
    end
  end

  describe "validations" do
    it "rejects an unknown status" do
      batch = System::ModuleBuildBatch.new(account: account, status: "bogus", trigger: "push",
                                            base_sha: "a", head_sha: "b")
      expect(batch).not_to be_valid
      expect(batch.errors[:status]).to be_present
    end

    it "rejects an unknown trigger" do
      batch = System::ModuleBuildBatch.new(account: account, trigger: "bogus", base_sha: "a", head_sha: "b")
      expect(batch).not_to be_valid
      expect(batch.errors[:trigger]).to be_present
    end

    it "accepts every documented trigger" do
      System::ModuleBuildBatch::TRIGGERS.each do |trigger|
        expect(build_batch(trigger: trigger)).to be_valid
      end
    end

    it "requires base_sha and head_sha" do
      expect(System::ModuleBuildBatch.new(account: account, trigger: "push", base_sha: nil, head_sha: "b"))
        .not_to be_valid
      expect(System::ModuleBuildBatch.new(account: account, trigger: "push", base_sha: "a", head_sha: nil))
        .not_to be_valid
    end
  end

  describe "AASM transitions" do
    it "planning -> dispatched via dispatch!, stamping dispatched_at" do
      batch = build_batch
      expect { batch.dispatch! }.to change(batch, :status).from("planning").to("dispatched")
      expect(batch.dispatched_at).to be_present
    end

    it "dispatched -> awaiting_signature via await_signature!, stamping awaiting_signature_at" do
      batch = build_batch(status: "dispatched")
      expect { batch.await_signature! }.to change(batch, :status).to("awaiting_signature")
      expect(batch.awaiting_signature_at).to be_present
    end

    it "awaiting_signature -> publishing via begin_publishing!, stamping publishing_at" do
      batch = build_batch(status: "awaiting_signature")
      expect { batch.begin_publishing! }.to change(batch, :status).to("publishing")
      expect(batch.publishing_at).to be_present
    end

    it "publishing -> complete via complete!, stamping completed_at" do
      batch = build_batch(status: "publishing")
      expect { batch.complete! }.to change(batch, :status).to("complete")
      expect(batch.completed_at).to be_present
    end

    it "publishing -> partial via complete_partially!, stamping completed_at" do
      batch = build_batch(status: "publishing")
      expect { batch.complete_partially! }.to change(batch, :status).to("partial")
      expect(batch.completed_at).to be_present
    end

    %w[planning dispatched awaiting_signature publishing].each do |from_status|
      it "#{from_status} -> failed via fail!, stamping failed_at + error_message" do
        batch = build_batch(status: from_status)
        expect { batch.fail!("boom") }.to change(batch, :status).to("failed")
        expect(batch.failed_at).to be_present
        expect(batch.error_message).to eq("boom")
      end
    end

    it "fail! with no message leaves error_message untouched" do
      batch = build_batch(status: "planning", error_message: nil)
      batch.fail!
      expect(batch).to be_failed
      expect(batch.error_message).to be_nil
    end

    describe "illegal transitions raise AASM::InvalidTransition (whiny_transitions)" do
      it "dispatch! on an already-dispatched batch" do
        batch = build_batch(status: "dispatched")
        expect { batch.dispatch! }.to raise_error(AASM::InvalidTransition)
      end

      it "complete! on a planning batch (must reach publishing first)" do
        batch = build_batch(status: "planning")
        expect { batch.complete! }.to raise_error(AASM::InvalidTransition)
      end

      it "fail! on an already-complete batch (terminal)" do
        batch = build_batch(status: "complete")
        expect { batch.fail!("x") }.to raise_error(AASM::InvalidTransition)
      end

      it "fail! on an already-failed batch (terminal)" do
        batch = build_batch(status: "failed")
        expect { batch.fail!("x") }.to raise_error(AASM::InvalidTransition)
      end
    end
  end

  describe "scopes" do
    let!(:manual_batch) { build_batch(trigger: "manual") }
    let!(:dispatched)   { build_batch(status: "dispatched") }

    it "by_status filters to a single status" do
      expect(System::ModuleBuildBatch.by_status("dispatched")).to contain_exactly(dispatched)
    end

    it "by_trigger filters to a single trigger" do
      expect(System::ModuleBuildBatch.by_trigger("manual")).to contain_exactly(manual_batch)
    end

    it "recent orders by created_at descending" do
      ordered = System::ModuleBuildBatch.recent.pluck(:created_at)
      expect(ordered).to eq(ordered.sort.reverse)
    end
  end

  describe ".create_for" do
    let(:plan) do
      [
        { module: "redis", oci_ref: "abc1234" },
        { module: "hub-backend", oci_ref: "abc1234" }
      ]
    end

    it "creates a batch in :planning from a planner result" do
      batch = described_class.create_for(
        account: account, plan: plan, trigger: "push", base_sha: "a" * 40, head_sha: "b" * 40
      )

      expect(batch).to be_persisted
      expect(batch).to be_planning
      expect(batch.trigger).to eq("push")
      expect(batch.base_sha).to eq("a" * 40)
      expect(batch.head_sha).to eq("b" * 40)
      expect(batch.module_slugs).to contain_exactly("redis", "hub-backend")
      expect(batch.planned_count).to eq(2)
    end

    it "preserves the full plan (module + oci_ref) in metadata for audit" do
      batch = described_class.create_for(account: account, plan: plan, trigger: "manual", base_sha: "a", head_sha: "b")

      expect(batch.metadata["plan"]).to contain_exactly(
        { "module" => "redis", "oci_ref" => "abc1234" },
        { "module" => "hub-backend", "oci_ref" => "abc1234" }
      )
    end

    it "handles an empty plan (nothing to build)" do
      batch = described_class.create_for(account: account, plan: [], trigger: "push", base_sha: "a", head_sha: "b")

      expect(batch.module_slugs).to eq([])
      expect(batch.planned_count).to eq(0)
    end
  end

  describe "#member_tasks" do
    let(:batch) { build_batch }

    it "returns only ci.module_build tasks carrying this batch's id in options" do
      member1 = create(:system_task, account: account, command: "ci.module_build",
                                      status: "complete", options: { "batch_id" => batch.id })
      member2 = create(:system_task, account: account, command: "ci.module_build",
                                      status: "failed", options: { "batch_id" => batch.id })
      other_batch_task = create(:system_task, account: account, command: "ci.module_build",
                                               status: "pending", options: { "batch_id" => SecureRandom.uuid })
      other_command_task = create(:system_task, account: account, command: "sync_modules",
                                                 status: "pending", options: { "batch_id" => batch.id })

      result = batch.member_tasks
      expect(result).to include(member1, member2)
      expect(result).not_to include(other_batch_task, other_command_task)
    end
  end

  describe "#recompute_counts!" do
    let(:batch) { build_batch }

    def member_task(status:)
      create(:system_task, account: account, command: "ci.module_build",
                            status: status, options: { "batch_id" => batch.id })
    end

    it "recomputes succeeded_count/failed_count from member task statuses, leaving planned_count untouched" do
      batch.update!(planned_count: 3)
      member_task(status: "complete")
      member_task(status: "complete")
      member_task(status: "failed")

      batch.recompute_counts!

      expect(batch.succeeded_count).to eq(2)
      expect(batch.failed_count).to eq(1)
      expect(batch.planned_count).to eq(3)
    end

    it "counts aborted and cancelled member tasks as failed" do
      member_task(status: "aborted")
      member_task(status: "cancelled")

      batch.recompute_counts!

      expect(batch.failed_count).to eq(2)
      expect(batch.succeeded_count).to eq(0)
    end

    it "ignores tasks still in flight (pending/scheduled/running)" do
      member_task(status: "pending")
      member_task(status: "running")

      batch.recompute_counts!

      expect(batch.succeeded_count).to eq(0)
      expect(batch.failed_count).to eq(0)
    end
  end

  describe "#active? / #finished?" do
    it "active? is true for planning/dispatched/awaiting_signature/publishing" do
      %w[planning dispatched awaiting_signature publishing].each do |status|
        expect(build_batch(status: status)).to be_active
      end
    end

    it "active? is false for complete/partial/failed" do
      %w[complete partial failed].each do |status|
        expect(build_batch(status: status)).not_to be_active
      end
    end

    it "finished? is true for complete/partial/failed only" do
      %w[complete partial failed].each { |status| expect(build_batch(status: status)).to be_finished }
      %w[planning dispatched awaiting_signature publishing].each do |status|
        expect(build_batch(status: status)).not_to be_finished
      end
    end
  end
end
