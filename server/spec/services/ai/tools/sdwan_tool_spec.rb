# frozen_string_literal: true

require "rails_helper"

# Phase O6 — SdwanTool MCP surface.
#
# Mirrors system_fleet_tool_spec.rb's shape: invoke `.execute(params:)`
# directly and assert success_result/error_result content. Coverage here
# focuses on the 8 new Phase O6 actions that surface the O1 host-bridge,
# O3 OVN deployment + switches + ports + plan, and O5 IPFIX models so AI
# agents can compose with them.
RSpec.describe Ai::Tools::SdwanTool do
  let(:account) { create(:account) }
  let(:node)    { sdwan_test_node(account: account) }
  # This spec drives the tool as an in-process caller, which declares itself
  # with `internal: true`. A bare userless construction is no longer a
  # permission bypass — see "principal authorization (IMP-54bf2643f542)".
  let(:tool)    { described_class.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # Shared approval-gate harness (IMP-6c482005db87). Tail of the approval
  # path — Ai::ApprovalRequest ultimately calls execute_now!; the presence
  # assertion keeps a missing gate failing by name instead of as `undefined
  # method for nil`. Older gate describes below still carry local copies
  # with action-specific failure messages; the cross-file extraction is
  # queued separately (IMP-b8e8e9d6e4d9).
  def approve_latest_deferred!
    deferred = Ai::DeferredOperation.order(created_at: :desc).first
    expect(deferred).to be_present, "no deferred operation was parked — the action was applied inline"
    deferred.execute_now!
  end

  # Forces the gate's :proceed branch — the default policy resolution is
  # require_approval, so nothing else exercises the inline path.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  # IMP-c9798d9d5671 harness: resolve the parked operation by the
  # RESPONSE's own deferred_operation_id (exact — immune to the
  # two-ops-in-one-example latest-row footgun), assert its routing identity
  # (category + executor), yield it for park-shape assertions, then execute
  # it — the one approval motion every update-gate describe repeats.
  def approve_parked_update!(response, category:, executor:)
    deferred = Ai::DeferredOperation.find_by(id: response.dig(:data, :deferred_operation_id))
    expect(deferred).to be_present, "no deferred operation was parked — the update was applied inline"
    expect(deferred.action_category).to eq(category)
    expect(deferred.executor_class).to eq(executor)
    yield deferred if block_given?
    deferred.execute_now!
  end

  # IMP-c9798d9d5671 template (Angle-D): a typo'd or empty payload must
  # fail LOUD naming the permitted fields — never park a no-op approval an
  # operator has to dispose of. Consumers define gate_action and
  # noop_request (a payload whose recognized-field set is empty).
  shared_examples "a loud no-op update refusal" do
    it "refuses a payload with no recognized fields without parking anything" do
      expect {
        @result = call(gate_action, **noop_request)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(@result[:error]).to include("no recognized fields to update"),
                                 "a no-op payload must fail loud, not park an empty approval"
    end
  end

  # IMP-c9798d9d5671 template: a gated update arm answers pending WITHOUT
  # touching the row. The record-unchanged probe is part of the template so
  # no arm's describe can omit it. Consumers define gate_action,
  # gate_request, pristine_probe (lambda over the persisted value),
  # pristine_value, and pristine_failure_hint.
  shared_examples "an approval-gated sdwan update" do
    it "defers the update through the approval gate rather than writing inline" do
      r = call(gate_action, **gate_request)

      expect(r[:success]).to be true
      expect(r[:data][:pending]).to be true
      expect(instance_exec(&pristine_probe)).to eq(pristine_value), pristine_failure_hint
    end
  end

  describe ".action_definitions" do
    it "registers all 8 Phase O6 actions" do
      keys = described_class.action_definitions.keys
      %w[
        system_sdwan_create_host_bridge
        system_sdwan_list_host_bridges
        system_sdwan_create_ovn_deployment
        system_sdwan_create_ovn_logical_switch
        system_sdwan_create_ovn_logical_switch_port
        system_sdwan_compile_ovn_plan
        system_sdwan_create_ipfix_collector
        system_sdwan_list_ipfix_collectors
      ].each do |action|
        expect(keys).to include(action), "expected #{action} in action_definitions"
      end
    end

    it "registers the federation peer mutation + residency + audit actions" do
      keys = described_class.action_definitions.keys
      %w[
        system_sdwan_update_federation_peer
        system_sdwan_set_data_residency
        system_sdwan_get_audit_log
      ].each do |action|
        expect(keys).to include(action), "expected #{action} in action_definitions"
      end
    end
  end

  # ─── D8: peer firewall tags ──────────────────────────────────────────

  describe "system_sdwan_set_peer_tags" do
    let(:network)  { Sdwan::Network.create!(account_id: account.id, name: "tag-#{SecureRandom.hex(4)}") }
    let(:instance) { create(:system_node_instance, node: node, name: "ti-#{SecureRandom.hex(3)}") }
    let!(:peer)    { Sdwan::PeerEnroller.call(network: network, node_instance: instance) }

    # Value semantics ride the gate's :proceed branch since IMP-c9798d9d5671
    # (sdwan.peer_update — the approval-path behaviour has its own describe).
    it "sets + normalizes (trim/dedup/drop-blank) the peer's tags" do
      auto_approve_policy!
      r = call("system_sdwan_set_peer_tags", peer_id: peer.id, tags: [ " database ", "edge", "database", "" ])
      expect(r[:success]).to be true
      expect(r[:data][:tags]).to eq(%w[database edge])
      expect(peer.reload.tags).to eq(%w[database edge])
    end

    it "clears tags with an empty array" do
      auto_approve_policy!
      peer.update!(tags: %w[old])
      r = call("system_sdwan_set_peer_tags", peer_id: peer.id, tags: [])
      expect(r[:success]).to be true
      expect(peer.reload.tags).to eq([])
    end

    it "is registered with the peers.manage permission" do
      expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_set_peer_tags")).to eq("system.sdwan.peers.manage")
    end
  end

  # ─── IMP-1c08ab7f5ecd: v6-literal endpoint bracketing ────────────────

  describe "system_sdwan_list_peers effective_endpoint bracketing" do
    let(:network) { create(:sdwan_network, account: account) }

    it "brackets an IPv6-literal primary endpoint and leaves a hostname bare" do
      v6_hub   = create(:sdwan_peer, :hub, account: account, network: network)
      name_hub = create(:sdwan_peer, :hub, account: account, network: network,
                                           endpoint_host_v6: "edge.example.net")

      r = call("system_sdwan_list_peers", network_id: network.id)
      expect(r[:success]).to be true

      by_id = r[:data][:peers].index_by { |p| p[:id] }
      expect(by_id.fetch(v6_hub.id)[:effective_endpoint]).to eq("[fd00:abcd:1::1]:51820")
      expect(by_id.fetch(name_hub.id)[:effective_endpoint]).to eq("edge.example.net:51820")
    end
  end

  # ─── Federation peer mutation + residency + audit ────────────────────

  describe "system_sdwan_update_federation_peer" do
    let!(:peer) { create(:system_federation_peer, account: account, status: "proposed") }

    it "updates mutable fields and serializes the peer" do
      r = call(
        "system_sdwan_update_federation_peer",
        federation_peer_id: peer.id,
        remote_instance_url: "https://renamed.example.com",
        metadata: { "note" => "updated" }
      )
      expect(r[:success]).to be true
      fp = r[:data][:federation_peer]
      expect(fp[:id]).to eq(peer.id)
      expect(fp[:remote_instance_url]).to eq("https://renamed.example.com")
      expect(peer.reload.metadata["note"]).to eq("updated")
    end

    # Negative control for the trust-boundary routing below: transitions that
    # neither extend nor withdraw cross-instance trust stay inline, per the
    # REST ruling on FederationPeersController#update.
    it "applies a non-trust-boundary in-matrix transition inline (accepted → suspended)" do
      peer.update!(status: "accepted")
      expect {
        r = call("system_sdwan_update_federation_peer", federation_peer_id: peer.id, status: "suspended")
        expect(r[:success]).to be true
        expect(r[:data][:federation_peer][:status]).to eq("suspended")
      }.not_to change(Ai::DeferredOperation, :count)
      expect(peer.reload.status).to eq("suspended")
    end

    it "rejects an out-of-matrix status transition (proposed → active)" do
      r = call("system_sdwan_update_federation_peer", federation_peer_id: peer.id, status: "active")
      expect(r[:success]).to be false
      expect(r[:error]).to match(/not permitted/)
      expect(peer.reload.status).to eq("proposed")
    end

    it "rejects a peer belonging to a different account" do
      other_peer = create(:system_federation_peer, account: create(:account))
      r = call("system_sdwan_update_federation_peer", federation_peer_id: other_peer.id, status: "accepted")
      expect(r[:success]).to be false
    end
  end

  # IMP-796bde368789 — the MCP twin of the REST PATCH-status bypass
  # (bc2ef162 gated_revoke!, e655659f gated_accept!). update_federation_peer
  # wrote status via bare update! after only can_transition_to?, so
  # status:"accepted" completed the cross-instance handshake with no approval
  # gate, no signed_at, and WITHOUT consuming the Phase 11b single-use
  # acceptance token (it bypassed FederationPeer#accept! entirely);
  # status:"revoked" likewise skipped revoke!, recording no revocation_reason.
  #
  # Contract mirrored from FederationPeersController#update: token verified
  # BEFORE the gate (a doomed accept must not park an approval), accepted →
  # sdwan.federation_peer_accept → AcceptFederationPeer with the token
  # threaded, revoked → sdwan.federation_peer_revoke → RevokeFederationPeer
  # with the reason threaded. Other transitions stay inline (pinned above).
  describe "system_sdwan_update_federation_peer trust-boundary status routing (IMP-796bde368789)" do
    let!(:peer) { create(:system_federation_peer, account: account, status: "proposed") }

    # Tail of the approval path — Ai::ApprovalRequest ultimately calls
    # execute_now!. The presence assertion keeps a missing gate failing by
    # name instead of as `undefined method for nil`.
    def approve_latest_deferred!
      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "no deferred operation was parked — the status write was applied inline"
      deferred.tap(&:execute_now!)
    end

    # Forces the gate's :proceed branch. The default policy is require_approval,
    # so nothing else here covers the inline path.
    def auto_approve_policy!
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    describe "status: accepted" do
      it "defers the acceptance through the approval gate rather than completing the handshake inline" do
        r = call("system_sdwan_update_federation_peer", federation_peer_id: peer.id, status: "accepted")

        expect(r[:success]).to be true
        expect(r[:data][:pending]).to be true
        expect(peer.reload.status).to eq("proposed"),
                                      "MCP update completed the federation handshake without an approval gate"

        deferred = Ai::DeferredOperation.order(created_at: :desc).first
        expect(deferred).to be_present
        expect(deferred.action_category).to eq("sdwan.federation_peer_accept")
        expect(deferred.executor_class).to eq("Sdwan::Executors::AcceptFederationPeer")
        expect(deferred.params["federation_peer_id"]).to eq(peer.id)
      end

      # The Phase 11b single-use token is the cross-account authentication of
      # the handshake. The bare update! bypassed it entirely: the digest was
      # never verified and never consumed.
      it "refuses up front — parking nothing — when the peer requires a token and none is supplied" do
        peer.generate_acceptance_token!

        expect {
          @result = call("system_sdwan_update_federation_peer", federation_peer_id: peer.id, status: "accepted")
        }.not_to change(Ai::DeferredOperation, :count)

        expect(@result[:success]).to be false
        expect(@result[:error]).to include("acceptance_token")
        expect(peer.reload.status).to eq("proposed")
        expect(peer.acceptance_token_digest).to be_present, "the unconsumed token digest was cleared"
      end

      it "threads the verified token to the executor and consumes it on approval" do
        plaintext = peer.generate_acceptance_token!

        r = call("system_sdwan_update_federation_peer",
                 federation_peer_id: peer.id, status: "accepted", acceptance_token: plaintext)
        expect(r[:data][:pending]).to be true

        deferred = Ai::DeferredOperation.order(created_at: :desc).first
        expect(deferred.params["acceptance_token"]).to eq(plaintext),
                                                       "the token did not survive to the executor's replay params"
        # The approval-audience copy must NOT carry the plaintext token
        # (Ai::SensitiveParams filters the request_data mirror).
        expect(deferred.approval_request.request_data.dig("params", "acceptance_token")).to eq("[FILTERED]")

        approve_latest_deferred!

        peer.reload
        expect(peer.status).to eq("accepted")
        expect(peer.signed_at).to be_present, "the deferred acceptance skipped accept!'s signed_at stamp"
        expect(peer.acceptance_token_digest).to be_nil, "the single-use token was not consumed"
      end

      it "carries ride-along fields to the executor instead of writing them ahead of the approval" do
        r = call("system_sdwan_update_federation_peer",
                 federation_peer_id: peer.id, status: "accepted",
                 remote_prefix_advertisement: "fd00:aa:1::/48")
        expect(r[:data][:pending]).to be true

        expect(peer.reload.remote_prefix_advertisement).to be_nil,
                                                           "an unapproved caller edited the peer ahead of the gate"

        deferred = Ai::DeferredOperation.order(created_at: :desc).first
        expect(deferred.params.dig("attributes", "remote_prefix_advertisement")).to eq("fd00:aa:1::/48")

        approve_latest_deferred!
        peer.reload
        expect(peer.status).to eq("accepted")
        expect(peer.remote_prefix_advertisement).to eq("fd00:aa:1::/48")
      end

      it "completes the acceptance inline when the policy auto-approves" do
        auto_approve_policy!

        r = call("system_sdwan_update_federation_peer", federation_peer_id: peer.id, status: "accepted")

        expect(r[:success]).to be true
        expect(r[:data][:federation_peer][:status]).to eq("accepted")
        peer.reload
        expect(peer.status).to eq("accepted")
        expect(peer.signed_at).to be_present, "the accepted transition skipped accept!'s signed_at stamp"
      end
    end

    describe "status: revoked" do
      let!(:peer) { create(:system_federation_peer, account: account, status: "accepted") }

      it "defers the revocation through the approval gate with the reason threaded" do
        r = call("system_sdwan_update_federation_peer",
                 federation_peer_id: peer.id, status: "revoked", reason: "remote key compromised")

        expect(r[:success]).to be true
        expect(r[:data][:pending]).to be true
        expect(peer.reload.status).to eq("accepted"),
                                      "MCP update withdrew cross-instance trust without an approval gate"

        deferred = Ai::DeferredOperation.order(created_at: :desc).first
        expect(deferred).to be_present
        expect(deferred.action_category).to eq("sdwan.federation_peer_revoke")
        expect(deferred.executor_class).to eq("Sdwan::Executors::RevokeFederationPeer")
        expect(deferred.params["reason"]).to eq("remote key compromised")
      end

      it "records the revocation reason when the deferred op is approved" do
        call("system_sdwan_update_federation_peer",
             federation_peer_id: peer.id, status: "revoked", reason: "remote key compromised")
        approve_latest_deferred!

        peer.reload
        expect(peer.status).to eq("revoked")
        expect(peer.metadata["revocation_reason"]).to eq("remote key compromised"),
                                                      "the inline status write skipped revoke!'s reason recording"
      end

      # Mirrors gated_revoke!: revoked is terminal and the revoke executor
      # applies no attributes, so ride-along fields are ignored, not applied.
      it "ignores ride-along fields on the revoke arm" do
        original_url = peer.remote_instance_url

        call("system_sdwan_update_federation_peer",
             federation_peer_id: peer.id, status: "revoked",
             remote_instance_url: "https://smuggled.example.com")

        deferred = Ai::DeferredOperation.order(created_at: :desc).first
        expect(deferred.params).not_to have_key("attributes")

        approve_latest_deferred!
        peer.reload
        expect(peer.status).to eq("revoked")
        expect(peer.remote_instance_url).to eq(original_url)
      end
    end
  end

  # IMP-3a32dc649043. `generate_token: true` used to mint a single-use
  # acceptance token and hand the PLAINTEXT back in the tool result. A tool
  # return does not stop at its caller: Ai::AgentToolBridgeService appends the
  # full result JSON as a `role: "tool"` message and sends it to the model
  # provider on the next loop iteration, and its truncated preview is persisted
  # into ai_messages.processing_metadata. Ai::SensitiveParams cannot intervene
  # on either (the preview is a String, and #filter returns non-Hash input
  # unchanged). So the MCP surface is structurally incapable of delivering
  # signing material.
  #
  # The refusal is deliberately up-front rather than a silent omission: minting
  # a token that no caller can read leaves a peer that only an unreadable secret
  # can accept.
  describe "system_sdwan_propose_federation_peer token minting (IMP-3a32dc649043)" do
    # Never a real mint. The tool must refuse before reaching the model, so this
    # marker also serves as the tripwire: if it appears anywhere in the result,
    # a plaintext token reached the MCP surface.
    let(:synthetic_token) { "SYNTHETIC-NOT-A-REAL-TOKEN-000000" }
    # Counts mints without asserting on a real one. allow_any_instance_of has no
    # spy form, so the block records the call itself.
    let(:mint_calls) { [] }

    before do
      recorder = mint_calls
      token = synthetic_token
      allow_any_instance_of(::System::FederationPeer)
        .to receive(:generate_acceptance_token!) do |_peer, **_kwargs|
          recorder << true
          token
        end
    end

    def propose(**rest)
      call("system_sdwan_propose_federation_peer",
           remote_instance_url: "https://peer.example.test", **rest)
    end

    context "with generate_token: true" do
      it "refuses instead of returning the plaintext under any key" do
        r = propose(generate_token: true)

        expect(r.to_json).not_to include(synthetic_token),
                                 "a plaintext acceptance token reached the MCP tool result"
        expect(r[:success]).to be false
      end

      it "names the operator path that can deliver the token" do
        r = propose(generate_token: true)

        expect(r[:error]).to include("generate_token")
        expect(r[:error]).to include("/api/v1/system/sdwan/federation_peers"),
                             "the refusal does not tell the caller where the token CAN be obtained"
      end

      # Fail loud, not silently strand: a peer minted with a token nobody can
      # read is worse than no peer at all, because the digest is the only thing
      # that can accept it.
      it "mints nothing and creates no peer" do
        expect { propose(generate_token: true) }.not_to change(::System::FederationPeer, :count)

        expect(mint_calls).to be_empty, "a token was minted and then withheld, stranding the peer"
      end

      # Nothing on the MCP path coerces booleans, and models routinely serialize
      # a boolean argument as a string. A refusal that `"true"` walks past is not
      # a refusal — the caller would get success: true and a digest-less peer,
      # which System::FederationPeer#acceptance_token_error treats as needing no
      # token at all.
      it "refuses the string form the JSON boundary produces" do
        expect { @r = propose(generate_token: "true") }.not_to change(::System::FederationPeer, :count)

        expect(@r[:success]).to be false
        expect(@r[:error]).to include("/api/v1/system/sdwan/federation_peers")
      end
    end

    # Guard: the refusal is scoped to the token, not to the action. Proposing a
    # peer over MCP still works — this is what keeps the fix from reading as a
    # removal of the capability.
    context "without a token request" do
      it "still proposes the peer when generate_token is omitted" do
        expect { @r = propose }.to change(::System::FederationPeer, :count).by(1)

        expect(@r[:success]).to be true
        expect(@r[:data][:federation_peer][:status]).to eq("proposed")
      end

      it "still proposes the peer when generate_token is explicitly false" do
        r = propose(generate_token: false)

        expect(r[:success]).to be true
        expect(::System::FederationPeer.last.acceptance_token_digest).to be_nil
      end
    end

    # Guard: the operator path is untouched. Sdwan::Executors::ProposeFederationPeer
    # is what FederationPeersController#create drives through Ai::AutonomyGate,
    # and its return carries the one reveal. On the ordinary branch — the default
    # policy is require_approval, and Ai::ApprovalChain is defined in core so the
    # gate never short-circuits — that return is handed to
    # Ai::DeferredOperation#take_revealed_result! and read by
    # Ai::ApprovalRequest#capture_revealed_result!, reaching the operator on the
    # approval decision response.
    #
    # Mints for real (overriding the outer stub) so this cannot degrade into
    # "the executor returns whatever the stub was given": the returned plaintext
    # has to verify against the digest the peer actually stored.
    it "leaves the operator executor path delivering a plaintext that verifies" do
      allow_any_instance_of(::System::FederationPeer)
        .to receive(:generate_acceptance_token!).and_call_original

      result = ::Sdwan::Executors::ProposeFederationPeer.execute(
        { attributes: { remote_instance_url: "https://peer.example.test" } },
        deferred_operation: instance_double(::Ai::DeferredOperation, account: account)
      )
      delivered = result[:data][:acceptance_token_plaintext]
      peer = ::System::FederationPeer.find(result[:data][:federation_peer_id])

      expect(delivered).to be_present, "the operator delivery path stopped returning the token"
      expect(peer.acceptance_token_error(delivered)).to be_nil,
                                                       "the delivered plaintext does not verify against the stored digest"
      expect(peer.acceptance_token_digest).to be_present
      expect(peer.acceptance_token_digest).not_to eq(delivered), "the peer stored the plaintext, not a digest"
    end
  end

  # This tool already threaded `reason` into FederationPeer#revoke!, but its
  # peer serializer projected no metadata — so the reason it advertises as
  # "recorded on the peer" could not be read back through any MCP action
  # (revoke's own response, get, or list). IMP-8ce2d82065b9.
  describe "system_sdwan_revoke_federation_peer" do
    let!(:peer) { create(:system_federation_peer, account: account, status: "accepted") }

    it "records the reason and surfaces it in the serialized peer" do
      r = call("system_sdwan_revoke_federation_peer",
               federation_peer_id: peer.id,
               reason: "remote signing key compromised")

      expect(r[:success]).to be true
      fp = r[:data][:federation_peer]
      expect(fp[:status]).to eq("revoked")
      expect(fp[:revocation_reason]).to eq("remote signing key compromised")
      expect(peer.reload.metadata["revocation_reason"]).to eq("remote signing key compromised")
    end

    it "reports a nil revocation_reason for a peer revoked without one" do
      r = call("system_sdwan_revoke_federation_peer", federation_peer_id: peer.id)

      expect(r[:success]).to be true
      expect(r[:data][:federation_peer]).to have_key(:revocation_reason)
      expect(r[:data][:federation_peer][:revocation_reason]).to be_nil
    end

    it "rejects a peer belonging to a different account" do
      other_peer = create(:system_federation_peer, account: create(:account), status: "accepted")
      r = call("system_sdwan_revoke_federation_peer", federation_peer_id: other_peer.id, reason: "x")

      expect(r[:success]).to be false
      expect(other_peer.reload.status).to eq("accepted")
    end
  end

  describe "system_sdwan_set_data_residency" do
    let!(:peer) { create(:system_federation_peer, account: account) }

    it "sets the data_residency tag and surfaces it in the serializer" do
      r = call("system_sdwan_set_data_residency", federation_peer_id: peer.id, data_residency: "eu-west")
      expect(r[:success]).to be true
      expect(r[:data][:federation_peer][:data_residency]).to eq("eu-west")
      expect(peer.reload.data_residency).to eq("eu-west")
    end

    it "rejects a peer belonging to a different account" do
      other_peer = create(:system_federation_peer, account: create(:account))
      r = call("system_sdwan_set_data_residency", federation_peer_id: other_peer.id, data_residency: "eu-west")
      expect(r[:success]).to be false
    end
  end

  describe "system_sdwan_get_audit_log" do
    let!(:peer) { create(:system_federation_peer, account: account) }

    it "returns audit shipments (non-secret fields) and federation events for the peer" do
      shipment = ::System::FederationAuditShipment.create!(
        account: account,
        federation_peer: peer,
        period_start: 2.days.ago,
        period_end: 1.day.ago,
        event_count: 3,
        sha256: "a" * 64,
        sealed_path: "/worm/secret-path.jsonl",
        status: "sealed"
      )
      event = ::System::FleetEvent.create!(
        account: account,
        kind: "federation.peer.accepted",
        severity: "low",
        source: "federation_peer",
        payload: { "federation_peer_id" => peer.id }
      )

      r = call("system_sdwan_get_audit_log", federation_peer_id: peer.id)
      expect(r[:success]).to be true

      shipments = r[:data][:audit_shipments]
      expect(shipments.map { |s| s[:id] }).to include(shipment.id)
      shipment_row = shipments.find { |s| s[:id] == shipment.id }
      expect(shipment_row[:event_count]).to eq(3)
      expect(shipment_row[:status]).to eq("sealed")
      # Secret fields are not surfaced.
      expect(shipment_row).not_to have_key(:sealed_path)
      expect(shipment_row).not_to have_key(:error_message)

      expect(r[:data][:events].map { |e| e[:id] }).to include(event.id)
    end

    it "excludes events that don't reference this peer" do
      other_peer = create(:system_federation_peer, account: account)
      ::System::FleetEvent.create!(
        account: account,
        kind: "federation.peer.accepted",
        severity: "low",
        source: "federation_peer",
        payload: { "federation_peer_id" => other_peer.id }
      )

      r = call("system_sdwan_get_audit_log", federation_peer_id: peer.id)
      expect(r[:success]).to be true
      expect(r[:data][:events]).to be_empty
    end

    it "honors the limit param" do
      3.times do
        ::System::FleetEvent.create!(
          account: account,
          kind: "federation.peer.heartbeat",
          severity: "low",
          source: "federation_peer",
          payload: { "federation_peer_id" => peer.id }
        )
      end
      r = call("system_sdwan_get_audit_log", federation_peer_id: peer.id, limit: 2)
      expect(r[:success]).to be true
      expect(r[:data][:events].size).to eq(2)
    end

    # IMP-a9fbf64c3e7a. Every other example in this block fabricates its
    # FleetEvent with the payload key the reader already queries, so they
    # exercise the reader against a synthetic writer and cannot see a
    # writer/reader key mismatch. This one drives the REAL writer:
    # FederationPeer#broadcast_status_transition! → #broadcast_peer_state!,
    # fired by the after_update callback. Revocation is the transition an
    # operator opens the audit log to explain, and it is severity "high".
    it "returns the peer-state event the model itself emits on revocation" do
      platform_peer = create(:system_federation_peer, :active, account: account)
      platform_peer.revoke!(reason: "operator drill")

      emitted = ::System::FleetEvent.where(account: account, kind: "federation.peer.revoked").last
      expect(emitted).to be_present,
                         "expected FederationPeer#revoke! to emit a federation.peer.revoked FleetEvent"

      r = call("system_sdwan_get_audit_log", federation_peer_id: platform_peer.id)
      expect(r[:success]).to be true
      expect(r[:data][:events].map { |e| e[:id] }).to include(emitted.id),
                                                      "model-emitted peer-state events are missing from get_audit_log — " \
                                                      "broadcast_peer_state! stamps payload #{emitted.payload.keys.sort.inspect}, " \
                                                      "the query filters on federation_peer_id"
    end

    it "rejects a peer belonging to a different account" do
      other_peer = create(:system_federation_peer, account: create(:account))
      r = call("system_sdwan_get_audit_log", federation_peer_id: other_peer.id)
      expect(r[:success]).to be false
    end
  end

  # ─── Phase O6 — host bridges (O1) ────────────────────────────────────

  describe "system_sdwan_create_host_bridge" do
    let(:host) { sdwan_test_node_instance(node: node) }

    it "allocates a HostBridge for the given host (lightweight host → linux kind)" do
      r = call("system_sdwan_create_host_bridge", node_instance_id: host.id)
      expect(r[:success]).to be true
      bridge = r[:data][:host_bridge]
      expect(bridge[:node_instance_id]).to eq(host.id)
      expect(bridge[:account_id]).to eq(account.id)
      expect(bridge[:short_id]).to eq(1)
      expect(bridge[:bridge_name]).to eq("pwnbr-1")
      expect(bridge[:kind]).to eq("linux")
      expect(bridge[:state]).to eq("pending")
    end

    it "honors an explicit kind override" do
      r = call("system_sdwan_create_host_bridge", node_instance_id: host.id, kind: "ovs")
      expect(r[:success]).to be true
      expect(r[:data][:host_bridge][:kind]).to eq("ovs")
    end

    it "is idempotent — repeated allocations return the same bridge for the same kind" do
      r1 = call("system_sdwan_create_host_bridge", node_instance_id: host.id)
      r2 = call("system_sdwan_create_host_bridge", node_instance_id: host.id)
      expect(r1[:data][:host_bridge][:id]).to eq(r2[:data][:host_bridge][:id])
    end

    it "rejects a host belonging to a different account" do
      other_account = create(:account)
      other_node = sdwan_test_node(account: other_account)
      other_host = sdwan_test_node_instance(node: other_node)
      r = call("system_sdwan_create_host_bridge", node_instance_id: other_host.id)
      expect(r[:success]).to be false
    end
  end

  describe "system_sdwan_list_host_bridges" do
    let(:host) { sdwan_test_node_instance(node: node) }

    it "lists bridges scoped to the current account" do
      created = call("system_sdwan_create_host_bridge", node_instance_id: host.id)
      expect(created[:success]).to be true
      created_id = created[:data][:host_bridge][:id]

      r = call("system_sdwan_list_host_bridges")
      expect(r[:success]).to be true
      ids = r[:data][:host_bridges].map { |b| b[:id] }
      expect(ids).to include(created_id)
      expect(r[:data][:count]).to be >= 1
    end

    it "filters by node_instance_id when provided" do
      host_a = sdwan_test_node_instance(node: node, name: "host-a")
      host_b = sdwan_test_node_instance(node: node, name: "host-b")
      call("system_sdwan_create_host_bridge", node_instance_id: host_a.id)
      call("system_sdwan_create_host_bridge", node_instance_id: host_b.id)

      r = call("system_sdwan_list_host_bridges", node_instance_id: host_a.id)
      expect(r[:success]).to be true
      ids = r[:data][:host_bridges].map { |b| b[:node_instance_id] }
      expect(ids).to all(eq(host_a.id))
    end

    it "excludes bridges from other accounts" do
      other_account = create(:account)
      other_node = sdwan_test_node(account: other_account)
      other_host = sdwan_test_node_instance(node: other_node)
      ::Sdwan::HostBridgeAllocator.allocate!(host: other_host, account: other_account)

      r = call("system_sdwan_list_host_bridges")
      account_ids = r[:data][:host_bridges].map { |b| b[:account_id] }.uniq
      expect(account_ids).not_to include(other_account.id)
    end
  end

  describe "system_sdwan_activate_host_bridge" do
    let(:host) { sdwan_test_node_instance(node: node) }
    let!(:bridge) { ::Sdwan::HostBridgeAllocator.allocate!(host: host, account: account) }

    it "marks a pending bridge active" do
      expect(bridge.state).to eq("pending")
      r = call("system_sdwan_activate_host_bridge", id: bridge.id)
      expect(r[:success]).to be true
      expect(r[:data][:host_bridge][:state]).to eq("active")
      expect(bridge.reload.state).to eq("active")
    end

    it "rejects a bridge from another account" do
      other_account = create(:account)
      other_node = sdwan_test_node(account: other_account)
      other_host = sdwan_test_node_instance(node: other_node)
      other_bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: other_host, account: other_account)
      r = call("system_sdwan_activate_host_bridge", id: other_bridge.id)
      expect(r[:success]).to be false
    end

    it "reports an error instead of silently no-op'ing on a removed bridge" do
      bridge.mark_removed!
      r = call("system_sdwan_activate_host_bridge", id: bridge.id)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/readopt/)
      expect(bridge.reload.state).to eq("removed")
    end
  end

  # ─── Phase O6 — OVN deployment + switches + ports + plan (O3) ────────

  describe "system_sdwan_create_ovn_deployment" do
    it "creates an OvnDeployment with required endpoints" do
      r = call(
        "system_sdwan_create_ovn_deployment",
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642",
        northd_host: "northd-host-1"
      )
      expect(r[:success]).to be true
      deployment = r[:data][:ovn_deployment]
      expect(deployment[:account_id]).to eq(account.id)
      expect(deployment[:nb_db_endpoint]).to eq("tcp:nb.example:6641")
      expect(deployment[:sb_db_endpoint]).to eq("tcp:sb.example:6642")
      expect(deployment[:northd_host]).to eq("northd-host-1")
      expect(deployment[:status]).to eq("pending")
    end

    it "rejects a malformed endpoint" do
      r = call(
        "system_sdwan_create_ovn_deployment",
        nb_db_endpoint: "not-a-real-endpoint",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
      expect(r[:success]).to be false
      expect(r[:error]).to match(/nb db endpoint|invalid/i)
    end

    it "is per-account unique — second create surfaces a validation error" do
      call(
        "system_sdwan_create_ovn_deployment",
        nb_db_endpoint: "tcp:nb1.example:6641",
        sb_db_endpoint: "tcp:sb1.example:6642"
      )
      r2 = call(
        "system_sdwan_create_ovn_deployment",
        nb_db_endpoint: "tcp:nb2.example:6641",
        sb_db_endpoint: "tcp:sb2.example:6642"
      )
      expect(r2[:success]).to be false
    end
  end

  describe "system_sdwan_create_ovn_logical_switch" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end

    it "creates a logical switch under the deployment" do
      r = call(
        "system_sdwan_create_ovn_logical_switch",
        deployment_id: deployment.id,
        name: "tenant-switch",
        cidr: "10.42.0.0/24",
        description: "Phase O6 smoke switch"
      )
      expect(r[:success]).to be true
      switch = r[:data][:ovn_logical_switch]
      expect(switch[:deployment_id]).to eq(deployment.id)
      expect(switch[:name]).to eq("tenant-switch")
      expect(switch[:cidr]).to eq("10.42.0.0/24")
      expect(switch[:state]).to eq("pending")
    end

    it "rejects an invalid name" do
      r = call(
        "system_sdwan_create_ovn_logical_switch",
        deployment_id: deployment.id,
        name: "has spaces and ! chars"
      )
      expect(r[:success]).to be false
    end

    it "rejects a deployment from another account" do
      other_account = create(:account)
      other_deployment = ::Sdwan::OvnDeployment.create!(
        account: other_account,
        nb_db_endpoint: "tcp:nb.other:6641",
        sb_db_endpoint: "tcp:sb.other:6642"
      )
      r = call(
        "system_sdwan_create_ovn_logical_switch",
        deployment_id: other_deployment.id,
        name: "leakage"
      )
      expect(r[:success]).to be false
    end
  end

  describe "system_sdwan_create_ovn_logical_switch_port" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end
    let!(:switch) do
      deployment.logical_switches.create!(account: account, name: "lsw-1")
    end
    let(:host) { sdwan_test_node_instance(node: node) }

    it "creates a vm-kind port with auto-generated MAC" do
      r = call(
        "system_sdwan_create_ovn_logical_switch_port",
        logical_switch_id: switch.id,
        name: "vm-port-1",
        kind: "vm",
        host_node_instance_id: host.id,
        addresses: [ "10.42.0.5" ]
      )
      expect(r[:success]).to be true
      port = r[:data][:ovn_logical_switch_port]
      expect(port[:logical_switch_id]).to eq(switch.id)
      expect(port[:name]).to eq("vm-port-1")
      expect(port[:kind]).to eq("vm")
      expect(port[:host_node_instance_id]).to eq(host.id)
      expect(port[:addresses]).to eq([ "10.42.0.5" ])
      # Auto-gen MAC starts with the locally-administered `02:` prefix.
      expect(port[:mac]).to match(/\A02:[0-9a-f]{2}(:[0-9a-f]{2}){4}\z/)
    end

    it "respects an explicit MAC override" do
      r = call(
        "system_sdwan_create_ovn_logical_switch_port",
        logical_switch_id: switch.id,
        name: "vm-port-2",
        kind: "vm",
        host_node_instance_id: host.id,
        mac: "02:aa:bb:cc:dd:ee"
      )
      expect(r[:success]).to be true
      expect(r[:data][:ovn_logical_switch_port][:mac]).to eq("02:aa:bb:cc:dd:ee")
    end

    it "creates an external port without a host" do
      r = call(
        "system_sdwan_create_ovn_logical_switch_port",
        logical_switch_id: switch.id,
        name: "uplink-1",
        kind: "external"
      )
      expect(r[:success]).to be true
      expect(r[:data][:ovn_logical_switch_port][:kind]).to eq("external")
      expect(r[:data][:ovn_logical_switch_port][:host_node_instance_id]).to be_nil
    end

    it "rejects an invalid kind via model validation" do
      r = call(
        "system_sdwan_create_ovn_logical_switch_port",
        logical_switch_id: switch.id,
        name: "bad-kind",
        kind: "router"
      )
      expect(r[:success]).to be false
    end
  end

  # IMP-b0292ddd5ee9 — create_ovn_logical_switch / create_ovn_logical_switch_port
  # land rows in `pending` (matching create_host_bridge's design) but, unlike
  # host bridges, had no activation path via MCP: no tool ever called
  # switch.mark_active!/port.mark_active!, so the documented create -> compile
  # sequence silently produced an empty plan with zero errors.
  describe "the documented create -> compile sequence" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end

    it "materializes the plan once the switch and port are activated via the tool" do
      switch_r = call(
        "system_sdwan_create_ovn_logical_switch",
        deployment_id: deployment.id,
        name: "trap-switch"
      )
      switch_id = switch_r[:data][:ovn_logical_switch][:id]

      port_r = call(
        "system_sdwan_create_ovn_logical_switch_port",
        logical_switch_id: switch_id,
        name: "trap-port",
        kind: "external"
      )
      port_id = port_r[:data][:ovn_logical_switch_port][:id]

      # Before activation: the trap. Zero errors, but nothing compiles.
      empty_plan = call("system_sdwan_compile_ovn_plan", deployment_id: deployment.id)
      expect(empty_plan[:success]).to be true
      expect(empty_plan[:data][:plan][:plan]).to eq([])

      switch_activation = call("system_sdwan_activate_ovn_logical_switch", logical_switch_id: switch_id)
      expect(switch_activation[:success]).to be true
      expect(switch_activation[:data][:ovn_logical_switch][:state]).to eq("active")

      port_activation = call("system_sdwan_activate_ovn_logical_switch_port", port_id: port_id)
      expect(port_activation[:success]).to be true
      expect(port_activation[:data][:ovn_logical_switch_port][:state]).to eq("active")

      plan = call("system_sdwan_compile_ovn_plan", deployment_id: deployment.id)
      cmds = plan[:data][:plan][:plan].map { |e| e[:cmd] }
      expect(cmds).to include("ls-add", "lsp-add")
    end
  end

  describe "system_sdwan_activate_ovn_logical_switch" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end
    let!(:switch) { deployment.logical_switches.create!(account: account, name: "activate-me") }

    it "marks a pending switch active" do
      expect(switch.state).to eq("pending")
      r = call("system_sdwan_activate_ovn_logical_switch", logical_switch_id: switch.id)
      expect(r[:success]).to be true
      expect(r[:data][:ovn_logical_switch][:state]).to eq("active")
      expect(switch.reload.state).to eq("active")
    end

    it "rejects a switch from another account" do
      other_account = create(:account)
      other_deployment = ::Sdwan::OvnDeployment.create!(
        account: other_account,
        nb_db_endpoint: "tcp:nb.other:6641",
        sb_db_endpoint: "tcp:sb.other:6642"
      )
      other_switch = other_deployment.logical_switches.create!(account: other_account, name: "not-mine")
      r = call("system_sdwan_activate_ovn_logical_switch", logical_switch_id: other_switch.id)
      expect(r[:success]).to be false
    end

    it "reports an error instead of silently no-op'ing on a removed switch" do
      switch.mark_removed!
      r = call("system_sdwan_activate_ovn_logical_switch", logical_switch_id: switch.id)
      expect(r[:success]).to be false
      expect(switch.reload.state).to eq("removed")
    end
  end

  describe "system_sdwan_activate_ovn_logical_switch_port" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end
    let!(:switch) { deployment.logical_switches.create!(account: account, name: "port-parent") }
    let!(:port) do
      switch.ports.create!(account: account, name: "activate-me", kind: "external")
    end

    it "marks a pending port active" do
      expect(port.state).to eq("pending")
      r = call("system_sdwan_activate_ovn_logical_switch_port", port_id: port.id)
      expect(r[:success]).to be true
      expect(r[:data][:ovn_logical_switch_port][:state]).to eq("active")
      expect(port.reload.state).to eq("active")
    end

    it "rejects a port from another account" do
      other_account = create(:account)
      other_deployment = ::Sdwan::OvnDeployment.create!(
        account: other_account,
        nb_db_endpoint: "tcp:nb.other:6641",
        sb_db_endpoint: "tcp:sb.other:6642"
      )
      other_switch = other_deployment.logical_switches.create!(account: other_account, name: "not-mine")
      other_port = other_switch.ports.create!(account: other_account, name: "not-mine", kind: "external")
      r = call("system_sdwan_activate_ovn_logical_switch_port", port_id: other_port.id)
      expect(r[:success]).to be false
    end

    it "reports an error instead of silently no-op'ing on a removed port" do
      port.mark_removed!
      r = call("system_sdwan_activate_ovn_logical_switch_port", port_id: port.id)
      expect(r[:success]).to be false
      expect(port.reload.state).to eq("removed")
    end
  end

  describe "system_sdwan_compile_ovn_plan" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end
    let!(:switch) do
      sw = deployment.logical_switches.create!(account: account, name: "compiled-sw")
      sw.mark_active!
      sw
    end
    let!(:port) do
      p = switch.ports.create!(
        account: account,
        name: "compiled-port",
        kind: "vm",
        addresses: [ "10.42.0.7" ]
      )
      p.mark_active!
      p
    end

    it "returns the structured ovn-nbctl command plan" do
      r = call("system_sdwan_compile_ovn_plan", deployment_id: deployment.id)
      expect(r[:success]).to be true
      plan = r[:data][:plan]
      expect(plan[:deployment_id]).to eq(deployment.id)
      expect(plan[:plan]).to be_an(Array)
      expect(plan[:compiled_at]).to be_present

      cmds = plan[:plan].map { |e| e[:cmd] }
      expect(cmds).to include("ls-add", "lsp-add", "lsp-set-addresses")

      ls_add = plan[:plan].find { |e| e[:cmd] == "ls-add" }
      expect(ls_add[:args]).to eq([ "compiled-sw" ])

      lsp_add = plan[:plan].find { |e| e[:cmd] == "lsp-add" }
      expect(lsp_add[:args]).to eq([ "compiled-sw", "compiled-port" ])
    end

    it "rejects a deployment from another account" do
      other_account = create(:account)
      other_deployment = ::Sdwan::OvnDeployment.create!(
        account: other_account,
        nb_db_endpoint: "tcp:nb.other:6641",
        sb_db_endpoint: "tcp:sb.other:6642"
      )
      r = call("system_sdwan_compile_ovn_plan", deployment_id: other_deployment.id)
      expect(r[:success]).to be false
    end
  end

  # ─── Audit F8-06 — OVN read/prune symmetry ──────────────────────────
  # create/delete existed for deployments + switches, and create-only for
  # ports, with no way to REDISCOVER a deployment id after a session
  # restart or PRUNE a single port. These four close the gaps.
  describe "OVN read + port-prune symmetry (F8-06)" do
    let!(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account: account,
        nb_db_endpoint: "tcp:nb.example:6641",
        sb_db_endpoint: "tcp:sb.example:6642"
      )
    end
    let!(:switch) { deployment.logical_switches.create!(account: account, name: "sw-1") }
    let!(:port) do
      switch.ports.create!(account: account, name: "port-1", kind: "vm", addresses: [ "10.42.0.7" ])
    end

    describe "system_sdwan_list_ovn_deployments" do
      it "lists the account's deployments for rediscovery" do
        r = call("system_sdwan_list_ovn_deployments")
        expect(r[:success]).to be true
        expect(r[:data][:ovn_deployments].map { |d| d[:id] }).to include(deployment.id)
      end

      it "does not leak other accounts' deployments" do
        other = create(:account)
        ::Sdwan::OvnDeployment.create!(account: other, nb_db_endpoint: "tcp:nb.o:6641", sb_db_endpoint: "tcp:sb.o:6642")
        r = call("system_sdwan_list_ovn_deployments")
        expect(r[:data][:ovn_deployments].map { |d| d[:account_id] }.uniq).to eq([ account.id ])
      end
    end

    describe "system_sdwan_get_ovn_deployment" do
      it "returns the deployment with its logical switches" do
        r = call("system_sdwan_get_ovn_deployment", deployment_id: deployment.id)
        expect(r[:success]).to be true
        expect(r[:data][:ovn_deployment][:id]).to eq(deployment.id)
        expect(r[:data][:ovn_deployment][:logical_switches].map { |s| s[:id] }).to include(switch.id)
      end

      it "rejects a deployment from another account" do
        other = create(:account)
        foreign = ::Sdwan::OvnDeployment.create!(account: other, nb_db_endpoint: "tcp:nb.o:6641", sb_db_endpoint: "tcp:sb.o:6642")
        r = call("system_sdwan_get_ovn_deployment", deployment_id: foreign.id)
        expect(r[:success]).to be false
      end
    end

    describe "system_sdwan_list_ovn_logical_switches" do
      it "lists switches and surfaces their ports so port ids are discoverable" do
        r = call("system_sdwan_list_ovn_logical_switches")
        expect(r[:success]).to be true
        sw = r[:data][:ovn_logical_switches].find { |s| s[:id] == switch.id }
        expect(sw).to be_present
        expect(sw[:ports].map { |p| p[:id] }).to include(port.id)
      end

      it "filters by deployment_id" do
        # OvnDeployment is one-per-account, so exercise the filter with a
        # second switch under the same deployment + a non-matching id.
        switch2 = deployment.logical_switches.create!(account: account, name: "sw-2")

        matched = call("system_sdwan_list_ovn_logical_switches", deployment_id: deployment.id)
        expect(matched[:data][:ovn_logical_switches].map { |s| s[:id] }).to contain_exactly(switch.id, switch2.id)

        none = call("system_sdwan_list_ovn_logical_switches", deployment_id: SecureRandom.uuid)
        expect(none[:data][:ovn_logical_switches]).to be_empty
      end
    end

    describe "system_sdwan_delete_ovn_logical_switch_port" do
      it "prunes a single port without touching the switch" do
        r = call("system_sdwan_delete_ovn_logical_switch_port", port_id: port.id)
        expect(r[:success]).to be true
        expect(r[:data][:deleted]).to be true
        expect(Sdwan::OvnLogicalSwitchPort.exists?(port.id)).to be false
        expect(Sdwan::OvnLogicalSwitch.exists?(switch.id)).to be true
      end

      it "rejects a port from another account" do
        other = create(:account)
        od = ::Sdwan::OvnDeployment.create!(account: other, nb_db_endpoint: "tcp:nb.o:6641", sb_db_endpoint: "tcp:sb.o:6642")
        os = od.logical_switches.create!(account: other, name: "sw-o")
        op = os.ports.create!(account: other, name: "port-o", kind: "vm", addresses: [ "10.9.0.1" ])
        r = call("system_sdwan_delete_ovn_logical_switch_port", port_id: op.id)
        expect(r[:success]).to be false
        expect(Sdwan::OvnLogicalSwitchPort.exists?(op.id)).to be true
      end
    end

    describe "system_sdwan_delete_ovn_deployment" do
      it "destroys the deployment without raising (model has no name column)" do
        r = call("system_sdwan_delete_ovn_deployment", deployment_id: deployment.id)
        expect(r[:success]).to be true
        expect(r[:data][:deleted]).to be true
        expect(Sdwan::OvnDeployment.exists?(deployment.id)).to be false
      end

      it "rejects a deployment from another account" do
        other = create(:account)
        foreign = ::Sdwan::OvnDeployment.create!(account: other, nb_db_endpoint: "tcp:nb.o:6641", sb_db_endpoint: "tcp:sb.o:6642")
        r = call("system_sdwan_delete_ovn_deployment", deployment_id: foreign.id)
        expect(r[:success]).to be false
        expect(Sdwan::OvnDeployment.exists?(foreign.id)).to be true
      end
    end

    describe "permission + registration" do
      it "maps read actions to system.sdwan.ovn.read and delete to system.sdwan.ovn.manage" do
        expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_list_ovn_deployments")).to eq("system.sdwan.ovn.read")
        expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_get_ovn_deployment")).to eq("system.sdwan.ovn.read")
        expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_list_ovn_logical_switches")).to eq("system.sdwan.ovn.read")
        expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_delete_ovn_logical_switch_port")).to eq("system.sdwan.ovn.manage")
      end

      it "documents all four in action_definitions" do
        defs = described_class.action_definitions
        %w[system_sdwan_list_ovn_deployments system_sdwan_get_ovn_deployment
           system_sdwan_list_ovn_logical_switches system_sdwan_delete_ovn_logical_switch_port].each do |a|
          expect(defs).to have_key(a)
        end
      end
    end
  end

  # ─── Phase O6 — IPFIX collectors (O5) ────────────────────────────────

  describe "system_sdwan_create_ipfix_collector" do
    it "creates an IPFIX collector with defaults" do
      r = call(
        "system_sdwan_create_ipfix_collector",
        name: "primary",
        host: "10.0.0.50"
      )
      expect(r[:success]).to be true
      collector = r[:data][:ipfix_collector]
      expect(collector[:name]).to eq("primary")
      expect(collector[:host]).to eq("10.0.0.50")
      expect(collector[:port]).to eq(4739)
      expect(collector[:sampling_rate]).to eq(1)
      expect(collector[:state]).to eq("active")
      expect(collector[:target_endpoint]).to eq("10.0.0.50:4739")
    end

    it "honors explicit port and sampling_rate" do
      r = call(
        "system_sdwan_create_ipfix_collector",
        name: "high-rate",
        host: "10.0.0.51",
        port: 9995,
        sampling_rate: 100
      )
      expect(r[:success]).to be true
      expect(r[:data][:ipfix_collector][:port]).to eq(9995)
      expect(r[:data][:ipfix_collector][:sampling_rate]).to eq(100)
      expect(r[:data][:ipfix_collector][:target_endpoint]).to eq("10.0.0.51:9995")
    end

    it "brackets IPv6 host literals in target_endpoint" do
      r = call(
        "system_sdwan_create_ipfix_collector",
        name: "v6-collector",
        host: "fd00::1"
      )
      expect(r[:success]).to be true
      expect(r[:data][:ipfix_collector][:target_endpoint]).to eq("[fd00::1]:4739")
    end

    it "rejects duplicate names within the same account" do
      call("system_sdwan_create_ipfix_collector", name: "dup", host: "10.0.0.52")
      r = call("system_sdwan_create_ipfix_collector", name: "dup", host: "10.0.0.53")
      expect(r[:success]).to be false
    end
  end

  describe "system_sdwan_list_ipfix_collectors" do
    it "lists collectors scoped to the current account" do
      call("system_sdwan_create_ipfix_collector", name: "list-1", host: "10.0.0.60")
      call("system_sdwan_create_ipfix_collector", name: "list-2", host: "10.0.0.61")

      r = call("system_sdwan_list_ipfix_collectors")
      expect(r[:success]).to be true
      names = r[:data][:ipfix_collectors].map { |c| c[:name] }
      expect(names).to include("list-1", "list-2")
      expect(r[:data][:count]).to be >= 2
    end

    it "excludes collectors from other accounts" do
      other_account = create(:account)
      ::Sdwan::IpfixCollector.create!(
        account: other_account, name: "other-acct", host: "10.0.0.70"
      )

      r = call("system_sdwan_list_ipfix_collectors")
      account_ids = r[:data][:ipfix_collectors].map { |c| c[:account_id] }.uniq
      expect(account_ids).not_to include(other_account.id)
    end
  end

  # ─── Campaign 019f3458 increment 6: hardened DNAT tier param wiring ───

  describe "system_sdwan_create_port_mapping (hardening params)" do
    let(:network)    { create(:sdwan_network, account: account) }
    let(:hub_peer)   { create(:sdwan_peer, :hub, account: account, network: network) }
    let(:target)     { create(:sdwan_peer, account: account, network: network) }

    it "accepts rate_limit, max_connections, and source_cidrs and surfaces them on the full serializer" do
      r = call(
        "system_sdwan_create_port_mapping",
        network_id: network.id, hub_peer_id: hub_peer.id, target_peer_id: target.id,
        name: "hardened-mapping", listen_port: 6000, protocol: "tcp",
        rate_limit: 100, max_connections: 25, source_cidrs: [ "203.0.113.0/24" ]
      )
      expect(r[:success]).to be true
      pm = r[:data][:port_mapping]
      expect(pm[:rate_limit]).to eq(100)
      expect(pm[:max_connections]).to eq(25)
      expect(pm[:source_cidrs]).to eq([ "203.0.113.0/24" ])

      persisted = ::Sdwan::PortMapping.find(pm[:id])
      expect(persisted.rate_limit).to eq(100)
      expect(persisted.max_connections).to eq(25)
      expect(persisted.source_cidrs).to eq([ "203.0.113.0/24" ])
    end

    it "defaults all three to unrestricted (nil/[]) when omitted" do
      r = call(
        "system_sdwan_create_port_mapping",
        network_id: network.id, hub_peer_id: hub_peer.id, target_peer_id: target.id,
        name: "plain-mapping", listen_port: 6001, protocol: "tcp"
      )
      expect(r[:success]).to be true
      pm = r[:data][:port_mapping]
      expect(pm[:rate_limit]).to be_nil
      expect(pm[:max_connections]).to be_nil
      expect(pm[:source_cidrs]).to eq([])
    end

    it "rejects an invalid CIDR through the tool path with the model's per-entry error" do
      r = call(
        "system_sdwan_create_port_mapping",
        network_id: network.id, hub_peer_id: hub_peer.id, target_peer_id: target.id,
        name: "bad-cidr-mapping", listen_port: 6002, protocol: "tcp",
        source_cidrs: [ "not-a-cidr" ]
      )
      expect(r[:success]).to be false
      expect(r[:error]).to match(/invalid CIDR entry/)
      expect(::Sdwan::PortMapping.exists?(name: "bad-cidr-mapping")).to be false
    end

    it "rejects a non-positive rate_limit through the tool path" do
      r = call(
        "system_sdwan_create_port_mapping",
        network_id: network.id, hub_peer_id: hub_peer.id, target_peer_id: target.id,
        name: "bad-rate-mapping", listen_port: 6003, protocol: "tcp",
        rate_limit: 0
      )
      expect(r[:success]).to be false
      expect(r[:error]).to match(/greater than 0/)
    end

    it "keeps the manage permission gate unchanged" do
      expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_create_port_mapping"))
        .to eq("system.sdwan.port_mappings.manage")
    end
  end

  describe "system_sdwan_update_port_mapping (hardening params)" do
    let(:network)  { create(:sdwan_network, account: account) }
    let!(:mapping) { create(:sdwan_port_mapping, account: account, network: network) }

    # Value semantics ride the gate's :proceed branch since IMP-c9798d9d5671
    # (sdwan.port_mapping_update — the approval-path behaviour has its own
    # describe below).
    it "updates rate_limit, max_connections, and source_cidrs via options" do
      auto_approve_policy!
      r = call(
        "system_sdwan_update_port_mapping",
        port_mapping_id: mapping.id,
        options: { rate_limit: 200, max_connections: 40, source_cidrs: [ "2001:db8::/32" ] }
      )
      expect(r[:success]).to be true
      pm = r[:data][:port_mapping]
      expect(pm[:rate_limit]).to eq(200)
      expect(pm[:max_connections]).to eq(40)
      expect(pm[:source_cidrs]).to eq([ "2001:db8::/32" ])
    end

    it "clears hardening back to unrestricted with nil/[]" do
      auto_approve_policy!
      mapping.update!(rate_limit: 50, max_connections: 10, source_cidrs: [ "203.0.113.0/24" ])

      r = call(
        "system_sdwan_update_port_mapping",
        port_mapping_id: mapping.id,
        options: { rate_limit: nil, max_connections: nil, source_cidrs: [] }
      )
      expect(r[:success]).to be true
      pm = r[:data][:port_mapping]
      expect(pm[:rate_limit]).to be_nil
      expect(pm[:max_connections]).to be_nil
      expect(pm[:source_cidrs]).to eq([])
    end

    it "rejects an invalid CIDR before the gate without persisting or parking anything" do
      expect {
        @result = call(
          "system_sdwan_update_port_mapping",
          port_mapping_id: mapping.id,
          options: { source_cidrs: [ "999.999.999.999/24" ] }
        )
      }.not_to change(Ai::DeferredOperation, :count)
      expect(@result[:success]).to be false
      expect(@result[:error]).to match(/invalid CIDR entry/)
      expect(mapping.reload.source_cidrs).to eq([])
    end

    it "keeps the manage permission gate unchanged" do
      expect(described_class::ACTION_PERMISSIONS.fetch("system_sdwan_update_port_mapping"))
        .to eq("system.sdwan.port_mappings.manage")
    end
  end

  # ─── Registry wiring ─────────────────────────────────────────────────

  # IMP-3686f6c236d9 — MCP/HTTP parity for the device-revoke trust boundary.
  #
  # Revoking a Sdwan::UserDevice cuts one user's VPN access.
  # UserDevicesController#revoke gates it on `system.sdwan_user_device_revoke`
  # (seeded require_approval in db/seeds/fleet_autonomy_agent.rb, and the
  # InterventionPolicyService default), so the operator waits for approval —
  # while this tool called `device.revoke!` inline, giving an agent holding the
  # MCP tool a strictly wider capability than the same operator over HTTP, with
  # no Ai::DeferredOperation audit row.
  #
  # The params handed to the gate are the cross-seam contract: the tool speaks
  # `user_device_id`, the executor reads `grant_id`/`device_id`. Nothing is
  # stubbed between them here — the deferred op is executed for real, so a
  # key mismatch fails rather than passing on a well-formed-looking hash.
  describe "system_sdwan_revoke_user_device approval gate (IMP-3686f6c236d9)" do
    let(:network) { create(:sdwan_network, account: account) }
    let(:grant)   { create(:sdwan_access_grant, account: account, network: network) }
    let!(:target)  { create(:sdwan_user_device, access_grant: grant, label: "lost-phone") }
    let!(:sibling) { create(:sdwan_user_device, access_grant: grant, label: "work-laptop") }

    # Tail of the approval path — Ai::ApprovalRequest ultimately calls
    # execute_now!. The presence assertion keeps a missing gate failing by
    # name instead of as `undefined method for nil`.
    def approve_latest_deferred!
      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "no deferred operation was parked — the revoke was applied inline"
      deferred.tap(&:execute_now!)
    end

    # Forces the gate's :proceed branch. The default policy is require_approval,
    # so nothing else here covers the inline path.
    def auto_approve_policy!
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    it "defers the revoke through the approval gate rather than mutating inline" do
      r = call("system_sdwan_revoke_user_device", user_device_id: target.id, reason: "lost")

      expect(r[:success]).to be true
      expect(r[:data][:pending]).to be true
      expect(target.reload.revoked?).to be(false),
                                        "MCP revoke_user_device cut the device without an approval gate"
    end

    it "parks a device-scoped deferred operation the executor can consume" do
      call("system_sdwan_revoke_user_device", user_device_id: target.id, reason: "lost")

      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "no deferred operation was parked — the revoke was applied inline"
      expect(deferred.action_category).to eq("system.sdwan_user_device_revoke")
      expect(deferred.executor_class).to eq("Sdwan::Executors::RevokeUserDevice")
      expect(deferred.params["device_id"]).to eq(target.id)
      expect(deferred.params["grant_id"]).to eq(grant.id)
    end

    # The seeded require_approval row is scoped to an agent, and
    # Ai::InterventionPolicy#agent_matches? rejects a scoped row when no agent
    # is passed — an agent caller that drops its agent routes the approval to
    # "Manual Operations", unattributed.
    it "attributes the deferred revoke to the calling agent" do
      agent = create(:ai_agent, account: account)
      agent_tool = described_class.new(account: account, agent: agent, internal: true)

      agent_tool.execute(params: {
        action: "system_sdwan_revoke_user_device", user_device_id: target.id
      })

      expect(Ai::DeferredOperation.order(created_at: :desc).first.ai_agent_id).to eq(agent.id)
    end

    it "revokes ONLY the named device when the deferred op is approved" do
      call("system_sdwan_revoke_user_device", user_device_id: target.id, reason: "lost")
      approve_latest_deferred!

      expect(target.reload.revoked?).to be(true), "approving the deferred MCP revoke did not revoke the device"
      expect(target.revocation_reason).to eq("lost"), "the reason did not survive the deferral"
      expect(sibling.reload.revoked?).to be(false), "sibling device was revoked — device revoke leaked to the whole grant"
      expect(grant.reload.status).to eq("active"), "access grant was revoked by a DEVICE-level revoke"
    end

    it "revokes inline and reports it when the policy auto-approves" do
      auto_approve_policy!

      r = call("system_sdwan_revoke_user_device", user_device_id: target.id, reason: "lost")

      expect(r[:success]).to be true
      expect(r[:data][:revoked]).to be true
      expect(r[:data][:device][:revoked_at]).to be_present,
                                                "answered revoked: true over a device serialized as still active"
      expect(target.reload.revoked?).to be(true)
      expect(sibling.reload.revoked?).to be(false)
    end

    # Account scoping is enforced BEFORE the gate, as it is on the HTTP path
    # (set_network/set_grant/set_device) — the executor re-resolves from stored
    # ids and is not an authorization boundary.
    it "refuses a device outside the caller's account without parking anything" do
      foreign = create(:sdwan_user_device)

      expect {
        @result = call("system_sdwan_revoke_user_device", user_device_id: foreign.id)
      }.not_to change(Ai::DeferredOperation, :count)
      expect(@result[:success]).to be false
      expect(foreign.reload.revoked?).to be(false)
    end
  end

  # IMP-d172ed7435a2 — MCP/HTTP parity for the GRANT-revoke trust boundary,
  # one blast radius above the device verb gated in IMP-3686f6c236d9.
  #
  # AccessGrant#revoke! cascades: it soft-revokes every non-revoked device on
  # the grant (access_grant.rb:49-51). AccessGrantsController#revoke gates that
  # on `sdwan.access_grant_revoke` (seeded require_approval on the SDWAN Manager
  # in db/seeds/system_sdwan_manager_agent.rb:138, and the
  # InterventionPolicyService default), while this tool called `grant.revoke!`
  # inline. Since both device- and grant-revoke map to the SAME permission
  # (system.sdwan.user_devices.manage), an agent refused the narrow device
  # revoke could reach for this one and cut every sibling device instead.
  #
  # Nothing is stubbed between the tool and the executor: the deferred op is
  # executed for real, so a params-key mismatch fails as RecordNotFound rather
  # than passing on a well-formed-looking hash.
  describe "system_sdwan_revoke_access_grant approval gate (IMP-d172ed7435a2)" do
    let(:network)  { create(:sdwan_network, account: account) }
    let(:grant)    { create(:sdwan_access_grant, account: account, network: network) }
    let!(:phone)   { create(:sdwan_user_device, access_grant: grant, label: "phone") }
    let!(:laptop)  { create(:sdwan_user_device, access_grant: grant, label: "work-laptop") }

    # Tail of the approval path — Ai::ApprovalRequest ultimately calls
    # execute_now!. The presence assertion keeps a missing gate failing by name
    # instead of as `undefined method for nil`.
    def approve_latest_deferred!
      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "no deferred operation was parked — the revoke was applied inline"
      deferred.tap(&:execute_now!)
    end

    # Forces the gate's :proceed branch. The default policy is require_approval,
    # so nothing else here covers the inline path.
    def auto_approve_policy!
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    it "defers the grant revoke through the approval gate rather than cascading inline" do
      r = call("system_sdwan_revoke_access_grant", access_grant_id: grant.id, reason: "offboarded")

      expect(r[:success]).to be true
      expect(r[:data][:pending]).to be true
      expect(grant.reload.revoked?).to be(false),
                                       "MCP revoke_access_grant revoked the grant without an approval gate"
      expect(phone.reload.revoked?).to be(false),
                                       "the ungated grant revoke cascaded to every device on the grant"
      expect(laptop.reload.revoked?).to be(false)
    end

    # The executor refuses device-scoped params (reject_device_scoped_params!),
    # so the parked hash must carry grant_id and NO device_id — otherwise every
    # approval of an MCP-filed revoke raises ArgumentError at execute time.
    it "parks a grant-scoped deferred operation the executor can consume" do
      call("system_sdwan_revoke_access_grant", access_grant_id: grant.id, reason: "offboarded")

      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "no deferred operation was parked — the revoke was applied inline"
      expect(deferred.action_category).to eq("sdwan.access_grant_revoke")
      expect(deferred.executor_class).to eq("Sdwan::Executors::RevokeAccessGrant")
      expect(deferred.params["grant_id"]).to eq(grant.id)
      expect(deferred.params).not_to have_key("device_id")
    end

    # The seeded require_approval row is scoped to the SDWAN Manager agent, and
    # Ai::InterventionPolicy#agent_matches? rejects a scoped row when no agent is
    # passed — an agent caller that drops its agent routes the approval to
    # "Manual Operations", unattributed.
    it "attributes the deferred revoke to the calling agent" do
      agent = create(:ai_agent, account: account)
      agent_tool = described_class.new(account: account, agent: agent, internal: true)

      agent_tool.execute(params: {
        action: "system_sdwan_revoke_access_grant", access_grant_id: grant.id
      })

      expect(Ai::DeferredOperation.order(created_at: :desc).first.ai_agent_id).to eq(agent.id)
    end

    it "revokes the grant and every device on it when the deferred op is approved" do
      call("system_sdwan_revoke_access_grant", access_grant_id: grant.id, reason: "offboarded")
      approve_latest_deferred!

      expect(grant.reload.revoked?).to be(true), "approving the deferred MCP revoke did not revoke the grant"
      expect(grant.revocation_reason).to eq("offboarded"), "the reason did not survive the deferral"
      expect(phone.reload.revoked?).to be(true), "the grant revoke did not cascade to the user's devices"
      expect(laptop.reload.revoked?).to be(true)
      expect(phone.revocation_reason).to eq("grant_revoked")
    end

    it "revokes inline and reports it when the policy auto-approves" do
      auto_approve_policy!

      r = call("system_sdwan_revoke_access_grant", access_grant_id: grant.id, reason: "offboarded")

      expect(r[:success]).to be true
      expect(r[:data][:revoked]).to be true
      expect(r[:data][:grant][:status]).to eq("revoked"),
                                           "answered revoked: true over a grant serialized as still active"
      expect(grant.reload.revoked?).to be(true)
      expect(phone.reload.revoked?).to be(true)
    end

    # Account scoping is enforced BEFORE the gate, as it is on the HTTP path
    # (set_network/set_grant) — the executor re-resolves from the stored id and
    # is not an authorization boundary.
    it "refuses a grant outside the caller's account without parking anything" do
      foreign = create(:sdwan_access_grant)

      expect {
        @result = call("system_sdwan_revoke_access_grant", access_grant_id: foreign.id)
      }.not_to change(Ai::DeferredOperation, :count)
      expect(@result[:success]).to be false
      expect(foreign.reload.revoked?).to be(false)
    end
  end

  # IMP-6c482005db87 — MCP/HTTP parity for the two ADDITIVE data-plane writes
  # whose executors existed but had no caller: create_firewall_rule and
  # create_virtual_ip both persisted inline, so the seeded
  # sdwan.{firewall_rule,virtual_ip}_create policies matched nothing this tool
  # did while the REST twins now gate the same categories.
  #
  # Nothing is stubbed between the tool and the executor: the deferred op is
  # executed for real, so a params-key mismatch fails as RecordNotFound /
  # RecordInvalid rather than passing on a well-formed-looking hash.
  describe "system_sdwan_create_firewall_rule approval gate (IMP-6c482005db87)" do
    let(:network) { create(:sdwan_network, account: account) }

    let(:create_params) do
      { network_id: network.id, name: "allow-db", firewall_action: "accept",
        direction: "ingress", protocol: "tcp", priority: 42,
        port_from: 5432, port_to: 5433 }
    end

    it "defers the create through the approval gate rather than writing inline" do
      r = call("system_sdwan_create_firewall_rule", **create_params)

      expect(r[:success]).to be true
      expect(r[:data][:pending]).to be true
      expect(::Sdwan::FirewallRule.count).to eq(0),
                                             "MCP create_firewall_rule wrote the nftables rule without an approval gate"
    end

    # port_from/port_to must be re-keyed to port_range_hash for the executor's
    # create! — the raw column is an int4range a Hash cannot mass-assign —
    # and the card scopes its network label by attributes[:account_id]
    # (stripped again by Base#attrs before perform).
    it "parks a deferred operation the executor can consume" do
      call("system_sdwan_create_firewall_rule", **create_params)

      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "no deferred operation was parked — the create was applied inline"
      expect(deferred.action_category).to eq("sdwan.firewall_rule_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreateFirewallRule")
      expect(deferred.params["network_id"]).to eq(network.id)
      expect(deferred.params.dig("attributes", "action")).to eq("accept")
      expect(deferred.params.dig("attributes", "port_range_hash", "from")).to eq(5432)
      # IMP-4a5094b22df0 — INVERTED. This used to assert account_id was PRESENT,
      # because the approval card scoped its network label by whatever account
      # the attributes carried. The card now anchors on the operation's own
      # account, so a caller-shaped tenancy key in gate-replayed params buys
      # nothing and is exactly the shape Base::TENANCY_ATTRIBUTE_KEYS exists to
      # keep out. Sdwan::FirewallRule derives account_id from its network in a
      # before_validation, so nothing downstream wanted it either.
      expect(deferred.params.dig("attributes", "account_id")).to be_nil
    end

    it "creates the rule when the deferred op is approved" do
      call("system_sdwan_create_firewall_rule", **create_params)

      expect { approve_latest_deferred! }.to change(::Sdwan::FirewallRule, :count).by(1)

      rule = ::Sdwan::FirewallRule.order(created_at: :desc).first
      expect(rule.name).to eq("allow-db")
      expect(rule.action).to eq("accept")
      expect(rule.port_range_hash).to eq({ from: 5432, to: 5433 })
      expect(rule.account_id).to eq(account.id)
    end

    it "creates inline and serializes the rule when the policy auto-approves" do
      auto_approve_policy!

      r = call("system_sdwan_create_firewall_rule", **create_params)

      expect(r[:success]).to be true
      expect(r[:data][:firewall_rule][:name]).to eq("allow-db"),
                                                 "answered success over a rule that was not serialized back"
      expect(::Sdwan::FirewallRule.count).to eq(1)
    end

    # Validated BEFORE the gate, like accept_federation_peer's up-front
    # checks: a doomed create must fail with its field errors immediately
    # rather than park an approval that can only ever fail.
    it "rejects an invalid rule before the gate without parking anything" do
      expect {
        @result = call("system_sdwan_create_firewall_rule",
                       network_id: network.id, name: "bad", firewall_action: "explode")
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(@result[:error]).to include("Action"), "the field-level error must survive pre-gate validation"
    end

    it "refuses a network outside the caller's account without parking anything" do
      foreign = create(:sdwan_network)

      expect {
        @result = call("system_sdwan_create_firewall_rule", **create_params.merge(network_id: foreign.id))
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(foreign.firewall_rules.count).to eq(0)
    end
  end

  describe "system_sdwan_create_virtual_ip approval gate (IMP-6c482005db87)" do
    let(:network) { create(:sdwan_network, account: account) }
    let!(:holder) { create(:sdwan_peer, account: account, network: network) }

    let(:create_params) do
      { network_id: network.id, name: "svc-vip", cidr: "fd00:beef::9/128",
        holder_peer_ids: [ holder.id ] }
    end

    it "defers the create through the approval gate rather than writing inline" do
      r = call("system_sdwan_create_virtual_ip", **create_params)

      expect(r[:success]).to be true
      expect(r[:data][:pending]).to be true
      expect(::Sdwan::VirtualIp.count).to eq(0),
                                          "MCP create_virtual_ip allocated the VIP without an approval gate"
    end

    it "parks a deferred operation the executor can consume" do
      call("system_sdwan_create_virtual_ip", **create_params)

      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "no deferred operation was parked — the create was applied inline"
      expect(deferred.action_category).to eq("sdwan.virtual_ip_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreateVirtualIp")
      expect(deferred.params["network_id"]).to eq(network.id)
      expect(deferred.params.dig("attributes", "holder_peer_ids")).to eq([ holder.id ])
      # IMP-4a5094b22df0 — INVERTED, same rationale as the firewall-rule twin
      # above: the card anchors on the operation's account, so the caller-shaped
      # tenancy key is gone from the params the gate replays.
      expect(deferred.params.dig("attributes", "account_id")).to be_nil
    end

    # The executor owns the whole create ceremony (activation + slice-9b
    # initial assignment row) so the approved VIP is indistinguishable from
    # one created inline.
    it "creates an ACTIVE vip with its initial assignment row when approved" do
      call("system_sdwan_create_virtual_ip", **create_params)

      expect { approve_latest_deferred! }.to change(::Sdwan::VirtualIp, :count).by(1)

      vip = ::Sdwan::VirtualIp.order(created_at: :desc).first
      expect(vip.state).to eq("active")
      expect(vip.assignments.count).to eq(1),
                                       "approved create left phantom holder state with no assignment history row"
      expect(vip.assignments.first.sdwan_peer_id).to eq(holder.id)
      expect(vip.assignments.first.reason).to eq("initial")
    end

    it "creates inline and serializes the vip when the policy auto-approves" do
      auto_approve_policy!

      r = call("system_sdwan_create_virtual_ip", **create_params)

      expect(r[:success]).to be true
      expect(r[:data][:virtual_ip][:name]).to eq("svc-vip"),
                                              "answered success over a VIP that was not serialized back"
      expect(r[:data][:virtual_ip][:state]).to eq("active")
      expect(::Sdwan::VirtualIp.count).to eq(1)
      expect(::Sdwan::VirtualIp.first.assignments.count).to eq(1)
    end

    it "rejects an invalid vip before the gate without parking anything" do
      expect {
        @result = call("system_sdwan_create_virtual_ip", **create_params.merge(anycast: true))
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(@result[:error]).to include("holder"), "the field-level error must survive pre-gate validation"
      expect(::Sdwan::VirtualIp.count).to eq(0)
    end

    it "refuses a network outside the caller's account without parking anything" do
      foreign = create(:sdwan_network)

      expect {
        @result = call("system_sdwan_create_virtual_ip", **create_params.merge(network_id: foreign.id))
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(foreign.virtual_ips.count).to eq(0)
    end
  end

  # IMP-c9798d9d5671 — MCP/HTTP parity for the UPDATE verbs: every REST
  # update path in this family now parks behind Ai::AutonomyGate
  # (sdwan.{firewall_rule,virtual_ip,route_policy,port_mapping,peer,network}
  # _update) while these MCP arms applied the identical mutations inline —
  # an agent refused on the REST surface could reach for the MCP twin.
  # Mirrors the IMP-6c482005db87 create-gate blocks above: nothing is
  # stubbed between the tool and the executor, so a params-key mismatch
  # fails as RecordNotFound / RecordInvalid rather than passing on a
  # well-formed-looking hash.
  describe "system_sdwan_update_firewall_rule approval gate (IMP-c9798d9d5671)" do
    let(:network) { create(:sdwan_network, account: account) }
    let!(:rule)   { create(:sdwan_firewall_rule, account: account, network: network, name: "old-rule", priority: 100) }

    let(:gate_action)  { "system_sdwan_update_firewall_rule" }
    let(:gate_request) { { firewall_rule_id: rule.id, name: "renamed" } }
    let(:pristine_probe) { -> { rule.reload.name } }
    let(:pristine_value) { "old-rule" }
    let(:pristine_failure_hint) { "MCP update_firewall_rule rewrote the nftables rule without an approval gate" }

    let(:noop_request) { { firewall_rule_id: rule.id, bogus_field: "x" } }

    it_behaves_like "an approval-gated sdwan update"
    it_behaves_like "a loud no-op update refusal"

    it "parks a deferred operation the executor consumes on approval (port re-key included)" do
      r = call("system_sdwan_update_firewall_rule",
               firewall_rule_id: rule.id, priority: 7, port_from: 5432, port_to: 5433)

      approve_parked_update!(r, category: "sdwan.firewall_rule_update",
                             executor: "Sdwan::Executors::UpdateFirewallRule") do |deferred|
        expect(deferred.params["rule_id"]).to eq(rule.id)
        expect(deferred.params.dig("attributes", "port_range_hash", "from")).to eq(5432)
      end

      expect(rule.reload.priority).to eq(7)
      expect(rule.port_range_hash).to eq({ from: 5432, to: 5433 })
    end

    it "updates inline and serializes the rule when the policy auto-approves" do
      auto_approve_policy!

      r = call("system_sdwan_update_firewall_rule", firewall_rule_id: rule.id, name: "renamed")

      expect(r[:success]).to be true
      expect(r[:data][:firewall_rule][:name]).to eq("renamed"),
                                                 "answered success over a rule that was not serialized back"
      expect(rule.reload.name).to eq("renamed")
    end

    it "rejects an invalid update before the gate without parking anything" do
      expect {
        @result = call("system_sdwan_update_firewall_rule",
                       firewall_rule_id: rule.id, firewall_action: "explode")
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(rule.reload.action).to eq("accept")
    end

    it "refuses a rule outside the caller's account without parking anything" do
      foreign = create(:sdwan_firewall_rule, name: "foreign-rule")

      expect {
        @result = call("system_sdwan_update_firewall_rule", firewall_rule_id: foreign.id, name: "stolen")
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(foreign.reload.name).to eq("foreign-rule")
    end
  end

  describe "system_sdwan_update_virtual_ip approval gate (IMP-c9798d9d5671)" do
    let(:network) { create(:sdwan_network, account: account) }
    # Lazy: only the holder-change examples pay the peer-allocator cost.
    let(:holder)  { create(:sdwan_peer, account: account, network: network) }
    let!(:vip)    { create(:sdwan_virtual_ip, account: account, network: network, holder_peer_ids: []) }

    let(:gate_action)  { "system_sdwan_update_virtual_ip" }
    let(:gate_request) { { virtual_ip_id: vip.id, holder_peer_ids: [ holder.id ] } }
    let(:pristine_probe) { -> { vip.reload.holder_peer_ids } }
    let(:pristine_value) { [] }
    let(:pristine_failure_hint) { "MCP update_virtual_ip moved the VIP without an approval gate" }

    let(:noop_request) { { virtual_ip_id: vip.id, bogus_field: "x" } }

    it_behaves_like "an approval-gated sdwan update"
    it_behaves_like "a loud no-op update refusal"

    # The holder audit sync migrated INTO UpdateVirtualIp#perform
    # (IMP-0e44cf2fc80b) — approving the parked op must both apply the
    # holder change AND write the slice-9b assignment history row ("no
    # phantom current state without a history row").
    it "parks a deferred operation whose approval applies the holder change with its audit row" do
      r = call("system_sdwan_update_virtual_ip", virtual_ip_id: vip.id, holder_peer_ids: [ holder.id ])

      approve_parked_update!(r, category: "sdwan.virtual_ip_update",
                             executor: "Sdwan::Executors::UpdateVirtualIp") do |deferred|
        expect(deferred.params["vip_id"]).to eq(vip.id)
        expect(deferred.params.dig("attributes", "holder_peer_ids")).to eq([ holder.id ])
      end

      expect(vip.reload.holder_peer_ids).to eq([ holder.id ])
      expect(vip.assignments.where(sdwan_peer_id: holder.id, reason: "holder_changed").count).to eq(1),
                                                                                                "approved holder change left phantom current state with no assignment history row"
    end

    it "updates inline and serializes the vip when the policy auto-approves" do
      auto_approve_policy!

      r = call("system_sdwan_update_virtual_ip", virtual_ip_id: vip.id, description: "edge vip")

      expect(r[:success]).to be true
      expect(r[:data][:virtual_ip][:description]).to eq("edge vip"),
                                                     "answered success over a VIP that was not serialized back"
      expect(vip.reload.description).to eq("edge vip")
    end

    it "refuses a vip outside the caller's account without parking anything" do
      foreign = create(:sdwan_virtual_ip)

      expect {
        @result = call("system_sdwan_update_virtual_ip", virtual_ip_id: foreign.id, description: "stolen")
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(foreign.reload.description).to be_nil
    end
  end

  # IMP-7c911ca26585 — the failover arm was the one VIP mutation left
  # writing inline after the create/update parity waves: REST gates the
  # identical action as system.sdwan_vip_failover through
  # Sdwan::Executors::FailoverVirtualIp, so under require_approval an agent
  # refused on the REST surface could promote the failover holder (a BGP /
  # AllowedIPs reachability rewrite) through this arm with no approval and
  # no DeferredOperation.
  describe "system_sdwan_failover_virtual_ip approval gate (IMP-7c911ca26585)" do
    let(:network)  { create(:sdwan_network, account: account) }
    # Lazy like the sibling update-VIP describe: only the examples that
    # exercise the default vip pay the peer-allocator (node-instance chain)
    # cost — the refusal examples build their own rows.
    let(:primary) { create(:sdwan_peer, account: account, network: network) }
    let(:standby) { create(:sdwan_peer, account: account, network: network) }
    let(:vip) do
      create(:sdwan_virtual_ip, account: account, network: network, state: "active",
             holder_peer_ids: [ primary.id ], failover_holder_peer_ids: [ standby.id ])
    end

    let(:gate_action)  { "system_sdwan_failover_virtual_ip" }
    let(:gate_request) { { virtual_ip_id: vip.id } }
    let(:pristine_probe) { -> { vip.reload.holder_peer_ids } }
    let(:pristine_value) { [ primary.id ] }
    let(:pristine_failure_hint) { "MCP failover_virtual_ip promoted the failover holder without an approval gate" }

    it_behaves_like "an approval-gated sdwan update"

    it "parks a system.sdwan_vip_failover operation whose approval promotes the standby with its audit row" do
      r = call("system_sdwan_failover_virtual_ip", virtual_ip_id: vip.id)

      approve_parked_update!(r, category: "system.sdwan_vip_failover",
                             executor: "Sdwan::Executors::FailoverVirtualIp") do |deferred|
        expect(deferred.params["vip_id"]).to eq(vip.id)
      end

      expect(vip.reload.holder_peer_ids.first).to eq(standby.id)
      expect(vip.failover_holder_peer_ids).to eq([ primary.id ])
      expect(vip.assignments.where(sdwan_peer_id: standby.id, reason: "manual_failover").count).to eq(1),
                                                                                                   "approved failover left phantom holder state with no assignment history row"
    end

    it "fails over inline and serializes the vip when the policy auto-approves" do
      auto_approve_policy!

      r = call("system_sdwan_failover_virtual_ip", virtual_ip_id: vip.id)

      expect(r[:success]).to be true
      expect(r[:data][:failed_over]).to be true
      expect(r[:data][:virtual_ip][:holder_peer_ids].first).to eq(standby.id),
                                                               "answered success over a VIP that was not serialized back"
      expect(vip.reload.holder_peer_ids.first).to eq(standby.id)
    end

    # Positive twins for the two pre-gate refusals below are the gated
    # examples above (a failover the model would accept parks / executes).
    # Refusal wording is the model's own (Sdwan::VirtualIp#failover!
    # StateError guards) so the arm's error contract is unchanged.
    it "refuses an anycast failover pre-gate without parking a doomed approval" do
      anycast = create(:sdwan_virtual_ip, account: account, network: network, anycast: true,
                       holder_peer_ids: [ primary.id, standby.id ])

      expect {
        @result = call("system_sdwan_failover_virtual_ip", virtual_ip_id: anycast.id)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(@result[:error]).to include("anycast")
    end

    it "refuses a candidate-less failover pre-gate without parking a doomed approval" do
      bare = create(:sdwan_virtual_ip, account: account, network: network,
                    holder_peer_ids: [ primary.id ], failover_holder_peer_ids: [])

      expect {
        @result = call("system_sdwan_failover_virtual_ip", virtual_ip_id: bare.id)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(@result[:error]).to include("no failover candidates")
    end

    # The foreign VIP carries a real failover candidate so this control stays
    # sharp: if the account scope broke, the arm would park/promote rather
    # than fall through to a pre-gate refusal for the wrong reason.
    it "refuses a vip outside the caller's account without parking anything" do
      foreign_standby = create(:sdwan_peer)
      foreign = create(:sdwan_virtual_ip, network: foreign_standby.network,
                       holder_peer_ids: [], failover_holder_peer_ids: [ foreign_standby.id ])

      expect {
        @result = call("system_sdwan_failover_virtual_ip", virtual_ip_id: foreign.id)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(foreign.reload.holder_peer_ids).to eq([])
    end
  end

  describe "system_sdwan_update_route_policy approval gate (IMP-c9798d9d5671)" do
    let!(:policy) { create(:sdwan_route_policy, account: account, name: "old-policy") }

    let(:gate_action)  { "system_sdwan_update_route_policy" }
    let(:gate_request) { { route_policy_id: policy.id, options: { name: "renamed" } } }
    let(:pristine_probe) { -> { policy.reload.name } }
    let(:pristine_value) { "old-policy" }
    let(:pristine_failure_hint) { "MCP update_route_policy rewrote the policy without an approval gate" }

    let(:noop_request) { { route_policy_id: policy.id, options: { bogus_field: "x" } } }

    it_behaves_like "an approval-gated sdwan update"
    it_behaves_like "a loud no-op update refusal"

    it "parks a deferred operation the executor consumes on approval" do
      r = call("system_sdwan_update_route_policy", route_policy_id: policy.id, options: { name: "renamed", enabled: false })

      approve_parked_update!(r, category: "sdwan.route_policy_update",
                             executor: "Sdwan::Executors::UpdateRoutePolicy") do |deferred|
        expect(deferred.params["policy_id"]).to eq(policy.id)
      end

      expect(policy.reload.name).to eq("renamed")
      expect(policy.enabled).to be false
    end

    it "updates inline and serializes the policy when the policy auto-approves" do
      auto_approve_policy!

      r = call("system_sdwan_update_route_policy", route_policy_id: policy.id, options: { name: "renamed" })

      expect(r[:success]).to be true
      expect(r[:data][:route_policy][:name]).to eq("renamed"),
                                                "answered success over a policy that was not serialized back"
    end

    it "keeps the not-found contract for a bogus id" do
      r = call("system_sdwan_update_route_policy",
               route_policy_id: SecureRandom.uuid, options: { name: "x" })

      expect(r[:success]).to be false
      expect(r[:error]).to eq("route policy not found")
    end
  end

  describe "system_sdwan_update_port_mapping approval gate (IMP-c9798d9d5671)" do
    let(:network)  { create(:sdwan_network, account: account) }
    let!(:mapping) { create(:sdwan_port_mapping, account: account, network: network) }

    let(:gate_action)  { "system_sdwan_update_port_mapping" }
    let(:gate_request) { { port_mapping_id: mapping.id, options: { rate_limit: 200 } } }
    let(:pristine_probe) { -> { mapping.reload.rate_limit } }
    let(:pristine_value) { nil }
    let(:pristine_failure_hint) { "MCP update_port_mapping rewrote the DNAT mapping without an approval gate" }

    let(:noop_request) { { port_mapping_id: mapping.id, options: { bogus_field: "x" } } }

    it_behaves_like "an approval-gated sdwan update"
    it_behaves_like "a loud no-op update refusal"

    it "parks a deferred operation the executor consumes on approval" do
      r = call("system_sdwan_update_port_mapping",
               port_mapping_id: mapping.id, options: { rate_limit: 200, max_connections: 40 })

      approve_parked_update!(r, category: "sdwan.port_mapping_update",
                             executor: "Sdwan::Executors::UpdatePortMapping") do |deferred|
        expect(deferred.params["mapping_id"]).to eq(mapping.id)
      end

      expect(mapping.reload.rate_limit).to eq(200)
      expect(mapping.max_connections).to eq(40)
    end

    it "refuses a mapping outside the caller's account without parking anything" do
      foreign = create(:sdwan_port_mapping)

      expect {
        @result = call("system_sdwan_update_port_mapping",
                       port_mapping_id: foreign.id, options: { rate_limit: 1 })
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(foreign.reload.rate_limit).to be_nil
    end
  end

  describe "system_sdwan_update_peer_lan_subnets approval gate (IMP-c9798d9d5671)" do
    let(:network)  { create(:sdwan_network, account: account) }
    let!(:peer)    { create(:sdwan_peer, account: account, network: network) }

    let(:gate_action)  { "system_sdwan_update_peer_lan_subnets" }
    let(:gate_request) { { peer_id: peer.id, lan_subnets: [ "10.9.0.0/24" ] } }
    let(:pristine_probe) { -> { peer.reload.lan_subnets } }
    let(:pristine_value) { [] }
    let(:pristine_failure_hint) { "MCP update_peer_lan_subnets rewrote AllowedIPs routing without an approval gate" }

    it_behaves_like "an approval-gated sdwan update"

    it "parks a sdwan.peer_update operation the executor consumes on approval" do
      r = call("system_sdwan_update_peer_lan_subnets", peer_id: peer.id, lan_subnets: [ "10.9.0.0/24" ])

      approve_parked_update!(r, category: "sdwan.peer_update",
                             executor: "Sdwan::Executors::UpdatePeer") do |deferred|
        expect(deferred.params["peer_id"]).to eq(peer.id)
        expect(deferred.params.dig("attributes", "lan_subnets")).to eq([ "10.9.0.0/24" ])
      end

      expect(peer.reload.lan_subnets).to eq([ "10.9.0.0/24" ])
    end

    it "updates inline and answers the routing payload when the policy auto-approves" do
      auto_approve_policy!

      r = call("system_sdwan_update_peer_lan_subnets", peer_id: peer.id, lan_subnets: [ "10.9.0.0/24" ])

      expect(r[:success]).to be true
      expect(r[:data][:lan_subnets]).to eq([ "10.9.0.0/24" ])
      expect(r[:data]).to have_key(:advertisement_count)
      expect(peer.reload.lan_subnets).to eq([ "10.9.0.0/24" ])
    end
  end

  describe "system_sdwan_update_network_routing_mode approval gate (IMP-c9798d9d5671)" do
    let!(:network) { create(:sdwan_network, account: account) }

    let(:gate_action)  { "system_sdwan_update_network_routing_mode" }
    let(:gate_request) { { network_id: network.id, routing_protocol: "ibgp" } }
    let(:pristine_probe) { -> { network.reload.routing_protocol } }
    let(:pristine_value) { "static" }
    let(:pristine_failure_hint) { "MCP update_network_routing_mode flipped the control plane without an approval gate" }

    it_behaves_like "an approval-gated sdwan update"

    # The old inline arm ALWAYS returned the iBGP capability warning; behind
    # the gate it must survive both audiences — the caller's pending
    # response (pending_extra) and the approver-facing description — or the
    # mode being approved silently loses its "not fully functional yet"
    # caveat.
    it "carries the iBGP capability note to the pending caller AND the approver" do
      r = call("system_sdwan_update_network_routing_mode", network_id: network.id, routing_protocol: "ibgp")

      expect(r[:data][:pending]).to be true
      expect(r[:data][:note]).to include("FRR"), "the pending caller lost the iBGP capability warning"
      approval = Ai::ApprovalRequest.find_by(id: r.dig(:data, :approval_request_id))
      expect(approval).to be_present
      expect(approval.description).to include("FRR"), "the approver never sees the iBGP capability warning"
    end

    it "parks a sdwan.network_update operation the executor consumes on approval" do
      r = call("system_sdwan_update_network_routing_mode", network_id: network.id, routing_protocol: "ibgp")

      approve_parked_update!(r, category: "sdwan.network_update",
                             executor: "Sdwan::Executors::UpdateNetwork") do |deferred|
        expect(deferred.params["network_id"]).to eq(network.id)
        expect(deferred.params.dig("attributes", "routing_protocol")).to eq("ibgp")
      end

      expect(network.reload.routing_protocol).to eq("ibgp")
    end

    it "updates inline and answers the routing payload when the policy auto-approves" do
      auto_approve_policy!

      r = call("system_sdwan_update_network_routing_mode", network_id: network.id, routing_protocol: "ibgp")

      expect(r[:success]).to be true
      expect(r[:data][:routing_protocol]).to eq("ibgp")
      expect(r[:data][:note]).to include("FRR")
    end

    it "rejects an unknown protocol before the gate without parking anything" do
      expect {
        @result = call("system_sdwan_update_network_routing_mode", network_id: network.id, routing_protocol: "ospf")
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(network.reload.routing_protocol).to eq("static")
    end
  end

  # The general network update arm — the LAST ungated status write on the MCP
  # surface (IMP-2ff1980f7813). Its REST twin (NetworksController#update)
  # gates the WHOLE update through sdwan.network_update, so an inline write
  # here is a parity bypass: status flips a network between compilable and
  # deny-all for every peer.
  #
  # Options are string-keyed on purpose: McpPlatformToolRegistrar hands the
  # tool a HashWithIndifferentAccess, which is the only live caller shape.
  describe "system_sdwan_update_network approval gate (IMP-2ff1980f7813)" do
    let!(:network) { create(:sdwan_network, account: account) }

    let(:gate_action)  { "system_sdwan_update_network" }
    let(:gate_request) { { network_id: network.id, options: { "status" => "suspended" } } }
    let(:pristine_probe) { -> { network.reload.status } }
    let(:pristine_value) { "registered" }
    let(:pristine_failure_hint) { "MCP update_network flipped network status without an approval gate" }

    let(:noop_request) { { network_id: network.id, options: { "bogus_field" => "x" } } }

    it_behaves_like "an approval-gated sdwan update"
    it_behaves_like "a loud no-op update refusal"

    it "parks a sdwan.network_update operation the executor consumes on approval" do
      r = call("system_sdwan_update_network", network_id: network.id,
               options: { "status" => "suspended", "description" => "paused for maintenance" })

      approve_parked_update!(r, category: "sdwan.network_update",
                             executor: "Sdwan::Executors::UpdateNetwork") do |deferred|
        expect(deferred.params["network_id"]).to eq(network.id)
        expect(deferred.params.dig("attributes", "status")).to eq("suspended")
        expect(deferred.params.dig("attributes", "description")).to eq("paused for maintenance")
      end

      expect(network.reload.status).to eq("suspended")
      expect(network.description).to eq("paused for maintenance")
    end

    # The gate must not become status-conditional: a name/description-only
    # payload carries no status at all and still has to defer.
    it "defers a name-only payload too — the gate is not status-conditional" do
      r = call("system_sdwan_update_network", network_id: network.id,
               options: { "name" => "renamed-net" })

      expect(r[:data][:pending]).to be true
      expect(network.reload.name).not_to eq("renamed-net")
    end

    # The proceed branch must run the EXECUTOR, not an inline write — without
    # the message expectation this example passes against the old inline
    # `network.update!` and proves nothing.
    it "runs the executor and serializes the network when the policy auto-approves" do
      auto_approve_policy!
      network.update!(settings: { "mtu" => 1420, "stale_key" => "gone" })
      expect(::Sdwan::Executors::UpdateNetwork).to receive(:execute).and_call_original

      r = call("system_sdwan_update_network", network_id: network.id,
               options: { "status" => "suspended", "settings" => { "mtu" => 1380 } })

      expect(r[:success]).to be true
      expect(r[:data][:network][:status]).to eq("suspended"),
                                             "answered success over a network that was not serialized back"
      expect(network.reload.status).to eq("suspended")
      # settings is REPLACED wholesale, matching the REST twin (network_params
      # permits `settings: {}` and UpdateNetwork assigns it) — not merged.
      expect(network.settings).to eq({ "mtu" => 1380 })
    end

    # An absent `options` is the shape whose behavior CHANGED: it used to
    # answer 200 with the serialized network (a write-shaped call that read
    # as applied), and now refuses loud. get_network covers the read case.
    it "refuses a call with no options at all rather than answering success" do
      expect {
        @result = call("system_sdwan_update_network", network_id: network.id)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(@result[:error]).to include("no recognized fields to update")
    end

    # SCOPE NOTE on this example's oracle: it cannot discriminate against the
    # pre-gate code, and no assertion can — the old inline `update!` raised
    # RecordInvalid, which the dispatch rescue (sdwan_tool.rb) rendered with
    # `errors.full_messages.join("; ")`, the byte-identical wording
    # validation_error_before_gate produces, and neither path wrote the row.
    # That wording parity is deliberate. What this example DOES pin is the
    # pre-gate refusal itself: neutering validation_error_before_gate makes a
    # doomed update reach Ai::AutonomyGate and park an approval an operator
    # would have to dispose of — mutation-verified red. The gating regression
    # is caught by "an approval-gated sdwan update" above, not here.
    it "rejects an out-of-range status before the gate is ever consulted" do
      expect(::Ai::AutonomyGate).not_to receive(:evaluate)

      expect {
        @result = call("system_sdwan_update_network", network_id: network.id,
                       options: { "name" => "renamed-net", "status" => "decommissioned" })
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(@result[:error]).to include("Status")
      expect(Ai::ApprovalRequest.count).to eq(0)
      expect(network.reload.status).to eq("registered")
      expect(network.name).not_to eq("renamed-net")
    end
  end

  describe "system_sdwan_set_peer_tags approval gate (IMP-c9798d9d5671)" do
    let(:network)  { create(:sdwan_network, account: account) }
    let!(:peer)    { create(:sdwan_peer, account: account, network: network) }

    # tags ride the SAME REST permit list (peer_update_params) as
    # lan_subnets, so leaving this arm inline would keep the
    # sdwan.peer_update category bypassable through MCP.
    let(:gate_action)  { "system_sdwan_set_peer_tags" }
    let(:gate_request) { { peer_id: peer.id, tags: %w[database] } }
    let(:pristine_probe) { -> { peer.reload.tags } }
    let(:pristine_value) { [] }
    let(:pristine_failure_hint) { "MCP set_peer_tags relabeled firewall selectors without an approval gate" }

    it_behaves_like "an approval-gated sdwan update"

    # The approval card renders the parked attributes, so the gate parks
    # the NORMALIZED tag set — what the approver sees must be what the
    # executor persists, not the raw [" database ", "", ...] input.
    it "parks the NORMALIZED tag set the executor persists on approval" do
      r = call("system_sdwan_set_peer_tags", peer_id: peer.id, tags: [ " database ", "edge", "database", "" ])

      approve_parked_update!(r, category: "sdwan.peer_update",
                             executor: "Sdwan::Executors::UpdatePeer") do |deferred|
        expect(deferred.params.dig("attributes", "tags")).to eq(%w[database edge]),
                                                             "the approval card would show a tag set the executor does not persist"
      end

      expect(peer.reload.tags).to eq(%w[database edge])
    end
  end

  describe "PlatformApiToolRegistry registration" do
    it "wires every Phase O6 action to SdwanTool" do
      registry = ::Ai::Tools::PlatformApiToolRegistry::TOOLS
      %w[
        system_sdwan_create_host_bridge
        system_sdwan_list_host_bridges
        system_sdwan_create_ovn_deployment
        system_sdwan_create_ovn_logical_switch
        system_sdwan_create_ovn_logical_switch_port
        system_sdwan_compile_ovn_plan
        system_sdwan_create_ipfix_collector
        system_sdwan_list_ipfix_collectors
      ].each do |action|
        expect(registry[action]).to eq("Ai::Tools::SdwanTool"), "expected #{action} → SdwanTool"
      end
    end
  end

  # IMP-54bf2643f542 — action_permitted? used to read `@user.nil?` as
  # "internal/system caller" and return true. That premise (MCP callers always
  # carry a user) predates instance principals: an mTLS node cert authenticates
  # with NO user, so all 82 per-action permissions were skipped and the peer's
  # per-tool grant glob was the only remaining control. Sibling of the
  # SystemFleetTool fix (IMP-9030413bc292): the bypass is now two EXPLICIT
  # signals and a bare userless call fails closed.
  describe "principal authorization (IMP-54bf2643f542)" do
    let(:gated_action) { "system_sdwan_create_network" }

    it "denies a bare userless call — no user, no internal flag, no instance grant" do
      bare = described_class.new(account: account, user: nil)

      expect(bare.send(:action_permitted?, gated_action)).to be false
    end

    it "surfaces the denial as an error_result rather than executing the action" do
      bare = described_class.new(account: account, user: nil)

      expect { @result = bare.execute(params: { action: gated_action, name: "bare-net", cidr: "10.90.0.0/16" }) }
        .not_to change(::Sdwan::Network, :count)
      expect(@result[:success]).to be false
      expect(@result[:error]).to include("permission denied")
    end

    it "preserves the internal/system bypass when declared explicitly" do
      internal = described_class.new(account: account, user: nil, internal: true)

      expect(internal.send(:action_permitted?, gated_action)).to be true
    end

    # Behaviour preservation for the live instance principal: the streamable
    # controller grant-gates the specific tool name via Mcp::Principal#may_invoke?
    # before dispatch, and the registrar marks the call. That marking — not the
    # nil user — is what carries it through here.
    it "still permits a grant-gated MCP instance principal" do
      instance_call = described_class.new(account: account, user: nil)
      instance_call.instance_authorized = true

      expect(instance_call.send(:action_permitted?, gated_action)).to be true
    end

    it "keeps enforcing per-action permissions for a user principal" do
      unprivileged = create(:user, account: account, permissions: %w[system.sdwan.networks.read])
      user_tool = described_class.new(account: account, user: unprivileged)

      expect(user_tool.send(:action_permitted?, "system_sdwan_list_networks")).to be true
      expect(user_tool.send(:action_permitted?, gated_action)).to be false
    end
  end
end
