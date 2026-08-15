# frozen_string_literal: true

require "rails_helper"

# IMP-391525770512 — the generic half of the replay guard.
#
# The behavioural evidence lives with the wired resource (VIP update, REST and
# MCP). What is pinned HERE is the seam itself, because every one of these
# properties is invisible to that resource's examples: it declares exactly one
# fingerprinted attribute, so nothing there can tell "fingerprints the declared
# intersection" from "fingerprints everything the request touches", and nothing
# there exercises an executor that opts OUT.
#
# Each example is written so that removing the behaviour it names turns it red
# — the parameters of a newly-extracted API are decoration until something
# fails without them.
RSpec.describe System::Executors::Base, "replay baseline" do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:peer_a)  { create(:sdwan_peer, account: account, network: network) }
  let(:peer_b)  { create(:sdwan_peer, account: account, network: network) }

  let!(:vip) do
    create(:sdwan_virtual_ip, account: account, network: network, state: "active",
                              holder_peer_ids: [ peer_a.id ], description: "before")
  end

  # A throwaway executor rather than a real one: the contract under test is
  # Base's, and binding it to a shipped executor would make these examples
  # restate that executor's declaration instead of the seam's behaviour.
  let(:fingerprinting_executor) do
    Class.new(described_class) do
      def self.replay_baseline_attributes = %i[holder_peer_ids]
      def self.name = "TestExecutors::Fingerprinting"

      def perform
        verify_replay_baseline!(::Sdwan::VirtualIp.find(params[:vip_id]))
        { ok: true }
      end
    end
  end

  let(:opted_out_executor) do
    Class.new(described_class) do
      def self.name = "TestExecutors::OptedOut"

      def perform
        verify_replay_baseline!(::Sdwan::VirtualIp.find(params[:vip_id]))
        { ok: true }
      end
    end
  end

  def run(executor, params)
    executor.execute(params, deferred_operation: nil)
    nil
  rescue StandardError => e
    e
  end

  describe ".replay_baseline" do
    it "fingerprints a declared attribute the request changes" do
      baseline = fingerprinting_executor.replay_baseline(vip, { holder_peer_ids: [ peer_b.id ] })

      expect(baseline).to eq(holder_peer_ids: [ peer_a.id ])
    end

    # "Fingerprint only what the request intends to change." Without the
    # intersection this returns the holder value for a description-only edit,
    # and any concurrent holder move would then invalidate it.
    it "omits a declared attribute the request does not touch" do
      baseline = fingerprinting_executor.replay_baseline(vip, { description: "after" })

      expect(baseline).to eq({})
    end

    # The other half of the intersection: a changed attribute nobody declared
    # replay-sensitive is not fingerprinted, so ordinary concurrent edits do
    # not start failing approvals.
    it "omits an undeclared attribute the request does change" do
      baseline = fingerprinting_executor.replay_baseline(vip, { description: "after", holder_peer_ids: [ peer_b.id ] })

      expect(baseline).to eq(holder_peer_ids: [ peer_a.id ])
    end

    it "is empty for an executor that declares nothing" do
      baseline = opted_out_executor.replay_baseline(vip, { holder_peer_ids: [ peer_b.id ] })

      expect(baseline).to eq({}), "an executor that opted out still stamped a fingerprint"
    end

    # Surfaces build these params from strong-params / MCP hashes, which arrive
    # string-keyed; a symbol-only intersection would silently fingerprint
    # nothing and the guard would never fire in production.
    it "matches string-keyed request attributes" do
      baseline = fingerprinting_executor.replay_baseline(vip, { "holder_peer_ids" => [ peer_b.id ] })

      expect(baseline).to eq(holder_peer_ids: [ peer_a.id ])
    end
  end

  describe "#verify_replay_baseline!" do
    it "proceeds when the fingerprinted value is unchanged" do
      error = run(fingerprinting_executor,
                  { vip_id: vip.id, replay_baseline: { holder_peer_ids: [ peer_a.id ] } })

      expect(error).to be_nil
    end

    it "refuses when the fingerprinted value moved" do
      error = run(fingerprinting_executor,
                  { vip_id: vip.id, replay_baseline: { holder_peer_ids: [ peer_b.id ] } })

      expect(error).to be_a(described_class::ReplayBaselineError)
      expect(error.message).to include("holder_peer_ids")
      expect(error.message).to include([ peer_b.id ].inspect), "the refusal does not name what was requested against"
      expect(error.message).to include([ peer_a.id ].inspect), "the refusal does not name what the row holds now"
    end

    # What makes the guard OPT-IN, and what keeps operations parked before a
    # surface adopted the stamp executable rather than permanently refused.
    it "proceeds when no baseline was stamped" do
      error = run(fingerprinting_executor, { vip_id: vip.id })

      expect(error).to be_nil
    end

    # A real production state (the request touched no declared attribute), but
    # a WEAK example, recorded honestly: {}.each is a no-op with or without
    # the blank? guard, so no mutation of verify_replay_baseline! turns it
    # red. Its sibling above carries the opt-in property instead — nil.each
    # raises without the guard. Kept as a scenario control, not as evidence.
    it "proceeds when the stamped baseline is empty" do
      error = run(fingerprinting_executor, { vip_id: vip.id, replay_baseline: {} })

      expect(error).to be_nil
    end

    # Keys read out of the params JSONB reach public_send, so they are
    # constrained to what the executor declared. Not caller-reachable through
    # either shipped surface today — both build the hash literally — but the
    # standing threat model for params (caller-influenced, stored verbatim,
    # replayed unvalidated) is what TENANCY_ATTRIBUTE_KEYS exists for, and
    # under it an undeclared key is a method call on the record.
    it "ignores a baseline key the executor never declared" do
      expect(vip).not_to receive(:destroy)

      error = run(fingerprinting_executor,
                  { vip_id: vip.id, replay_baseline: { description: "something else" } })

      expect(error).to be_nil, "an undeclared baseline key was compared, and refused, on its own authority"
    end

    # Through a REAL persisted operation, so the comparison runs against what
    # the JSONB column actually returns rather than an in-memory hash.
    #
    # Scope, measured rather than claimed: holder_peer_ids is a uuid[] column,
    # so the JSON round-trip is the identity for it and the PASS direction
    # alone cannot distinguish as_json from no normalization at all. The
    # refusal direction is what makes this example load-bearing — it dies when
    # the guard is disabled. An attribute whose Ruby and JSON forms genuinely
    # differ would be needed to pin the normalization itself, and none is
    # declared today.
    describe "against a persisted operation" do
      def persisted_run(baseline)
        deferred = ::Ai::DeferredOperation.create!(
          account: account, action_category: "sdwan.virtual_ip_update",
          executor_class: "Sdwan::Executors::UpdateVirtualIp",
          params: { vip_id: vip.id, attributes: { holder_peer_ids: [ peer_b.id ] },
                    replay_baseline: baseline },
          source_type: "Sdwan::VirtualIp", source_id: vip.id
        )
        reloaded = ::Ai::DeferredOperation.find(deferred.id)
        fingerprinting_executor.execute(reloaded.params, deferred_operation: reloaded)
        nil
      rescue StandardError => e
        e
      end

      it "proceeds when the persisted baseline still matches" do
        expect(persisted_run({ holder_peer_ids: [ peer_a.id ] })).to be_nil,
                                                                    "an unchanged holder value compared unequal after the JSONB round-trip"
      end

      it "refuses when the persisted baseline no longer matches" do
        expect(persisted_run({ holder_peer_ids: [ peer_b.id ] }))
          .to be_a(described_class::ReplayBaselineError)
      end
    end
  end
end
