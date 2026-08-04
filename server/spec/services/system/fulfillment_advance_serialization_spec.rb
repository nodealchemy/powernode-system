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

  # ---------------------------------------------------------------------------
  # Probing the lock takes a second Postgres SESSION — not merely a second
  # connection object, and not the request's own connection.
  #
  # Session advisory locks are re-entrant within one session: a session that
  # already holds a key is handed `true` again by pg_try_advisory_lock and its
  # hold count simply increments. So re-taking the key on the connection the
  # advance ran on returns true whether or not the lock was ever released — that
  # probe cannot observe a leak at all.
  #
  # The connection pool cannot supply the second session either. With
  # use_transactional_fixtures, Rails 8 PINS the pool to one connection, so
  # connection_pool.checkout and connection_pool.with_connection — including
  # from a separate Thread — all hand back that same backend (measured here:
  # identical pg_backend_pid, and checkout returns the very same object). Only a
  # separately established connection is a different session.
  #
  # Hence a throwaway libpq connection built from the same database config. It
  # is always closed, which both returns nothing to the pool and drops any lock
  # it took, so nothing leaks into the next example.
  def advisory_key(request_id)
    ::System::FulfillmentAdvanceOrchestrator.advisory_lock_key(request_id)
  end

  def open_second_session
    cfg = ::ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect({ host: cfg[:host], port: cfg[:port], dbname: cfg[:database],
                 user: cfg[:username], password: cfg[:password] }.compact)
  end

  # Whether a session OTHER than the one advance! ran on can take the key —
  # i.e. whether the lock is genuinely free rather than merely re-entrant.
  def lock_free_to_another_session?(request_id)
    conn = open_second_session
    conn.exec("SELECT pg_try_advisory_lock(#{advisory_key(request_id)})").getvalue(0, 0) == "t"
  ensure
    conn&.close
  end

  # Holds the key in another session for the duration of the block — exactly
  # what a concurrent advance in the other entrant's process looks like to
  # Postgres. No stubbing: the orchestrator's own pg_try_advisory_lock is what
  # gets refused.
  def holding_lock_in_another_session(request_id)
    conn = open_second_session
    taken = conn.exec("SELECT pg_try_advisory_lock(#{advisory_key(request_id)})").getvalue(0, 0)
    raise "second session could not take the advisory lock (got #{taken.inspect})" unless taken == "t"

    yield
  ensure
    conn&.close
  end

  # advance! locks on the request's own (pinned) connection, and a session lock
  # outlives the example's transaction rollback. Drop anything still held so no
  # example can hand a stuck lock to the next one.
  after do
    ::System::FulfillmentRequest.connection.execute("SELECT pg_advisory_unlock_all()")
  end

  describe "the advisory lock key" do
    it "is derived from the request id, so different requests never exclude each other" do
      key_a = advisory_key("11111111-1111-7111-8111-111111111111")
      key_b = advisory_key("22222222-2222-7222-8222-222222222222")

      expect(key_a).not_to eq(key_b)
      expect(key_a).to eq(advisory_key("11111111-1111-7111-8111-111111111111"))
      # Must fit a Postgres bigint — pg_try_advisory_lock takes int8.
      expect(key_a).to be < 2**63
      expect(key_a).to be >= 0
    end
  end

  describe "when another advance already holds the lock" do
    # Simulate the overlap deterministically: the second entrant's try-lock
    # fails, which is exactly what Postgres returns to a different session while
    # the first advance is mid-provision. (The unstubbed counterpart — a real
    # second session holding the key — is exercised below.)
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
  end

  describe "when another SESSION holds the lock (real contention, nothing stubbed)" do
    it "is excluded by Postgres itself, not by a stubbed acquire" do
      holding_lock_in_another_session(request_row.id) do
        result = ::System::FulfillmentAdvanceOrchestrator.advance!(request: request_row)

        expect(result.already_advancing).to be(true)
        expect(result.advanced).to be(false)
        expect(request_row.reload.state).to eq("approved")
      end
    end

    it "never releases a lock it does not hold" do
      expect_any_instance_of(::System::FulfillmentAdvanceOrchestrator)
        .not_to receive(:release_advance_lock!)

      holding_lock_in_another_session(request_row.id) do
        ::System::FulfillmentAdvanceOrchestrator.advance!(request: request_row)

        # The holder must still have it. A third session being refused is what
        # establishes that — the loser neither unlocked the winner's key nor
        # decremented its hold count.
        expect(lock_free_to_another_session?(request_row.id)).to be(false)
      end
    end
  end

  describe "when the lock is free" do
    it "advances and releases the lock afterwards" do
      expect_any_instance_of(::System::FulfillmentAdvanceOrchestrator)
        .to receive(:release_advance_lock!).at_least(:once).and_call_original

      result = ::System::FulfillmentAdvanceOrchestrator.advance!(request: request_row)

      expect(result.already_advancing).to be_falsey
      expect(request_row.reload.state).not_to eq("approved")
      # Released for real, not just called: a different session can take the key.
      expect(lock_free_to_another_session?(request_row.id)).to be(true)
    end

    it "releases the lock even when a phase raises" do
      allow_any_instance_of(::System::FulfillmentAdvanceOrchestrator)
        .to receive(:advance_one).and_raise(StandardError, "phase exploded")
      expect_any_instance_of(::System::FulfillmentAdvanceOrchestrator)
        .to receive(:release_advance_lock!).at_least(:once).and_call_original

      ::System::FulfillmentAdvanceOrchestrator.advance!(request: request_row)

      # A leaked session lock would wedge this request until the process died,
      # because the OTHER entrant is a different session and would be refused
      # forever. Asking a different session is what establishes the release:
      # re-taking the key on the request's own connection would return true even
      # after a leak.
      expect(lock_free_to_another_session?(request_row.id)).to be(true)
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
