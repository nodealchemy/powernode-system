# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc3 — System::CiRunnerLease AASM state machine, scopes,
# validations, and lifecycle-category helpers. See the model's class comment
# for the "bookkeeping + recycle, not job isolation" semantics this locks in.
RSpec.describe System::CiRunnerLease, type: :model do
  let(:account)  { create(:account) }
  let(:instance) { create(:system_node_instance, :running, account: account) }

  # Build a lease directly at a given status, bypassing the AASM events —
  # mirrors the trait-based direct-status pattern disk_image_publication_spec
  # uses (e.g. :published) since InstancePool-style specs have no dedicated
  # factory for this model.
  def build_lease(status: "leased", node_instance: instance, **attrs)
    System::CiRunnerLease.create!(
      account: account,
      node_instance: node_instance,
      status: status,
      **attrs
    )
  end

  describe "defaults" do
    it "starts in :leased (AASM initial state)" do
      lease = build_lease
      expect(lease).to be_leased
      expect(lease.status).to eq("leased")
    end
  end

  describe "validations" do
    it "rejects an unknown status" do
      lease = System::CiRunnerLease.new(account: account, node_instance: instance, status: "bogus")
      expect(lease).not_to be_valid
      expect(lease.errors[:status]).to be_present
    end

    it "rejects an unknown purpose" do
      lease = System::CiRunnerLease.new(account: account, node_instance: instance, purpose: "bogus")
      expect(lease).not_to be_valid
      expect(lease.errors[:purpose]).to be_present
    end

    it "accepts every documented purpose" do
      System::CiRunnerLease::PURPOSES.each do |purpose|
        lease = build_lease(purpose: purpose)
        expect(lease).to be_valid
      end
    end

    it "rejects an unknown runner_scope" do
      lease = System::CiRunnerLease.new(account: account, node_instance: instance, runner_scope: "bogus")
      expect(lease).not_to be_valid
      expect(lease.errors[:runner_scope]).to be_present
    end

    # BUG FIX (spec-discovered): the migration declares runner_scope NOT NULL
    # with default "org", but the validation originally had allow_nil: true —
    # a lease with an explicit nil scope would pass .valid? yet blow up on
    # save with a Postgres NotNullViolation. Fixed to presence: true (matches
    # status/purpose). See app/models/system/ci_runner_lease.rb.
    it "rejects an explicit nil runner_scope (DB column is NOT NULL)" do
      lease = System::CiRunnerLease.new(account: account, node_instance: instance, runner_scope: nil)
      expect(lease).not_to be_valid
      expect(lease.errors[:runner_scope]).to be_present
    end

    it "defaults runner_scope to 'org' when omitted" do
      lease = build_lease
      expect(lease.runner_scope).to eq("org")
    end
  end

  describe "AASM transitions" do
    let(:git_runner) { create(:git_runner, account: account, name: "fleet-abc123def456") }

    it "leased -> registered via register!, stamping registered_at" do
      lease = build_lease
      expect { lease.register! }.to change(lease, :status).from("leased").to("registered")
      expect(lease.registered_at).to be_present
    end

    it "register!(runner) snapshots git_runner_id/runner_external_id/runner_name" do
      lease = build_lease(runner_name: nil)
      lease.register!(git_runner)
      expect(lease.git_runner_id).to eq(git_runner.id)
      expect(lease.runner_external_id).to eq(git_runner.external_id)
      expect(lease.runner_name).to eq(git_runner.name)
    end

    it "register!(runner) does not overwrite an already-set runner_name, but still snapshots the id/external_id" do
      lease = build_lease(runner_name: "fleet-preset")
      lease.register!(git_runner)
      expect(lease.runner_name).to eq("fleet-preset")
      expect(lease.git_runner_id).to eq(git_runner.id)
      expect(lease.runner_external_id).to eq(git_runner.external_id)
    end

    it "register! with no runner arg still stamps registered_at without touching git_runner fields" do
      lease = build_lease
      lease.register!
      expect(lease).to be_registered
      expect(lease.git_runner_id).to be_nil
      expect(lease.runner_external_id).to be_nil
    end

    it "registered -> busy via mark_busy!, stamping busy_at" do
      lease = build_lease(status: "registered")
      expect { lease.mark_busy! }.to change(lease, :status).to("busy")
      expect(lease.busy_at).to be_present
    end

    %w[leased registered busy].each do |from_status|
      it "#{from_status} -> releasing via begin_release!, stamping releasing_at" do
        lease = build_lease(status: from_status)
        expect { lease.begin_release! }.to change(lease, :status).to("releasing")
        expect(lease.releasing_at).to be_present
      end
    end

    it "releasing -> released via complete_release!, stamping released_at" do
      lease = build_lease(status: "releasing")
      expect { lease.complete_release! }.to change(lease, :status).to("released")
      expect(lease.released_at).to be_present
    end

    %w[leased registered busy releasing].each do |from_status|
      it "#{from_status} -> errored via fail!, stamping errored_at + error_message" do
        lease = build_lease(status: from_status)
        expect { lease.fail!("boom") }.to change(lease, :status).to("errored")
        expect(lease.errored_at).to be_present
        expect(lease.error_message).to eq("boom")
      end
    end

    it "fail! with no message leaves error_message untouched" do
      lease = build_lease(status: "leased", error_message: nil)
      lease.fail!
      expect(lease).to be_errored
      expect(lease.error_message).to be_nil
    end

    describe "illegal transitions raise AASM::InvalidTransition (whiny_transitions)" do
      it "register! on an already-registered lease" do
        lease = build_lease(status: "registered")
        expect { lease.register! }.to raise_error(AASM::InvalidTransition)
      end

      it "mark_busy! on a leased lease" do
        lease = build_lease(status: "leased")
        expect { lease.mark_busy! }.to raise_error(AASM::InvalidTransition)
      end

      it "complete_release! on a leased lease (must begin_release first)" do
        lease = build_lease(status: "leased")
        expect { lease.complete_release! }.to raise_error(AASM::InvalidTransition)
      end

      it "begin_release! on an already-released lease" do
        lease = build_lease(status: "released")
        expect { lease.begin_release! }.to raise_error(AASM::InvalidTransition)
      end

      it "fail! on an already-released lease (terminal)" do
        lease = build_lease(status: "released")
        expect { lease.fail!("x") }.to raise_error(AASM::InvalidTransition)
      end

      it "fail! on an already-errored lease (terminal)" do
        lease = build_lease(status: "errored")
        expect { lease.fail!("x") }.to raise_error(AASM::InvalidTransition)
      end
    end
  end

  describe "scopes" do
    let!(:leased_lease)     { build_lease(status: "leased") }
    let!(:registered_lease) { build_lease(status: "registered") }
    let!(:busy_lease)       { build_lease(status: "busy") }
    let!(:releasing_lease)  { build_lease(status: "releasing") }
    let!(:released_lease)   { build_lease(status: "released") }
    let!(:errored_lease)    { build_lease(status: "errored") }

    it "by_status filters to a single status" do
      expect(System::CiRunnerLease.by_status("busy")).to contain_exactly(busy_lease)
    end

    it "per-state scopes match the AASM state names" do
      expect(System::CiRunnerLease.leased).to contain_exactly(leased_lease)
      expect(System::CiRunnerLease.registered).to contain_exactly(registered_lease)
      expect(System::CiRunnerLease.busy).to contain_exactly(busy_lease)
      expect(System::CiRunnerLease.releasing).to contain_exactly(releasing_lease)
      expect(System::CiRunnerLease.released).to contain_exactly(released_lease)
      expect(System::CiRunnerLease.errored).to contain_exactly(errored_lease)
    end

    it "active includes leased/registered/busy/releasing only" do
      expect(System::CiRunnerLease.active).to contain_exactly(
        leased_lease, registered_lease, busy_lease, releasing_lease
      )
    end

    it "finished includes released/errored only" do
      expect(System::CiRunnerLease.finished).to contain_exactly(released_lease, errored_lease)
    end

    it "for_node_instance scopes to the given instance" do
      other_instance = create(:system_node_instance, :running, account: account)
      other_lease = build_lease(status: "leased", node_instance: other_instance)
      result = System::CiRunnerLease.for_node_instance(instance)
      expect(result).not_to include(other_lease)
      expect(result).to include(leased_lease)
    end

    it "for_workflow_run scopes to the given run id" do
      run_lease = build_lease(status: "leased", workflow_run_id: 42)
      expect(System::CiRunnerLease.for_workflow_run(42)).to contain_exactly(run_lease)
    end

    it "with_run_ref returns only leases with a workflow_run_id set" do
      run_lease = build_lease(status: "leased", workflow_run_id: 99)
      expect(System::CiRunnerLease.with_run_ref).to contain_exactly(run_lease)
    end

    it "expired returns only leases whose expires_at is in the past" do
      expired = build_lease(status: "leased", expires_at: 1.hour.ago)
      not_expired = build_lease(status: "leased", expires_at: 1.hour.from_now)
      result = System::CiRunnerLease.expired
      expect(result).to include(expired)
      expect(result).not_to include(not_expired)
      expect(result).not_to include(leased_lease) # no expires_at set
    end

    it "recent orders by created_at descending" do
      ordered = System::CiRunnerLease.recent.pluck(:created_at)
      expect(ordered).to eq(ordered.sort.reverse)
    end
  end

  describe "#active? / #finished? / #expired?" do
    it "active? is true for leased/registered/busy/releasing" do
      %w[leased registered busy releasing].each do |status|
        expect(build_lease(status: status)).to be_active
      end
    end

    it "active? is false for released/errored" do
      %w[released errored].each do |status|
        expect(build_lease(status: status)).not_to be_active
      end
    end

    it "finished? is true for released/errored only" do
      %w[released errored].each { |status| expect(build_lease(status: status)).to be_finished }
      %w[leased registered busy releasing].each { |status| expect(build_lease(status: status)).not_to be_finished }
    end

    it "expired? is true only when expires_at is present and in the past" do
      expect(build_lease(expires_at: 1.hour.ago)).to be_expired
      expect(build_lease(expires_at: 1.hour.from_now)).not_to be_expired
      expect(build_lease(expires_at: nil)).not_to be_expired
    end
  end
end
