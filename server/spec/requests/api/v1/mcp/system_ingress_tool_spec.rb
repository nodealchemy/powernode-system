# frozen_string_literal: true

require "rails_helper"

# REQUEST-level coverage for expose_service_publicly / expose_service_local /
# expose_service_public_tcp (Path B), driven through the REAL MCP dispatch path:
#
#   POST /api/v1/mcp/message (tools/call)
#     -> Ai::Tools::McpPlatformToolRegistrar.execute_tool (permission floor)
#     -> Ai::Tools::SystemIngressTool#call (per-action permission + routing)
#     -> System::Ai::Skills::{ExposeServicePubliclyExecutor,ExposeServiceLocalExecutor,
#                             ExposeServicePublicTcpExecutor}
#
# The existing specs at
#   extensions/system/server/spec/services/system/ai/skills/expose_service_publicly_executor_spec.rb
#   extensions/system/server/spec/services/system/ai/skills/expose_service_local_executor_spec.rb
#   extensions/system/server/spec/services/system/ai/skills/expose_service_public_tcp_executor_spec.rb
#   extensions/system/server/spec/services/ai/tools/system_ingress_tool_spec.rb
# already cover orchestration/routing/permission-gating logic directly against
# the executor/tool objects. This spec instead asserts the HTTP/JSON-RPC
# contract a real MCP client depends on: Doorkeeper auth, the "platform."
# tool-name prefix, the tools/call envelope (isError / content[0].text), and
# real permission resolution via User#has_permission? end to end.
#
# Sub-collaborators (Ai::Tools::SdwanTool, AcmeCertificateProvisionExecutor,
# ReverseProxyComposeExecutor, Sdwan::ServiceExposureWriter) are stubbed at the
# same instance boundary the service-level specs use — this spec is about the
# transport/auth/routing layer, not re-proving orchestration internals.
RSpec.describe "MCP tools/call — system_ingress_tool (expose_service_publicly / expose_service_local / " \
               "expose_service_public_tcp)",
               type: :request do
  let(:mcp_endpoint) { "/api/v1/mcp/message" }

  def jsonrpc_request(method:, params: {}, id: 1)
    { jsonrpc: "2.0", id: id, method: method, params: params }.to_json
  end

  def call_tool(tool_name, arguments, headers:, id: 1)
    post mcp_endpoint,
         params: jsonrpc_request(
           method: "tools/call",
           params: { "name" => "platform.#{tool_name}", "arguments" => arguments },
           id: id
         ),
         headers: headers
  end

  def headers_for(user)
    oauth_app = create(:oauth_application, :mcp_client)
    token = create(:oauth_access_token, oauth_app: oauth_app, resource_owner_id: user.id, scopes: "read write")
    { "Authorization" => "Bearer #{token.plaintext_token}", "Content-Type" => "application/json" }
  end

  # tools/call always returns HTTP 200 with the tool's own success/error
  # threaded through result.content[0].text (JSON-RPC transport succeeded;
  # the tool-level outcome is inside the payload). This helper decodes that
  # inner payload for assertions.
  def tool_payload(body)
    JSON.parse(body.dig("result", "content", 0, "text"))
  end

  let(:manager) { user_with_permissions("system.ingress.read", "system.ingress.manage") }
  let(:account) { manager.account }

  # APO-1c (IMP-7e2bdc1774e4). All three executors declare
  # `requires_approval: true`, and BaseSkillExecutor#execute now honours it
  # BEFORE #perform. This spec is about the TRANSPORT — Doorkeeper auth, the
  # "platform." prefix, the tools/call envelope, permission resolution — so an
  # operator policy puts the gate on its proceed branch and leaves those
  # assertions measuring what they were written to measure. The two "approval
  # gating" blocks below deliberately outrank this row to exercise the other
  # branch. See spec/support/skill_gate_helpers.rb.
  before do
    auto_execute_skill_policy!(
      account,
      System::Ai::Skills::ExposeServicePubliclyExecutor,
      System::Ai::Skills::ExposeServiceLocalExecutor,
      System::Ai::Skills::ExposeServicePublicTcpExecutor
    )
  end

  # Outranks the account-wide auto_approve above on Ai::InterventionPolicy
  # #specificity_key's last element (priority) — every other element is equal
  # between the two rows, so the winner is deterministic rather than
  # insertion-ordered.
  def require_approval_for!(executor_class)
    ::Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: nil, scope: "global",
      action_category: executor_class.action_category,
      policy: "require_approval", priority: 50, is_active: true
    )
  end

  # ==========================================================================
  # expose_service_publicly
  # ==========================================================================
  describe "system_expose_service_publicly" do
    let(:network)  { create(:sdwan_network, account: account) }
    let(:hub_peer) { create(:sdwan_peer, network: network) }
    let(:backend)  { create(:sdwan_peer, network: network) }
    let(:vip_id)            { SecureRandom.uuid }
    let(:port_mapping_id)   { SecureRandom.uuid }
    let(:certificate_id)    { SecureRandom.uuid }

    def stub_sdwan_and_subexecutors_happy_path
      allow_any_instance_of(::Ai::Tools::SdwanTool).to receive(:execute) do |_tool, params:|
        case params[:action]
        when "system_sdwan_create_virtual_ip"
          { success: true, data: { virtual_ip: { id: vip_id, cidr: params[:cidr] } } }
        when "system_sdwan_create_port_mapping"
          { success: true, data: { port_mapping: { id: port_mapping_id } } }
        else
          { success: false, error: "unexpected action #{params[:action]}" }
        end
      end
      allow_any_instance_of(System::Ai::Skills::AcmeCertificateProvisionExecutor)
        .to receive(:execute)
        .and_return({ success: true, data: { certificate_id: certificate_id, certificate_status: "valid" } })
      allow_any_instance_of(System::Ai::Skills::ReverseProxyComposeExecutor)
        .to receive(:execute)
        .and_return({ success: true, data: { regenerated: true } })
    end

    def valid_arguments
      {
        "service_hostname" => "app.example.com", "service_protocol" => "https",
        "sdwan_network_id" => network.id, "sdwan_hub_peer_id" => hub_peer.id,
        "vip_cidr" => "fd00:beef::a/128", "dns_credential_id" => SecureRandom.uuid,
        "target_peer_id" => backend.id, "backend_port" => 8080
      }
    end

    describe "happy path" do
      before { stub_sdwan_and_subexecutors_happy_path }

      it "executes end to end over the real MCP path and returns the threaded ids" do
        call_tool("system_expose_service_publicly", valid_arguments, headers: headers_for(manager))

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body["result"]).not_to have_key("isError")

        payload = tool_payload(body)
        expect(payload["success"]).to be true
        expect(payload.dig("data", "vip_id")).to eq(vip_id)
        expect(payload.dig("data", "port_mapping_id")).to eq(port_mapping_id)
        expect(payload.dig("data", "certificate_id")).to eq(certificate_id)
        expect(payload.dig("data", "public_endpoints")).to eq([ "https://app.example.com" ])
        expect(payload.dig("data", "steps_completed")).to eq(
          %w[create_virtual_ip create_port_mapping provision_certificate reverse_proxy_regen]
        )
      end
    end

    describe "permission denial" do
      it "returns a JSON-RPC error when the caller lacks the system.ingress.read floor entirely" do
        stub_sdwan_and_subexecutors_happy_path
        no_perms_user = user_without_permissions(account: account)

        call_tool("system_expose_service_publicly", valid_arguments, headers: headers_for(no_perms_user))

        expect(response).to have_http_status(:ok) # JSON-RPC transport succeeds; error is in the envelope
        body = json_response
        expect(body["error"]["code"]).to eq(-32001)
        expect(body["error"]["message"]).to match(/system\.ingress\.read/)
      end

      it "returns success: false naming system.ingress.manage when the caller has only the read floor" do
        stub_sdwan_and_subexecutors_happy_path
        read_only_user = user_with_permissions("system.ingress.read", account: account)

        call_tool("system_expose_service_publicly", valid_arguments, headers: headers_for(read_only_user))

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body.dig("result", "isError")).to be true
        payload = tool_payload(body)
        expect(payload["success"]).to be false
        expect(payload["error"]).to match(/permission denied: system\.ingress\.manage/)
      end
    end

    describe "malformed input" do
      it "rejects a request missing the required service_hostname" do
        stub_sdwan_and_subexecutors_happy_path
        call_tool("system_expose_service_publicly", valid_arguments.except("service_hostname"),
                  headers: headers_for(manager))

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body.dig("result", "isError")).to be true
        payload = tool_payload(body)
        expect(payload["success"]).to be false
        expect(payload["error"]).to match(/missing required input: service_hostname/)
      end

      it "rejects an unsupported service_protocol" do
        call_tool("system_expose_service_publicly", valid_arguments.merge("service_protocol" => "ftp"),
                  headers: headers_for(manager))

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body.dig("result", "isError")).to be true
        payload = tool_payload(body)
        expect(payload["success"]).to be false
        expect(payload["error"]).to match(/service_protocol must be/)
      end
    end
  end

  # ==========================================================================
  # expose_service_local
  # ==========================================================================
  describe "system_expose_service_local" do
    let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }
    let!(:cert) do
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                               common_name: "apps.example.test")
    end

    before do
      allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
        .and_return(output_path: "/tmp/local-services.yaml", route_count: 1)
    end

    describe "happy path" do
      it "creates and exposes a new local service over the real MCP path" do
        call_tool("system_expose_service_local", {
          "slug" => "grafana", "name" => "Grafana", "protocol" => "https",
          "backend_host" => "10.20.0.5", "backend_port" => 3000, "auth_mode" => "authenticated"
        }, headers: headers_for(manager))

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body["result"]).not_to have_key("isError")

        payload = tool_payload(body)
        expect(payload["success"]).to be true
        expect(payload.dig("data", "created")).to be true
        expect(payload.dig("data", "slug")).to eq("grafana")
        expect(payload.dig("data", "local_url")).to eq("https://apps.example.test/svc/grafana")

        svc = ::Sdwan::Service.find_by(account_id: account.id, slug: "grafana")
        expect(svc.local_enabled).to be true
      end
    end

    describe "permission denial" do
      it "returns success: false naming system.ingress.manage when the caller has only the read floor" do
        read_only_user = user_with_permissions("system.ingress.read", account: account)

        call_tool("system_expose_service_local", {
          "slug" => "grafana", "name" => "Grafana", "backend_host" => "10.20.0.5", "backend_port" => 3000
        }, headers: headers_for(read_only_user))

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body.dig("result", "isError")).to be true
        payload = tool_payload(body)
        expect(payload["success"]).to be false
        expect(payload["error"]).to match(/permission denied: system\.ingress\.manage/)
      end
    end

    describe "malformed input" do
      it "rejects creation missing slug, name, and backend_port" do
        call_tool("system_expose_service_local", { "slug" => "grafana" }, headers: headers_for(manager))

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body.dig("result", "isError")).to be true
        payload = tool_payload(body)
        expect(payload["success"]).to be false
        expect(payload["error"]).to match(/requires slug, name, and backend_port/)
      end
    end
  end

  # ==========================================================================
  # system_expose_service_public_tcp / system_unexpose_service_public_tcp
  # (Path B, campaign 019f3458 increment 10 prerequisite — improvement
  # 019f34f9). Both actions route to the SAME executor,
  # ExposeServicePublicTcpExecutor, which is the sole owner of
  # Sdwan::Service#public_enabled in both directions (system_update_service's
  # inline CRUD refuses to touch it — see its own "does NOT flip
  # public_enabled" spec in spec/services/ai/tools/system_ingress_tool_spec.rb).
  # ==========================================================================
  describe "system_expose_service_public_tcp / system_unexpose_service_public_tcp" do
    let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }
    let!(:cert) do
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                               common_name: "tls.example.test")
    end

    def create_tls_service!(**attrs)
      ::Sdwan::Service.create!({
        account: account, slug: "tls-svc-#{SecureRandom.hex(3)}", name: "TLS Service",
        protocol: "tls", backend_host: "10.30.0.7", backend_port: 5432, local_certificate: cert
      }.merge(attrs))
    end

    before do
      allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
        .and_return(output_path: "/tmp/local-services.yaml", route_count: 1)
    end

    describe "happy path" do
      it "enables public exposure over the real MCP path" do
        svc = create_tls_service!

        call_tool("system_expose_service_public_tcp", { "service_id" => svc.id }, headers: headers_for(manager))

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body["result"]).not_to have_key("isError")

        payload = tool_payload(body)
        expect(payload["success"]).to be true
        expect(payload.dig("data", "public_enabled")).to be true
        expect(svc.reload.public_enabled).to be true
      end

      it "disables public exposure over the real MCP path" do
        svc = create_tls_service!(public_enabled: true)

        call_tool("system_unexpose_service_public_tcp", { "service_id" => svc.id }, headers: headers_for(manager))

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body["result"]).not_to have_key("isError")

        payload = tool_payload(body)
        expect(payload["success"]).to be true
        expect(payload.dig("data", "public_enabled")).to be false
        expect(svc.reload.public_enabled).to be false
      end
    end

    describe "permission denial" do
      it "returns success: false naming system.ingress.manage when the caller has only the read floor" do
        svc = create_tls_service!
        read_only_user = user_with_permissions("system.ingress.read", account: account)

        call_tool("system_expose_service_public_tcp", { "service_id" => svc.id },
                  headers: headers_for(read_only_user))

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body.dig("result", "isError")).to be true
        payload = tool_payload(body)
        expect(payload["success"]).to be false
        expect(payload["error"]).to match(/permission denied: system\.ingress\.manage/)
        expect(svc.reload.public_enabled).to be false
      end
    end

    describe "malformed input" do
      it "rejects a non-tls protocol with a clear message" do
        svc = create_tls_service!(protocol: "https", backend_vip_id: nil, backend_host: "10.0.0.1")

        call_tool("system_expose_service_public_tcp", { "service_id" => svc.id }, headers: headers_for(manager))

        body = json_response
        expect(body.dig("result", "isError")).to be true
        payload = tool_payload(body)
        expect(payload["success"]).to be false
        expect(payload["error"]).to match(/requires the tls protocol/)
      end
    end

    # Approval gating. This block used to PIN THE DEFECT (019f34a3): both
    # examples asserted the action ran immediately with no ApprovalRequest,
    # because `requires_approval: true` on the descriptor was read by nobody.
    # APO-1c (IMP-7e2bdc1774e4) made the flag real, so they are inverted here —
    # the same two calls, asserting the gate now fires and the mutation does
    # NOT land while the approval is parked.
    describe "approval gating" do
      before { require_approval_for!(System::Ai::Skills::ExposeServicePublicTcpExecutor) }

      it "parks an approval for system_expose_service_public_tcp instead of exposing" do
        expect(System::Ai::Skills::ExposeServicePublicTcpExecutor.descriptor[:requires_approval]).to be true
        svc = create_tls_service!

        expect do
          call_tool("system_expose_service_public_tcp", { "service_id" => svc.id }, headers: headers_for(manager))
        end.to change { ::Ai::ApprovalRequest.count }.by(1)

        payload = tool_payload(json_response)
        expect(payload["success"]).to be false
        expect(payload["error"]).to match(/approval required/i)
        # The ROW, not the status: a gate that answers 202 while the write
        # lands is the failure mode this asserts against.
        expect(svc.reload.public_enabled).to be false
      end

      it "parks an approval for system_unexpose_service_public_tcp instead of unexposing" do
        svc = create_tls_service!(public_enabled: true)

        expect do
          call_tool("system_unexpose_service_public_tcp", { "service_id" => svc.id }, headers: headers_for(manager))
        end.to change { ::Ai::ApprovalRequest.count }.by(1)

        expect(tool_payload(json_response)["success"]).to be false
        expect(svc.reload.public_enabled).to be true
      end
    end
  end

  # ==========================================================================
  # Approval gating — the SAME two calls this block used to pin as ungated.
  #
  # Both executors declare `requires_approval: true`
  # (expose_service_publicly_executor.rb:41, expose_service_local_executor.rb:41),
  # and every operator-facing runbook (docs/runbooks/expose-service.md,
  # publish-service.md, traefik-tcp-exposure-vs-dnat.md:62) describes both
  # actions as "approval-gated". Until APO-1c (IMP-7e2bdc1774e4) nothing on this
  # dispatch path consulted the flag — SystemIngressTool#call ->
  # BaseSkillExecutor#execute went straight to #perform — so this block existed
  # to pin the GAP, with a note that a real fix should surface as an intentional
  # spec change. This is that change: BaseSkillExecutor#execute now resolves
  # Ai::InterventionPolicy before #perform, and these examples assert the
  # runbooks' promise instead of contradicting it.
  # ==========================================================================
  describe "approval gating" do
    let(:network)  { create(:sdwan_network, account: account) }
    let(:hub_peer) { create(:sdwan_peer, network: network) }
    let(:backend)  { create(:sdwan_peer, network: network) }

    it "parks an approval for system_expose_service_publicly instead of exposing" do
      expect(System::Ai::Skills::ExposeServicePubliclyExecutor.descriptor[:requires_approval]).to be true
      require_approval_for!(System::Ai::Skills::ExposeServicePubliclyExecutor)

      # Stubbed so a MISSING gate would still succeed loudly rather than fail
      # for an unrelated reason — the assertion below has to be about the gate.
      allow_any_instance_of(::Ai::Tools::SdwanTool).to receive(:execute) do |_tool, params:|
        case params[:action]
        when "system_sdwan_create_virtual_ip"
          { success: true, data: { virtual_ip: { id: SecureRandom.uuid, cidr: params[:cidr] } } }
        else
          { success: true, data: { port_mapping: { id: SecureRandom.uuid } } }
        end
      end
      allow_any_instance_of(System::Ai::Skills::ReverseProxyComposeExecutor)
        .to receive(:execute).and_return({ success: true, data: {} })

      expect do
        call_tool("system_expose_service_publicly", {
          "service_hostname" => "app.example.com", "service_protocol" => "http",
          "sdwan_network_id" => network.id, "sdwan_hub_peer_id" => hub_peer.id,
          "vip_cidr" => "fd00:beef::a/128", "target_peer_id" => backend.id, "backend_port" => 8080
        }, headers: headers_for(manager))
      end.to change { ::Ai::ApprovalRequest.count }.by(1)

      payload = tool_payload(json_response)
      expect(payload["success"]).to be false
      expect(payload["error"]).to match(/approval required/i)
    end

    it "parks an approval for system_expose_service_local instead of exposing" do
      expect(System::Ai::Skills::ExposeServiceLocalExecutor.descriptor[:requires_approval]).to be true
      require_approval_for!(System::Ai::Skills::ExposeServiceLocalExecutor)
      allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
        .and_return(output_path: "/tmp/local-services.yaml", route_count: 1)

      expect do
        call_tool("system_expose_service_local", {
          "slug" => "immediate-svc", "name" => "Immediate", "backend_host" => "10.0.0.9", "backend_port" => 80
        }, headers: headers_for(manager))
      end.to change { ::Ai::ApprovalRequest.count }.by(1)

      expect(tool_payload(json_response)["success"]).to be false
      # The write is what the gate exists to hold back — assert the ROW.
      expect(::Sdwan::Service.where(account_id: account.id, slug: "immediate-svc")).to be_empty
    end
  end
end
