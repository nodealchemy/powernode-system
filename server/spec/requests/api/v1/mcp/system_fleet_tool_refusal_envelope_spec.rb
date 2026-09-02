# frozen_string_literal: true

require "rails_helper"

# IMP-a00997333d8f — REFUSALS from system_provision_instance reached the caller
# as a JSON-RPC TRANSPORT fault.
#
# Ai::Tools::SystemFleetTool#call rescued only ActiveRecord::RecordNotFound,
# ActiveRecord::RecordInvalid, ArgumentError and
# ::System::NodeModuleVersion::InvalidTransition
# (extensions/system/server/app/services/ai/tools/system_fleet_tool.rb:1852-1857
# before this change). Two refusal classes raised on the provisioning path are
# in neither list:
#
#   System::ProvisioningService::ProvisioningError
#     (provisioning_service.rb:17 defines it; :359 raises "Node is disabled";
#      :248 deliberately re-raises it past the service's own StandardError
#      rescue, so it arrives at the tool as an exception, not a Result)
#   System::Autonomy::SelfManagementFence::SelfManagementViolation
#     (self_management_fence.rb:65 defines it; :94 raises it; asserted on the
#      provisioning path at provisioning_service.rb:34)
#
# Escaping #call, they hit the core controller's generic handler at
# server/app/controllers/api/v1/mcp/streamable_http_controller.rb:137-139, which
# renders JSON-RPC -32603 "Internal error: ...". A -32603 with no isError reads
# to an agent as a TRANSPORT fault, i.e. retryable — and the retry raises
# identically, so a permanently correctable condition (an operator disabled the
# node) produces an unbounded provisioning loop against the fleet.
#
# The oracle is therefore the CALLER-VISIBLE ENVELOPE over the real HTTP/JSON-RPC
# path, not "an exception was raised": isError must be set (the controller sets
# it at :693, keyed on result[:success] == false) and the reason must be present.
# The retry assertion is the actual defect — no assertion on a single call can
# see a loop.
#
# The opposite guard matters just as much: a GENUINE internal fault must still
# surface as -32603. A blanket rescue that tidied every StandardError into a
# refusal would pass every assertion above while hiding real failures.
RSpec.describe "MCP tools/call — system_fleet_tool refusal envelope", type: :request do
  let(:mcp_endpoint) { "/api/v1/mcp/message" }

  def call_tool(tool_name, arguments, headers:, id: 1)
    post mcp_endpoint,
         params: { jsonrpc: "2.0", id: id, method: "tools/call",
                   params: { "name" => "platform.#{tool_name}", "arguments" => arguments } }.to_json,
         headers: headers
  end

  def headers_for(user)
    oauth_app = create(:oauth_application, :mcp_client)
    token = create(:oauth_access_token, oauth_app: oauth_app, resource_owner_id: user.id, scopes: "read write")
    { "Authorization" => "Bearer #{token.plaintext_token}", "Content-Type" => "application/json" }
  end

  def tool_payload(body)
    JSON.parse(body.dig("result", "content", 0, "text"))
  end

  let(:operator) do
    # The MCP registrar enforces a per-TOOL permission floor (system.nodes.read)
    # before the tool's own per-ACTION map (system.instances.create,
    # system_fleet_tool.rb:139) is consulted. Both are needed to reach #call.
    user_with_permissions("system.nodes.read", "system.instances.create")
  end
  let(:account)       { operator.account }
  let(:headers)       { headers_for(operator) }
  let(:region)        { create(:system_provider_region) }
  let(:instance_type) { create(:system_provider_instance_type) }

  def provision(node)
    call_tool("system_provision_instance",
              { "node_id" => node.id,
                "provider_region_id" => region.id,
                "provider_instance_type_id" => instance_type.id },
              headers: headers)
  end

  describe "a disabled node (System::ProvisioningService::ProvisioningError)" do
    let(:node) { create(:system_node, account: account, enabled: false) }

    it "returns an application-level refusal, not a JSON-RPC transport fault" do
      provision(node)

      expect(response).to have_http_status(:ok)
      body = json_response

      # The defect in one assertion: a -32603 error object instead of a result.
      expect(body["error"]).to be_nil,
                               "refusal surfaced as JSON-RPC error #{body.dig('error', 'code')}: " \
                               "#{body.dig('error', 'message')}"
      expect(body.dig("result", "isError")).to be(true)

      payload = tool_payload(body)
      expect(payload["success"]).to be(false)
      expect(payload["error"]).to match(/disabled/i)
    end

    it "names the refusal machine-readably so a caller can branch without parsing prose" do
      provision(node)

      payload = tool_payload(json_response)
      expect(payload["refusal_code"]).to eq("provisioning_refused")
      expect(payload["retryable"]).to be(false)
    end

    # A determinism fence, NOT proof that the loop is closed. The agent-side
    # retry loop is not observable from this seam, and the payload here is
    # static by construction (no counter, and the registrar's per-agent limiter
    # never arms — an OAuth user token carries no agent_id), so this cannot fail
    # for a reason the first example would not already catch. It is kept because
    # a future stateful degradation — a partial write, a counter, a second call
    # taking a different arm — would show up here and nowhere else.
    it "returns the SAME refusal on an identical retry rather than looping" do
      provision(node)
      first = json_response
      provision(node)
      second = json_response

      expect(second["error"]).to be_nil
      expect(second.dig("result", "isError")).to be(true)
      expect(tool_payload(second)).to eq(tool_payload(first))
    end
  end

  describe "the control plane's own hosting node (SelfManagementViolation)" do
    let(:node) { create(:system_node, account: account, enabled: true) }

    before do
      ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, node.id)
    end

    it "returns an application-level refusal naming INV-1, not a transport fault" do
      provision(node)

      body = json_response
      expect(body["error"]).to be_nil,
                               "refusal surfaced as JSON-RPC error #{body.dig('error', 'code')}: " \
                               "#{body.dig('error', 'message')}"
      expect(body.dig("result", "isError")).to be(true)

      payload = tool_payload(body)
      expect(payload["success"]).to be(false)
      expect(payload["error"]).to match(/self-management/i)
      expect(payload["refusal_code"]).to eq("self_management_violation")
      expect(payload["retryable"]).to be(false)
    end

    it "returns the SAME refusal on an identical retry rather than looping" do
      provision(node)
      first = json_response
      provision(node)
      second = json_response

      expect(second["error"]).to be_nil
      expect(second.dig("result", "isError")).to be(true)
      expect(tool_payload(second)).to eq(tool_payload(first))
    end
  end

  # The inverse guard. If the fix had widened the rescue to StandardError (or to
  # a class that also covers faults), this example would go green in the wrong
  # direction: a real internal failure would come back as a tidy refusal with
  # isError set, and nothing would ever page.
  describe "a genuine internal fault" do
    let(:node) { create(:system_node, account: account, enabled: true) }

    before do
      allow(::System::ProvisioningService).to receive(:provision_instance)
        .and_raise(NoMethodError, "undefined method `zz_mutation_fixture_boom' for nil")
    end

    it "still surfaces as JSON-RPC -32603, because it is not a refusal" do
      provision(node)

      body = json_response
      expect(body.dig("error", "code")).to eq(-32603),
                                           "a genuine fault was converted into an application-level result: " \
                                           "#{body['result'].inspect}"
      expect(body["result"]).to be_nil
      # Bound to the fault THIS example injects. Without it any unrelated
      # internal error upstream of the stub — a factory change, a serializer
      # blowing up — produces the identical -32603 and the example passes green
      # while never reaching the stub or the new rescue arms at all.
      expect(body.dig("error", "message")).to include("zz_mutation_fixture_boom")
    end
  end
end
