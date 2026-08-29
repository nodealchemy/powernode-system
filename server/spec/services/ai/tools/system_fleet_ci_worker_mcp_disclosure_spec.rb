# frozen_string_literal: true

require "rails_helper"

# IMP-27cc7dceb97b — an MCP tool RESULT is not a private channel.
#
# This is the same defect, on the same feature, as the one closed in core by
# badbaef6c (IMP-fa6cf8ee1eb6) for Ai::Tools::DiskImageOperatorTool
# #provision_ci_worker. SystemFleetTool#system_provision_ci_worker is the
# ALIAS of that capability living in the system extension, and it is in the
# production instance grant — so an agent told "provision_ci_worker will not
# hand you the token" reaches for this name and gets it.
#
# Ai::AgentToolBridgeService does two things with every tool result that the
# REST twin (Api::V1::System::CiWorkersController#create) does not:
#
#   * writes `result_json.to_s.truncate(200)` into `tool_calls_log`
#     (agent_tool_bridge_service.rb:413), which
#     Api::V1::Ai::ConversationsController persists verbatim into
#     ai_messages.processing_metadata — a durable jsonb column never
#     re-filtered on read. Ai::SensitiveParams cannot intervene: the value is
#     a String, and `.filter` returns non-Hash input unchanged;
#   * returns the FULL json (truncate_result caps at 50 KB, not 200 B) and
#     appends it as a `role: "tool"` message forwarded to the model provider
#     on the next turn.
#
# So a mint that is correctly "shown once, never stored" over HTTP becomes, on
# this surface, a durable at-rest copy AND an outbound transmission to a
# third-party inference provider.
#
# TRUNCATION-WINDOW HONESTY (carried from the core iteration). The persisted
# preview is only 200 chars. `success_result` wraps the payload as
# {"success":true,"data":{...}} and CiWorkerSerializer leads with two 36-char
# UUIDs, a name, a description, a status and timestamps — so `token_plaintext`
# sat PAST char 200 and the persisted-row assertion is TRUE EVEN AGAINST THE
# BUGGY CODE. It is vacuously green and is retained only as a regression fence
# against a future result reshuffle bringing the mint back inside the window;
# the assertion that actually discriminates here is the one on
# `provider_payload`, the untruncated json bound for the model provider. That
# is stated rather than implied so a later reader does not mistake the row
# check for the oracle.
#
# Absence is paired with a positive assertion in every example: an
# absence-only oracle is satisfied by a tool that returns nothing at all and
# quietly breaks the feature.
#
# NOTE ON FIXTURES: the "token" here is a synthetic constant, never a real
# mint. Nothing in this file prints or interpolates it into a failure message;
# assertions are on `include?`, so RSpec never echoes the needle.
RSpec.describe "Ai::Tools::SystemFleetTool CI-worker MCP-path secret disclosure" do
  # Synthetic, recognisably fake, long enough that an accidental substring
  # match is impossible. NOT key material.
  let(:synthetic_worker_token) { "swt_zzSyntheticFleetWorkerTokenFixtureDDDDDDDD" }

  let(:account) { create(:account) }
  let(:creator) do
    create(:user, account: account,
                  permissions: %w[system.nodes.read system.ci_workers.create])
  end
  let(:agent) { create(:ai_agent, account: account, creator: creator) }
  let(:bridge) { Ai::AgentToolBridgeService.new(agent: agent, account: account) }

  before do
    Role.find_or_create_by!(name: "ci_worker") do |r|
      r.role_type = "user"
      r.description = "CI worker"
    end

    # Pin the mint to a synthetic value so the oracle has a needle.
    allow(::Worker).to receive(:generate_secure_token).and_return(synthetic_worker_token)
  end

  # Production shape, verbatim: the bridge builds the provider-bound json and
  # the tool_calls_log preview; ConversationsController persists that log into
  # ai_messages.processing_metadata.
  #
  # COVERAGE BOUNDARY, stated rather than implied: this drives the REAL bridge
  # dispatch and the REAL jsonb column, but hand-assembles the tool_calls_log
  # hop between them rather than running #execute_tool_loop against a stubbed
  # LLM. It pins "this tool's result carries no mint", not "no future bridge
  # change can route a result into processing_metadata by another key".
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

  describe "system_provision_ci_worker" do
    it "leaves no minted token in the provider-bound payload, the tool result, or the persisted ai_messages row" do
      result, provider_payload, persisted = dispatch_and_persist(
        "system_provision_ci_worker", { name: "mcp-disclosure-fleet-worker" }
      )

      # THE DISCRIMINATING ASSERTION — the full json is what reaches the model
      # provider, and it is not truncated to 200 bytes.
      expect(provider_payload.include?(synthetic_worker_token)).to be(false),
        "the role:\"tool\" payload forwarded to the model provider carries the minted CI worker token"
      expect(result.to_json.include?(synthetic_worker_token)).to be(false),
        "the tool result carries the minted CI worker token"
      # A prefix of a token is a partial disclosure into the same sinks.
      expect(provider_payload.include?(synthetic_worker_token[0, 12])).to be(false),
        "the provider-bound payload carries a prefix of the minted CI worker token"
      # Retained regression fence; vacuously green against the buggy code (see
      # the TRUNCATION-WINDOW HONESTY note above).
      expect(persisted.include?(synthetic_worker_token)).to be(false),
        "the persisted ai_messages.processing_metadata carries the minted CI worker token"

      # POSITIVE: the worker really exists, is correctly roled, is addressable,
      # and the caller is told in-band where the plaintext CAN be obtained.
      expect(result[:success]).to be(true)
      worker = account.workers.find_by(name: "mcp-disclosure-fleet-worker")
      expect(worker).to be_present
      # PINS THE NEEDLE. Every absence assertion above is vacuous if the stub
      # is not actually the mint — a future refactor that mints inline (say,
      # SecureRandom.urlsafe_base64 inside create_worker!) would make
      # `generate_secure_token` a silent no-op, the needle would never exist,
      # and all four absences would go green against disclosing code while the
      # positives still passed. This ties the stub to the row that was written.
      expect(worker.token_digest).to eq(::Digest::SHA256.hexdigest(synthetic_worker_token))
      expect(result.dig(:data, :ci_worker, :id)).to eq(worker.id)
      expect(result.dig(:data, :ci_worker, :roles)).to include("ci_worker")
      expect(result.dig(:data, :ci_worker, :status)).to eq("active")
      expect(result.dig(:data, :token_delivery).to_s).to match(%r{rotate_token})
    end
  end
end
