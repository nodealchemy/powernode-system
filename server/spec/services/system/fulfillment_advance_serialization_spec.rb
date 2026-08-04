# frozen_string_literal: true

require "rails_helper"

# IMP-d4fc286b7ccf — advance! must be serialized PER REQUEST.
#
# Two independent entrants call System::FulfillmentAdvanceOrchestrator.advance!
# on the same row: the operator approve endpoint (which drives one advance
# inline) and System::FulfillmentRequestSweepService (which re-ticks every
# ADVANCEABLE row every 60s). A single advance walks the whole chain —
# materialize, dispatch a build, author a template, PROVISION CLOUD INSTANCES,
# smoke — which takes minutes, so the two overlap routinely.
#
# Every phase guard in the orchestrator is read-then-act (`materialized_recorded?`,
# `@request.template_id.present?`, ...) with no row lock, no lock_version and no
# uniqueness constraint behind it, so two overlapping advances each read "not
# provisioned yet" and each provision. That is duplicate billable cloud spend,
# not merely wasted work.
RSpec.describe "System::FulfillmentAdvanceOrchestrator advance serialization" do
  let(:account) { create(:account) }

  let(:request_row) do
    ::System::FulfillmentRequest.create_composed!(
      account: account,
      request: "give me a running memcached instance",
      plan: { "execution" => { "gaps" => [], "template_name" => "fulfill-memcached" } },
      cost_estimate: {},
      reused_modules: %w[mod-a],
      lease_ttl_seconds: 3600
    ).tap(&:approve!)
  end

  describe "the advisory lock key" do
    it "is derived from the request id, so different requests never exclude each other" do
      key_a = described_class_key("11111111-1111-7111-8111-111111111111")
      key_b = described_class_key("22222222-2222-7222-8222-222222222222")

      expect(key_a).not_to eq(key_b)
      expect(key_a).to eq(described_class_key("11111111-1111-7111-8111-111111111111"))
      # Must fit a Postgres bigint — pg_try_advisory_lock takes int8.
      expect(key_a).to be < 2**63
      expect(key_a).to be >= 0
    end
  end

  def described_class_key(id)
    ::System::FulfillmentAdvanceOrchestrator.advisory_lock_key(id)
  end

  describe "when another advance already holds the lock" do
    # Simulate the overlap deterministically: the second entrant's try-lock
    # fails, which is exactly what Postgres returns to a different session while
    # the first advance is mid-provision.
    before do
      allow_any_instance_of(::System::FulfillmentAdvanceOrchestrator)
        .to receive(:acquire_advance_lock!).and_return(false)
    end

    it "returns already_advancing instead of advancing a second time" do
      result = ::System::FulfillmentAdvanceOrchestrator.advance!(request: request_row)

      expect(result.already_advancing).to be(true)
      expect(result.advanced).to be(false)
      expect(result.ok?).to be(true)
    end

    it "does NOT run any phase — the row is untouched" do
      expect(request_row.state).to eq("approved")

      ::System::FulfillmentAdvanceOrchestrator.advance!(request: request_row)

      expect(request_row.reload.state).to eq("approved")
      expect(request_row.materializing_at).to be_nil
      expect(request_row.node_instance_ids).to be_empty
    end

    it "never releases a lock it does not hold" do
      expect_any_instance_of(::System::FulfillmentAdvanceOrchestrator)
        .not_to receive(:release_advance_lock!)

      ::System::FulfillmentAdvanceOrchestrator.advance!(request: request_row)
    end
  end

  describe "when the lock is free" do
    it "advances and releases the lock afterwards" do
      expect_any_instance_of(::System::FulfillmentAdvanceOrchestrator)
        .to receive(:release_advance_lock!).at_least(:once).and_call_original

      result = ::System::FulfillmentAdvanceOrchestrator.advance!(request: request_row)

      expect(result.already_advancing).to be_falsey
      expect(request_row.reload.state).not_to eq("approved")
    end

    it "releases the lock even when a phase raises" do
      allow_any_instance_of(::System::FulfillmentAdvanceOrchestrator)
        .to receive(:advance_one).and_raise(StandardError, "phase exploded")
      expect_any_instance_of(::System::FulfillmentAdvanceOrchestrator)
        .to receive(:release_advance_lock!).at_least(:once).and_call_original

      ::System::FulfillmentAdvanceOrchestrator.advance!(request: request_row)

      # A leaked session lock would wedge this request forever — the next
      # entrant must be able to take it.
      expect(::System::FulfillmentAdvanceOrchestrator.new(request: request_row.reload)
               .send(:acquire_advance_lock!)).to be_truthy
    end
  end

  describe "System::FulfillmentRequestSweepService" do
    it "skips a locked row rather than counting it as advanced" do
      request_row # materialize
      allow(::System::FulfillmentAdvanceOrchestrator).to receive(:advance!).and_return(
        ::System::FulfillmentAdvanceOrchestrator::Result.new(
          ok?: true, state: "approved", advanced: false, waiting: false,
          parked: [], error: nil, already_advancing: true
        )
      )

      summary = ::System::FulfillmentRequestSweepService.run!(account: account)

      expect(summary[:advanced]).to eq(0)
      expect(summary[:errored]).to eq(0)
    end

    it "still counts a genuinely advanced row" do
      request_row
      allow(::System::FulfillmentAdvanceOrchestrator).to receive(:advance!).and_return(
        ::System::FulfillmentAdvanceOrchestrator::Result.new(
          ok?: true, state: "materializing", advanced: true, waiting: false,
          parked: [], error: nil
        )
      )

      summary = ::System::FulfillmentRequestSweepService.run!(account: account)

      expect(summary[:advanced]).to eq(1)
    end
  end
end
