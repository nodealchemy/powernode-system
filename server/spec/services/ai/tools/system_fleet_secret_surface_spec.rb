# frozen_string_literal: true

require "rails_helper"

# IMP-27cc7dceb97b, sites 2 and 3 — two MORE places SystemFleetTool put secret
# material on the MCP result surface. They are in one file because they share
# the sink analysis, NOT the remedy: the right substitute is decided per site
# and differs, and each `describe` states its own.
#
# THE SHARED SINK. Ai::AgentToolBridgeService writes
# `result_json.to_s.truncate(200)` into `tool_calls_log`
# (agent_tool_bridge_service.rb:413), which Api::V1::Ai::ConversationsController
# persists into ai_messages.processing_metadata — durable jsonb, never
# re-filtered on read; Ai::SensitiveParams cannot reach it because the value is
# a String and `.filter` returns non-Hash input unchanged. It also returns the
# FULL json (50 KB cap) which is appended as a role:"tool" message and sent to
# the model provider on the next turn.
#
# NOTE ON FIXTURES: no real signing ever happens here. The capability-token
# examples stub the signer and use synthetic envelope/signature constants, so
# no Ed25519 signature over real key material is produced, and no assertion
# interpolates a value into a failure message.
RSpec.describe "Ai::Tools::SystemFleetTool MCP-surface secret material" do
  let(:account) { create(:account) }
  let(:creator) do
    create(:user, account: account,
                  permissions: %w[system.nodes.read system.node_instances.read
                                  system.node_instances.manage system.modules.read])
  end
  let(:agent) { create(:ai_agent, account: account, creator: creator) }
  let(:bridge) { Ai::AgentToolBridgeService.new(agent: agent, account: account) }

  # Production shape, verbatim. COVERAGE BOUNDARY: this drives the REAL bridge
  # dispatch and the REAL jsonb column, but hand-assembles the tool_calls_log
  # hop rather than running #execute_tool_loop against a stubbed LLM.
  def dispatch_and_persist(tool_name, arguments)
    result_json = bridge.dispatch_tool_call(name: tool_name, arguments: arguments)

    tool_calls_log = [ {
      iteration: 1, tool: tool_name, duration_ms: 1,
      result_preview: result_json.to_s.truncate(200)
    } ]

    message = create(:ai_message,
                     agent: agent, role: "assistant",
                     processing_metadata: { model: "spec", tool_calls_log: tool_calls_log })

    [ JSON.parse(result_json).with_indifferent_access,
      result_json,
      ::Ai::Message.find(message.id).processing_metadata.to_json ]
  end

  # === SITE 2 ==============================================================
  #
  # `system_mint_peer_capability_token` returned the A2A capability token's
  # `envelope` AND `signature` — together, a complete bearer credential, and an
  # Ed25519 signature produced from Vault-held signing material that
  # PeerCapabilityTokenSigner is explicitly built never to log.
  #
  # SUBSTITUTE CHOSEN: a REFUSAL, not a retrieval path and not a redaction.
  # This differs from the CI-worker site deliberately:
  #
  #   * There is no retrieval path to name. Unlike a CI worker token, no
  #     endpoint anywhere re-delivers a minted capability token to a caller.
  #     The two server-side minters both keep it:
  #     AgentFleetMissionService#mint_delegation_token mints the CROSS-instance
  #     edge into a delegation descriptor, and node_instance_peers#execute mints
  #     a SELF-EDGE token (caller == target) into a System::Task's options. So
  #     advertising a recovery path would be advertising one that does not exist.
  #   * Returning the envelope while withholding the signature would be worse
  #     than refusing: it produces an artifact that looks like a token, cannot
  #     be used as one, and still consumed the signing key.
  #
  # So the arm refuses BEFORE minting — nothing is signed, so nothing has to be
  # withheld. Nobody is stranded, and the refusal says so in-band: an agent
  # asking "may A invoke skill S on B?" already has the non-secret twin
  # `system_authorize_peer_call` (same gates, same arguments), and an operator
  # who wants the CROSS-instance call PERFORMED uses system_launch_agent_fleet.
  # This is the shape SdwanTool#propose_federation_peer already holds for its
  # acceptance token.
  describe "system_mint_peer_capability_token (site 2)" do
    let(:synthetic_envelope)  { '{"zz":"SyntheticCapabilityEnvelopeFixtureFFFFFFFF"}' }
    let(:synthetic_signature) { "zzSyntheticEd25519SignatureFixtureGGGGGGGGGGGG" }

    def cap_peer(handle:, declared_skills: [], granted: [])
      inst = create(:system_node_instance, account: account, status: "running")
      ::System::NodeInstancePeer.create!(
        node_instance: inst, account: account, handle: "#{handle}-#{SecureRandom.hex(2)}",
        status: "active", enabled: true, trust_score: 0.5, daily_decision_budget: 10,
        declared_skills: declared_skills
      ).tap { |p| p.grant_peer_skills!(granted) if granted.any? }
      inst
    end

    let!(:caller_inst) { cap_peer(handle: "caller", granted: %w[embed-*]) }
    let!(:target_inst) { cap_peer(handle: "target", declared_skills: [ { "name" => "embed-text" } ]) }

    let(:synthetic_token) do
      ::System::PeerCapabilityTokenSigner::Token.new(
        envelope_json: synthetic_envelope,
        signature_b64: synthetic_signature,
        handle: "cap-handle",
        public_key_b64: "zzSyntheticPublicKeyFixture",
        claims: { "sub" => caller_inst.id, "aud" => target_inst.id,
                  "skill" => "embed-text", "jti" => "zz-jti",
                  "exp" => 5.minutes.from_now.to_i }
      )
    end

    # TWO EXAMPLES ON PURPOSE, and the split is load-bearing.
    #
    # `expect(...).not_to receive(:mint!)` SUPERSEDES an `allow(...)` on the
    # same method, and RSpec's MockExpectationError descends from Exception
    # rather than StandardError — so under that expectation a minting mutant
    # raises past the tool's `rescue StandardError` and never returns the
    # fixture. Combining the two in one example would leave the body scan
    # unable to fail under ANY implementation: green against correct and buggy
    # code alike. So the scan gets its own example, where the signer is merely
    # stubbed and a minting mutant really would hand the fixture back.
    describe "with the signer stubbed (the body scan can actually fail here)" do
      before do
        # Both entry points: `.mint!` delegates to an instance #mint!, and a
        # mutant calling the instance form directly would otherwise produce a
        # REAL Ed25519 signature in the payload.
        allow(::System::PeerCapabilityTokenSigner).to receive(:mint!).and_return(synthetic_token)
        allow_any_instance_of(::System::PeerCapabilityTokenSigner)
          .to receive(:mint!).and_return(synthetic_token)
      end

      it "discloses no envelope/signature pair on any sink, and refuses usefully" do
        result, provider_payload, persisted = dispatch_and_persist(
          "system_mint_peer_capability_token",
          { caller_instance_id: caller_inst.id, target_instance_id: target_inst.id, skill: "embed-text" }
        )

        [ synthetic_envelope, synthetic_signature ].each do |needle|
          expect(provider_payload.include?(needle)).to be(false),
            "the role:\"tool\" payload forwarded to the model provider carries capability-token material"
          expect(persisted.include?(needle)).to be(false),
            "the persisted ai_messages row carries capability-token material"
        end

        expect(result[:success]).to be(false)
        # POSITIVE: the refusal is not a dead end — it names both real paths.
        expect(result[:error].to_s).to match(/system_authorize_peer_call/)
        expect(result[:error].to_s).to match(/system_launch_agent_fleet/)
      end
    end

    it "does not touch the signing key at all — neither entry point is called" do
      # The stronger property, isolated so it cannot mask the scan above: an
      # implementation that minted and THEN stripped the signature would fail
      # here, correctly, because it still consumed the Vault key and produced a
      # live credential server-side.
      expect(::System::PeerCapabilityTokenSigner).not_to receive(:mint!)
      expect_any_instance_of(::System::PeerCapabilityTokenSigner).not_to receive(:mint!)

      result, = dispatch_and_persist(
        "system_mint_peer_capability_token",
        { caller_instance_id: caller_inst.id, target_instance_id: target_inst.id, skill: "embed-text" }
      )

      expect(result[:success]).to be(false)
    end

    it "leaves the non-secret twin working, so the caller is not stranded" do
      result, = dispatch_and_persist(
        "system_authorize_peer_call",
        { caller_instance_id: caller_inst.id, target_instance_id: target_inst.id, skill: "embed-text" }
      )

      expect(result[:success]).to be(true)
      expect(result.dig(:data, :authorized)).to be(true)
    end
  end

  # === SITE 3 ==============================================================
  #
  # `system_list_disk_image_webhooks` returned `secret_preview` — the first 8
  # characters of the live HMAC webhook secret (System::DiskImageWebhook
  # persists `secret[0, 8]`).
  #
  # SUBSTITUTE CHOSEN: a plain REMOVAL — no retrieval path, no refusal. This is
  # a read action, and unlike sites 1/2/4 nothing here is being minted, so
  # there is nothing to deliver and nobody to strand:
  #
  #   * The column still exists and the operator UI still renders it. The REST
  #     twin (Api::V1::System::DiskImageWebhooksController#index →
  #     CiWebhooksTab.tsx) is the surface that field was designed for — "this
  #     is the secret you saved earlier" only means anything to a human looking
  #     at a screen.
  #   * On the MCP arm nothing reads it: `id` and `label` already disambiguate
  #     rows, and no executor or agent flow consumes the preview.
  #
  # So the only thing it bought on this surface was a partial disclosure into
  # the same two durable sinks as a whole secret. That is precisely the
  # reasoning badbaef6c used to delete the 12-char previews from
  # bootstrap_disk_image_ci, applied to its sibling.
  #
  # (Judgment stated rather than hidden: the prefix is "pndis_" + 2 random
  # base64url characters, so roughly 12 bits — weak on its own. It is removed
  # for consistency with the invariant this campaign asserts everywhere else,
  # not because 12 bits forges an HMAC.)
  describe "system_list_disk_image_webhooks (site 3)" do
    let!(:webhook) do
      ::System::DiskImageWebhook.create_with_secret!(account: account, label: "mcp-preview-webhook").first
    end

    it "lists the webhook without any slice of its secret" do
      result, provider_payload, persisted = dispatch_and_persist(
        "system_list_disk_image_webhooks", {}
      )

      preview = webhook.reload.secret_preview
      # Guard the oracle: an empty needle would make every assertion vacuous.
      expect(preview).to be_present
      expect(preview.length).to eq(8)

      # This site's mint sat around char 130 of the result — inside the
      # 200-char persisted window — so the row assertion genuinely
      # discriminates here, unlike the CI-worker site where the serializer's
      # leading UUIDs pushed it out.
      # Prove the row assertion is not vacuous: `secret_preview` sat at ~char
      # 147 of the pre-fix result, so it WOULD have been inside truncate(200)'s
      # ~197 retained chars. That margin depends on the fixture label length,
      # which is why the offset is asserted rather than assumed — a longer
      # label would silently push the needle out of the window and leave the
      # assertion below green against disclosing code.
      preview_slot = provider_payload.index('"status"')
      expect(preview_slot).to be_present
      expect(preview_slot).to be < 190
      expect(persisted.include?(preview)).to be(false),
        "the persisted ai_messages row carries a prefix of the live webhook secret"
      expect(provider_payload.include?(preview)).to be(false),
        "the provider-bound payload carries a prefix of the live webhook secret"
      result.dig(:data, :webhooks).each do |w|
        expect(w.key?("secret_preview")).to be(false),
          "a listed webhook still carries secret_preview"
      end

      # POSITIVE: the listing is still fully usable for what it is for.
      expect(result[:success]).to be(true)
      listed = result.dig(:data, :webhooks).find { |w| w[:id] == webhook.id }
      expect(listed).to be_present
      expect(listed[:label]).to eq("mcp-preview-webhook")
      expect(listed[:status]).to eq("active")
      expect(listed).to include("received_count", "created_at")
      expect(result.dig(:data, :count)).to eq(1)
    end
  end
end
