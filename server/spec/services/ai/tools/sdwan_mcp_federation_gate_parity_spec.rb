# frozen_string_literal: true

require "rails_helper"

# IMP-2795453255c3 — the last two SDWAN trust-boundary verbs on the MCP
# surface were outside the gate regime while their REST twins were inside it.
#
# The destroy family closed in IMP-800b25c1cc45 and the write families in
# IMP-6c482005db87 / IMP-c9798d9d5671 / IMP-051f3811ac60, but the FEDERATION
# pair was left behind — and it is the pair that crosses an instance boundary:
#
#   REST (gated)                                       MCP (was inline)
#   FederationPeersController#create   sdwan.federation_peer_propose  system_sdwan_propose_federation_peer
#   FederationPeersController#destroy  sdwan.federation_peer_revoke   system_sdwan_revoke_federation_peer
#   FederationPeersController#revoke   sdwan.federation_peer_revoke
#   FederationPeersController#update (status → revoked)
#
# The revoke arm is the sharper of the two, because the bypass was reachable
# WITHOUT leaving this tool: Ai::Tools::SdwanTool#update_federation_peer with
# status: "revoked" routes through #update_gated_revoke on
# sdwan.federation_peer_revoke, so an agent refused there reached the identical
# state change one action name over, through
# system_sdwan_revoke_federation_peer's bare FederationPeer#revoke!. Same
# account, same row, same terminal status, no DeferredOperation, and — because
# the executor is what records the audited cause — no gate row naming it.
#
# Nothing was missing but the call: Sdwan::Executors::RevokeFederationPeer and
# Sdwan::Executors::ProposeFederationPeer, both ACTION_CATEGORY constants, both
# engine registrations (lib/powernode_system/engine.rb) and both seeded
# require_approval rows (PolicyDeclarations::SDWAN_OPERATOR_POLICIES) already
# existed and were already driven through the controller.
#
# Shaped as the CLASS guard sdwan_mcp_destroy_gate_parity_spec.rb established,
# for the same reason: each arm asserts three properties, because only the
# three together mean "gated".
#
#   1. :pending — the response is the gate's parked shape AND the row is
#      UNCHANGED. Shape alone would pass for an arm that wrote first and
#      reported `pending` afterwards.
#   2. approval — the operation the gate parked actually performs the write.
#      "It parks" and "the feature still works" are different claims, and a
#      params-key mismatch between arm and executor only surfaces here.
#   3. :proceed — under an explicit notify_and_proceed row the arm writes
#      inline and answers the pre-gate body, so gating did not become refusing.
#
# The default policy resolution is require_approval and this tool carries no
# agent, so (1) and (2) run against the tier a fresh account gets with nothing
# stubbed; (3) seeds one operator row for the category under test.
RSpec.describe "SdwanTool federation gate parity (IMP-2795453255c3)" do
  let(:account) { create(:account) }
  let(:tool)    { Ai::Tools::SdwanTool.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  def expect_parked(response)
    expect(response[:success]).to be(true), "gated arm reported failure: #{response.inspect}"
    expect(response[:data][:pending]).to be(true),
                                         "arm wrote inline instead of parking for approval: #{response.inspect}"
    response
  end

  # Resolved by the response's own deferred_operation_id rather than "the latest
  # row", so an example that parks more than one cannot execute the wrong one.
  def approve!(response)
    deferred = parked_operation(response)
    expect(deferred).to be_present, "no deferred operation was parked: #{response.inspect}"
    deferred.execute_now!
    deferred
  end

  def parked_operation(response)
    Ai::DeferredOperation.find_by(id: response.dig(:data, :deferred_operation_id))
  end

  describe "system_sdwan_revoke_federation_peer" do
    let!(:peer) { create(:system_federation_peer, account: account, status: "accepted") }

    it "parks the revocation instead of cutting cross-instance routing" do
      parked = expect_parked(
        call("system_sdwan_revoke_federation_peer",
             federation_peer_id: peer.id, reason: "remote signing key compromised")
      )

      # The survival oracle. status is the effect this verb exists to produce,
      # and metadata carries the audited cause the executor writes — both must
      # be exactly as they were before any operator acted.
      expect(peer.reload.status).to eq("accepted"),
                                    "the peer was revoked before any approval"
      expect(peer.metadata["revocation_reason"]).to be_nil,
                                                    "a revocation cause was recorded before any approval"

      op = parked_operation(parked)
      expect(op.action_category).to eq("sdwan.federation_peer_revoke")
      expect(op.executor_class).to eq("Sdwan::Executors::RevokeFederationPeer")
      expect(op.params["federation_peer_id"]).to eq(peer.id)
      expect(op.params["reason"]).to eq("remote signing key compromised")
    end

    # The post-approval arm. A parked operation applies its write later through
    # a DIFFERENT call site (Ai::ApprovalRequest → DeferredOperation#execute),
    # so an oracle that exercises only the inline branch leaves the approved
    # branch — the one that actually has to work — untested. The reason has to
    # survive the approval window too: it is carried on the operation's params,
    # not by the caller, once the arm stops writing.
    it "revokes with its audited cause once the parked operation is approved" do
      parked = expect_parked(
        call("system_sdwan_revoke_federation_peer",
             federation_peer_id: peer.id, reason: "remote signing key compromised")
      )
      approve!(parked)

      expect(peer.reload.status).to eq("revoked")
      expect(peer.metadata["revocation_reason"]).to eq("remote signing key compromised")
    end

    it "revokes inline and answers the pre-gate body under notify_and_proceed" do
      seed_operator_policy!("sdwan.federation_peer_revoke")

      r = call("system_sdwan_revoke_federation_peer",
               federation_peer_id: peer.id, reason: "remote signing key compromised")

      expect(r[:success]).to be(true), r.inspect
      expect(r[:data][:pending]).to be_nil
      expect(r[:data][:revoked]).to be(true)
      expect(r[:data][:federation_peer][:status]).to eq("revoked")
      expect(r[:data][:federation_peer][:revocation_reason]).to eq("remote signing key compromised")
      expect(peer.reload.status).to eq("revoked")
    end

    # AutonomyGate opens the DeferredOperation BEFORE it branches on policy, so
    # "no row was opened" proves the gate was never reached — i.e. the arm
    # refused on scope rather than parking an operation that could not run.
    it "refuses a peer in another account without opening a gate row" do
      foreign = create(:system_federation_peer, account: create(:account), status: "accepted")

      expect {
        r = call("system_sdwan_revoke_federation_peer", federation_peer_id: foreign.id, reason: "x")
        expect(r[:success]).to be(false)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(foreign.reload.status).to eq("accepted")
    end

    # The bypass this task closed, stated as the property rather than the
    # mechanism: the two routes to "revoked" on THIS tool must land on one
    # policy and one audit trail, so an agent refused on either cannot reach
    # the other. update_federation_peer has gated since IMP-ca3440a11a9a.
    it "reaches the same category and executor as the update arm's revoke leg" do
      via_update = expect_parked(
        call("system_sdwan_update_federation_peer",
             federation_peer_id: peer.id, status: "revoked", reason: "via update")
      )
      via_revoke = expect_parked(
        call("system_sdwan_revoke_federation_peer",
             federation_peer_id: peer.id, reason: "via revoke")
      )

      expect(parked_operation(via_revoke).action_category)
        .to eq(parked_operation(via_update).action_category)
      expect(parked_operation(via_revoke).executor_class)
        .to eq(parked_operation(via_update).executor_class)
      expect(peer.reload.status).to eq("accepted"),
                                    "one of the two routes to 'revoked' still writes inline"
    end
  end

  describe "system_sdwan_propose_federation_peer" do
    let(:propose_params) { { remote_instance_url: "https://peer.example.test" } }

    it "parks the proposal instead of writing the row" do
      expect {
        parked = expect_parked(call("system_sdwan_propose_federation_peer", **propose_params))

        op = parked_operation(parked)
        expect(op.action_category).to eq("sdwan.federation_peer_propose")
        expect(op.executor_class).to eq("Sdwan::Executors::ProposeFederationPeer")
        expect(op.params["attributes"]["remote_instance_url"]).to eq("https://peer.example.test")
      }.not_to change(::System::FederationPeer, :count)
    end

    it "creates the peer once the parked operation is approved" do
      parked = expect_parked(call("system_sdwan_propose_federation_peer", **propose_params))

      expect { approve!(parked) }.to change(::System::FederationPeer, :count).by(1)
      created = ::System::FederationPeer.where(account_id: account.id).last
      expect(created.remote_instance_url).to eq("https://peer.example.test")
      expect(created.status).to eq("proposed")
    end

    it "proposes inline and renders the row under notify_and_proceed" do
      seed_operator_policy!("sdwan.federation_peer_propose")

      r = call("system_sdwan_propose_federation_peer", **propose_params)

      expect(r[:success]).to be(true), r.inspect
      expect(r[:data][:pending]).to be_nil
      expect(r[:data][:federation_peer][:status]).to eq("proposed")
      expect(r[:data][:federation_peer][:remote_instance_url]).to eq("https://peer.example.test")
      expect(::System::FederationPeer.where(account_id: account.id).count).to eq(1)
    end

    # A payload that could never save must not park an approval an operator has
    # to dispose of — the same validate-before-gate contract every other create
    # arm on this tool keeps, and the one the REST twin's gate_create! keeps.
    it "refuses an invalid payload up front without opening a gate row" do
      expect {
        expect {
          r = call("system_sdwan_propose_federation_peer", remote_instance_url: "")
          expect(r[:success]).to be(false)
        }.not_to change(Ai::DeferredOperation, :count)
      }.not_to change(::System::FederationPeer, :count)
    end

    # IMP-3a32dc649043's refusal predates the gate and must survive it: the
    # token refusal is UP FRONT, so it neither parks an approval nor reaches
    # the executor whose default is to mint. Asserted on both policy tiers,
    # because a refusal that only holds on one of them is not a refusal.
    describe "the token refusal survives the gate (IMP-3a32dc649043)" do
      let(:synthetic_token) { "SYNTHETIC-NOT-A-REAL-TOKEN-000000" }
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

      it "refuses generate_token before the gate, parking nothing" do
        expect {
          r = call("system_sdwan_propose_federation_peer", **propose_params, generate_token: true)
          expect(r[:success]).to be(false)
          expect(r.to_json).not_to include(synthetic_token)
        }.not_to change(Ai::DeferredOperation, :count)

        expect(mint_calls).to be_empty, "a token was minted and then withheld, stranding the peer"
      end

      # The executor mints BY DEFAULT (attrs[:generate_token] != false), so a
      # gated arm that forwarded the caller's attributes untouched would start
      # minting a token the caller never asked for and cannot read — the exact
      # stranding IMP-3a32dc649043 refused. The opt-out has to be explicit in
      # the replayed params, on both the parked and the inline branch.
      it "opts the executor out of minting on the parked branch" do
        parked = expect_parked(call("system_sdwan_propose_federation_peer", **propose_params))

        expect(parked_operation(parked).params["attributes"]["generate_token"]).to be(false)

        approve!(parked)

        expect(mint_calls).to be_empty,
                              "the approved proposal minted an acceptance token nobody can read"
        expect(::System::FederationPeer.where(account_id: account.id).last.acceptance_token_digest)
          .to be_nil
      end

      it "opts the executor out of minting on the inline branch" do
        seed_operator_policy!("sdwan.federation_peer_propose")

        r = call("system_sdwan_propose_federation_peer", **propose_params)

        expect(r[:success]).to be(true), r.inspect
        expect(mint_calls).to be_empty
        expect(r.to_json).not_to include(synthetic_token)
        expect(::System::FederationPeer.where(account_id: account.id).last.acceptance_token_digest)
          .to be_nil
      end
    end
  end

  # The RATCHET. Everything above pins the two arms this task moved; this pins
  # the CLASS, so the next destructive arm cannot arrive outside the regime the
  # way these did.
  #
  # The gap closed here took four improvements to work through one file
  # (IMP-051f3811ac60 creates, IMP-6c482005db87 creates, IMP-c9798d9d5671
  # updates, IMP-800b25c1cc45 destroys, and this one the federation pair)
  # because each was found by reading the file rather than by a failing test —
  # SdwanTool's own header asserted the parity claim in PROSE for the whole of
  # that time while six arms contradicted it. A claim about every arm needs an
  # oracle over every arm.
  #
  # Structural rather than behavioural on purpose: a per-arm behavioural
  # example only covers arms someone remembered to write one for, which is the
  # failure mode itself. This reads the tool's own source, so an arm added
  # tomorrow is in scope the moment it is written.
  describe "every destructive and trust-boundary arm routes through the gate seam" do
    # Named after the operations that are irreversible, cut traffic, or cross a
    # trust boundary — the set SdwanTool's header claims cannot disagree with
    # the REST surface. The trailing `[!?]?` catches a bang arm: a
    # `revoke_peer!` invisible to this scan would be a gate hole the ratchet
    # reported as clean, which is the one failure mode a guard must not have.
    #
    # `def`s, not top-level constants: a constant assigned inside a describe
    # block lands on ::Object, polluting the global namespace and warning on a
    # double load.
    def destructive_arm_pattern
      /\A(delete|destroy|revoke|detach|release|propose|failover|deactivate)_[a-z0-9_]*[!?]?\z/
    end

    # Deliberate, reviewed exemptions. EMPTY, and adding an entry is the point
    # at which someone has to write down why an arm may write without a policy
    # evaluation — not a line a passing suite ever quietly grows.
    def exempt_arms
      []
    end

    # A def, not a let: the file is parsed once per example and nothing here is
    # memoized state the examples share.
    def tool_source
      ::Ai::Tools::SdwanTool.instance_method(:call).source_location.first.then { |p| File.read(p) }
    end

    # Splits the tool's instance methods into { name => body }. The file's
    # methods are uniformly indented six spaces (module Ai / module Tools /
    # class SdwanTool), which is what anchors the scan.
    def arm_bodies
      bodies = {}
      current = nil
      tool_source.each_line do |line|
        if (m = line.match(/\A      def ([a-z_][a-z0-9_]*[!?]?)[\s(=]/))
          current = m[1]
          bodies[current] = +""
        elsif current
          break if line.match?(/\A    end\b/)

          bodies[current] << line
        end
      end
      bodies
    end

    def destructive_arms
      arm_bodies.select { |name, _| name.match?(destructive_arm_pattern) }
                .except(*exempt_arms)
    end

    # Guards the guard. A scan that matched nothing would pass silently and
    # assert nothing at all — the one way this example could rot into decoration
    # (an indentation change, a namespace change, a rename of the seam).
    it "actually finds the arms it claims to check" do
      expect(destructive_arms.keys).to include(
        "delete_network", "detach_peer", "delete_virtual_ip", "delete_firewall_rule",
        "delete_route_policy", "delete_port_mapping", "delete_ipfix_collector",
        "release_host_bridge", "propose_federation_peer", "revoke_federation_peer",
        "revoke_access_grant", "revoke_user_device", "failover_virtual_ip"
      )
      expect(destructive_arms.size).to be >= 17
    end

    it "leaves no arm writing outside Ai::AutonomyGate" do
      ungated = destructive_arms.reject { |_, body| body.include?("gated_result") }.keys

      expect(ungated).to be_empty,
                         "these SdwanTool arms perform a destructive or trust-boundary write without " \
                         "routing through #gated_result: #{ungated.join(', ')}. Route them through the " \
                         "seam (see #accept_federation_peer) rather than calling Ai::AutonomyGate — or, " \
                         "if the arm genuinely must not be gated, add it to EXEMPT_ARMS with the reason."
    end
  end
end
