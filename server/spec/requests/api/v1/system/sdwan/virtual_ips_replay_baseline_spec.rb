# frozen_string_literal: true

require "rails_helper"

# IMP-391525770512 — stale-attrs replay on an APPROVED gated update.
#
# gate! parks params[:attributes] verbatim at REQUEST time and the executor
# replays them whenever an approver decides — hours later. Nothing between the
# two re-reads the row, so a holder change parked against one baseline is
# applied over whatever the row holds at approval time.
#
# The concrete hazard, and the reason holder_peer_ids is wired first: manual
# failover is a SEPARATELY gated surface on this same controller, so the
# window is not theoretical. Operator A parks holder_peer_ids=[new_holder];
# a failover moves the VIP to the standby; operator B approves A's request;
# the executor writes [new_holder] anyway — silently reverting the failover
# AND recording a holder_changed VipAssignment (departed standby, arrived
# new_holder) that misrepresents what actually happened to the overlay.
#
# The approver has no way to see the divergence: the card was composed from
# the request, and the request still reads exactly as it did when parked.
RSpec.describe "Api::V1::System::Sdwan::VirtualIps replay baseline", type: :request do
  let(:user)    { user_with_permissions("system.sdwan.vips.manage", "system.sdwan.vips.read") }
  let(:account) { user.account }

  let!(:network)    { create(:sdwan_network, account: account) }
  let!(:old_holder) { create(:sdwan_peer, account: account, network: network) }
  let!(:new_holder) { create(:sdwan_peer, account: account, network: network) }
  let!(:standby)    { create(:sdwan_peer, account: account, network: network) }

  let!(:vip) do
    create(:sdwan_virtual_ip, account: account, network: network,
                              state: "active",
                              holder_peer_ids: [ old_holder.id ],
                              failover_holder_peer_ids: [ standby.id ])
  end
  let!(:current_assignment) do
    vip.assignments.create!(peer: old_holder, assumed_at: 1.hour.ago, reason: "initial")
  end

  def member_path = "/api/v1/system/sdwan/networks/#{network.id}/virtual_ips/#{vip.id}"

  def patch_update(attributes)
    patch member_path, params: { virtual_ip: attributes }.to_json,
          headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  # The intervening event: an out-of-band failover between park and approve.
  # Driven through the model's own canonical op (Sdwan::VirtualIp#failover!)
  # rather than a raw update! so the row AND its assignment history move the
  # way a real failover moves them.
  #
  # Returns the resulting holder array rather than a literal, and asserts only
  # that the PRIMARY (head) moved to the standby. failover! currently leaves
  # the demoted holder lingering in the array instead of popping it — its own
  # "pops the head" contract is broken, separately queued as IMP-43cf1e6b5541
  # — so a literal [standby.id] here would pin that defect's shape and this
  # spec would flip red when it is fixed. What this spec needs from the
  # failover is only that holder_peer_ids MOVED between park and approval.
  def failover_between!
    vip.reload.failover!(reason: "manual_failover", triggered_by_user: user)
    vip.reload.holder_peer_ids.tap do |holders|
      expect(holders.first).to eq(standby.id), "failover fixture did not promote the standby"
      expect(holders).not_to eq(baseline_holders), "failover fixture left holder_peer_ids unmoved"
    end
  end

  def baseline_holders = [ old_holder.id ]

  # Captures rather than leading with `raise_error`: an example whose first
  # assertion is raise_error aborts on "nothing was raised" and never reports
  # the effect it exists to prevent (IMP-2d26f7289c38).
  def approve_latest
    ::Ai::DeferredOperation.order(created_at: :desc).first.tap do |deferred|
      expect(deferred).to be_present, "no deferred operation was parked — the action was applied inline"
    end.execute_now!
    nil
  rescue StandardError => e
    e
  end

  describe "when the fingerprinted attribute moved between park and approval" do
    # THE red-first example. On unmodified HEAD this documents the CURRENT
    # PARKING BEHAVIOUR: the approved replay wins over the failover.
    it "refuses the replay instead of silently reverting the intervening failover" do
      patch_update(holder_peer_ids: [ new_holder.id ])
      expect(response).to have_http_status(:accepted)

      post_failover = failover_between!

      error = approve_latest

      expect(vip.reload.holder_peer_ids).to eq(post_failover),
                                            "the approved replay reverted the failover — the VIP is back on a peer no operator chose"
      expect(error).to be_a(::System::Executors::Base::ReplayBaselineError)
    end

    # The audit consequence, asserted separately: reverting the row is one
    # harm, MISREPRESENTING it in the assignment history is the other, and a
    # fix that only guarded the write would leave this one live.
    it "writes no holder_changed assignment row misattributing the revert" do
      patch_update(holder_peer_ids: [ new_holder.id ])
      failover_between!

      assignments_before = vip.reload.assignments.count

      approve_latest

      expect(vip.reload.assignments.count).to eq(assignments_before),
                                              "the refused replay still churned the assignment audit trail"
      expect(vip.assignments.where(sdwan_peer_id: new_holder.id)).to be_empty,
                                                                     "recorded a holder_changed arrival for a peer the replay never legitimately reached"
      # The standby's assignment is the one the FAILOVER opened; a replay that
      # ran would have released it.
      standby_assignment = vip.assignments.find_by(sdwan_peer_id: standby.id)
      expect(standby_assignment&.released_at).to be_nil,
                                                 "the refused replay released the assignment the failover had opened"
    end

    # The refusal must be DECLARED, not silent: an approver who clicked
    # approve has to be able to find out that nothing happened, and why.
    # Ai::ApprovalRequest#declare_execution_failure! is the core sink
    # (IMP-4bbb4227ac8a); the message is what names requested-vs-current.
    it "names the requested and current values in the refusal" do
      patch_update(holder_peer_ids: [ new_holder.id ])
      failover_between!

      error = approve_latest

      expect(error).to be_present,
                       "the approved replay was applied silently — no refusal for the approver to read"
      expect(error).to be_a(::System::Executors::Base::ReplayBaselineError)
      expect(error.message).to include("holder_peer_ids")
      # The BASELINE rendered whole. Asserting on old_holder.id alone would be
      # satisfied by a message printing only current state, because failover!
      # leaves the demoted holder in the current array too (IMP-43cf1e6b5541).
      # The single-element rendering appears only in the baseline.
      expect(error.message).to include(baseline_holders.inspect),
                               "the refusal does not say what the request was authored against"
      expect(error.message).to include(standby.id),
                              "the refusal does not say what the row holds now"
    end

    # Driven through the REAL approval decision rather than execute_now!,
    # because declare_execution_failure! hangs off
    # Ai::ApprovalRequest#notify_source_of_decision and execute_now! never
    # enters it. Asserting DeferredOperation#status alone would not pin this:
    # that is the operation's own AASM fail!, a different object and column,
    # and it reads "failed" for ANY raised error — a CrossAccountError from
    # anchor_reparent! satisfies it identically.
    it "declares the refusal on the approval request an operator sees" do
      patch_update(holder_peer_ids: [ new_holder.id ])
      post_failover = failover_between!

      request = ::Ai::DeferredOperation.order(created_at: :desc).first.approval_request
      expect(request).to be_present, "the gate parked no approval request to decide on"

      # The decision itself must still succeed — a refused replay is a
      # declared execution outcome, not a broken approval.
      expect { request.record_decision!(approver: user, decision: "approved") }.not_to raise_error

      request.reload
      expect(request.execution_status).to eq("failed"),
                                          "the approver was told nothing — the refusal left no declared outcome"
      expect(request.execution_error).to include("ReplayBaselineError")
      expect(request.execution_error).to include("holder_peer_ids")

      event = ::Ai::ExecutionEvent.find_by(source_type: "Ai::ApprovalRequest", source_id: request.id)
      expect(event).to be_present, "no operator-visible execution event for the refused replay"
      expect(event.status).to eq("failed")

      expect(vip.reload.holder_peer_ids).to eq(post_failover),
                                            "the real approval path applied the stale replay anyway"
    end

    # The pair attribute. failover! rewrites failover_holder_peer_ids in the
    # same update! as holder_peer_ids, and a parked candidate-list edit
    # replayed afterwards can name the peer that is now the PRIMARY holder —
    # after which old_holder == new_holder on the next failover and the VIP is
    # permanently unfailoverable. Declaring only holder_peer_ids leaves that
    # live, and no holder_peer_ids example can see it.
    it "refuses a stale failover-candidate replay too" do
      patch_update(failover_holder_peer_ids: [ standby.id ])
      failover_between!
      post_failover_candidates = vip.reload.failover_holder_peer_ids

      error = approve_latest

      expect(vip.reload.failover_holder_peer_ids).to eq(post_failover_candidates),
                                                     "the approved replay restored a candidate list naming the current primary holder"
      expect(error).to be_a(::System::Executors::Base::ReplayBaselineError)
      expect(error.message).to include("failover_holder_peer_ids")
    end
  end

  # CONTROLS. "No write happened" is equally satisfied by an executor that
  # stopped working at all, so each of these proves the gate is still
  # reachable and still applies through the SAME action.
  describe "controls — the guard is narrow" do
    it "applies an approved holder change when nothing moved in between" do
      patch_update(holder_peer_ids: [ new_holder.id ])

      error = approve_latest

      expect(error).to be_nil
      expect(vip.reload.holder_peer_ids).to eq([ new_holder.id ]),
                                            "the baseline guard blocked an undisturbed replay"
      arrived = vip.assignments.where(sdwan_peer_id: new_holder.id, released_at: nil).first
      expect(arrived).to be_present, "the undisturbed replay lost its assignment sync"
      expect(arrived.reason).to eq("holder_changed")
    end

    # A parked DESCRIPTION edit is not invalidated by a concurrent failover,
    # because that request never expressed an opinion about holders.
    #
    # Measured scope of this example (mutation, not inspection): it dies when
    # replay_baseline fingerprints the DECLARED attributes regardless of what
    # the request changes, and it SURVIVES an implementation that fingerprints
    # every attribute the request does change — that mutant leaves a
    # description-only edit carrying a description baseline, which a failover
    # does not disturb. So this pins "narrow with respect to the declared
    # list" only; the per-request intersection is pinned in
    # base_replay_baseline_spec.rb, which is the only place that can see it.
    it "does not refuse a request that never touched the fingerprinted attribute" do
      patch_update(description: "edge vip")
      post_failover = failover_between!

      error = approve_latest

      expect(error).to be_nil, "an unrelated concurrent failover invalidated a description edit"
      expect(vip.reload.description).to eq("edge vip")
      expect(vip.holder_peer_ids).to eq(post_failover), "the description replay disturbed the holder"
    end
  end
end
