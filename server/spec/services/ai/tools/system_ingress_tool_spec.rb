# frozen_string_literal: true

require "rails_helper"

# SystemIngressTool MCP surface — ingress / public exposure / ACME provisioning.
# Each action is a thin routing layer over a System extension skill executor,
# so the executors are stubbed here: this spec verifies routing, permission
# gating, and action_definitions registration — not executor internals.
RSpec.describe Ai::Tools::SystemIngressTool do
  # PermissionTestHelpers is auto-included only for request/controller/model
  # specs; this is a plain service spec, so include it explicitly.
  include PermissionTestHelpers

  # Real users via the canonical helper (per CLAUDE.md — never hand-build a User
  # double; action_permitted? calls user.respond_to?(:has_permission?) +
  # has_permission?, which only behave correctly on a real User).
  let(:permissive_user) { user_with_permissions("system.ingress.read", "system.ingress.manage", "system.acme.manage") }
  let(:account)         { permissive_user.account }

  # Stub the three executors the tool routes to. They are constructed by the
  # tool via `.new(account:, agent:, user:).execute(**inputs)`.
  let(:reverse_proxy_executor) { instance_double("System::Ai::Skills::ReverseProxyComposeExecutor") }
  let(:expose_executor)        { instance_double("System::Ai::Skills::ExposeServicePubliclyExecutor") }
  let(:acme_executor)          { instance_double("System::Ai::Skills::AcmeCertificateProvisionExecutor") }

  let(:tool) { described_class.new(account: account, user: permissive_user) }

  def stub_executor(const_name, double_obj, result)
    # Capture the real descriptor BEFORE stubbing the const — the tool calls
    # klass.descriptor to filter inputs to declared keys (fix #3).
    real_descriptor = const_name.constantize.descriptor
    klass = class_double(const_name).as_stubbed_const
    allow(klass).to receive(:new).and_return(double_obj)
    allow(klass).to receive(:descriptor).and_return(real_descriptor)
    allow(double_obj).to receive(:execute).and_return(result)
    klass
  end

  describe ".action_definitions" do
    it "registers every ingress / exposure / ACME / service action" do
      keys = described_class.action_definitions.keys
      expect(keys).to contain_exactly(
        "system_reverse_proxy_compose",
        "system_expose_service_publicly",
        "system_expose_service_local",
        "system_acme_provision_certificate",
        "system_create_service",
        "system_list_services",
        "system_get_service",
        "system_update_service",
        "system_delete_service",
        "system_unexpose_service_local",
        "system_expose_service_public_tcp",
        "system_unexpose_service_public_tcp",
        "system_set_service_backends"
      )
    end

    it "every action definition carries a description + parameters" do
      described_class.action_definitions.each_value do |defn|
        expect(defn[:description]).to be_present
        expect(defn[:parameters]).to be_a(Hash)
      end
    end

    it "declares parameters that match each executor's required inputs" do
      defs = described_class.action_definitions
      expect(defs["system_reverse_proxy_compose"][:parameters].keys).to include(:certificate_id)
      expect(defs["system_expose_service_publicly"][:parameters].keys)
        .to include(:service_hostname, :service_protocol, :sdwan_network_id, :sdwan_hub_peer_id, :vip_cidr, :backend_port)
      expect(defs["system_expose_service_publicly"][:parameters][:vip_cidr][:required]).to be true
      expect(defs["system_acme_provision_certificate"][:parameters].keys)
        .to include(:common_name, :issuer, :challenge_type)
    end
  end

  describe "action routing" do
    it "routes system_reverse_proxy_compose to ReverseProxyComposeExecutor" do
      klass = stub_executor("System::Ai::Skills::ReverseProxyComposeExecutor",
                            reverse_proxy_executor, { success: true, data: { composed: true } })

      result = tool.execute(params: {
        action: "system_reverse_proxy_compose",
        certificate_id: "cert-1"
      })

      expect(klass).to have_received(:new).with(account: account, agent: nil, user: permissive_user)
      expect(reverse_proxy_executor).to have_received(:execute).with(certificate_id: "cert-1")
      expect(result).to eq(success: true, data: { composed: true })
    end

    it "routes system_expose_service_publicly to ExposeServicePubliclyExecutor" do
      stub_executor("System::Ai::Skills::ExposeServicePubliclyExecutor",
                    expose_executor, { success: true, data: { exposed: true } })

      result = tool.execute(params: {
        action: "system_expose_service_publicly",
        service_hostname: "app.example.com",
        service_protocol: "https",
        sdwan_network_id: "net-1",
        sdwan_hub_peer_id: "peer-1",
        vip_cidr: "fd00:beef::a/128",
        backend_port: 8080
      })

      expect(expose_executor).to have_received(:execute).with(
        service_hostname: "app.example.com", service_protocol: "https",
        sdwan_network_id: "net-1", sdwan_hub_peer_id: "peer-1",
        vip_cidr: "fd00:beef::a/128", backend_port: 8080
      )
      expect(result[:success]).to be true
    end

    it "routes system_expose_service_local to ExposeServiceLocalExecutor" do
      local_executor = instance_double("System::Ai::Skills::ExposeServiceLocalExecutor")
      stub_executor("System::Ai::Skills::ExposeServiceLocalExecutor",
                    local_executor, { success: true, data: { local_path: "/svc/grafana" } })

      result = tool.execute(params: {
        action: "system_expose_service_local",
        service_id: "svc-1", auth_mode: "authenticated"
      })

      expect(local_executor).to have_received(:execute).with(service_id: "svc-1", auth_mode: "authenticated")
      expect(result.dig(:data, :local_path)).to eq("/svc/grafana")
    end

    it "routes system_expose_service_public_tcp to ExposeServicePublicTcpExecutor, forcing enabled: true" do
      public_tcp_executor = instance_double("System::Ai::Skills::ExposeServicePublicTcpExecutor")
      stub_executor("System::Ai::Skills::ExposeServicePublicTcpExecutor",
                    public_tcp_executor, { success: true, data: { public_enabled: true } })

      result = tool.execute(params: { action: "system_expose_service_public_tcp", service_id: "svc-1" })

      expect(public_tcp_executor).to have_received(:execute).with(service_id: "svc-1", enabled: true)
      expect(result.dig(:data, :public_enabled)).to be true
    end

    it "routes system_unexpose_service_public_tcp to ExposeServicePublicTcpExecutor, forcing enabled: false" do
      public_tcp_executor = instance_double("System::Ai::Skills::ExposeServicePublicTcpExecutor")
      stub_executor("System::Ai::Skills::ExposeServicePublicTcpExecutor",
                    public_tcp_executor, { success: true, data: { public_enabled: false } })

      result = tool.execute(params: { action: "system_unexpose_service_public_tcp", service_id: "svc-1" })

      expect(public_tcp_executor).to have_received(:execute).with(service_id: "svc-1", enabled: false)
      expect(result.dig(:data, :public_enabled)).to be false
    end

    it "ignores undeclared extra params instead of raising ArgumentError (fix #3)" do
      stub_executor("System::Ai::Skills::ReverseProxyComposeExecutor",
                    reverse_proxy_executor, { success: true, data: { composed: true } })

      result = tool.execute(params: {
        action: "system_reverse_proxy_compose",
        certificate_id: "cert-1",
        bogus_extra_param: "should-be-dropped"
      })

      # The executor only declares :certificate_id — the extra param must be
      # filtered out before splatting so perform's strict kwargs don't raise.
      expect(reverse_proxy_executor).to have_received(:execute).with(certificate_id: "cert-1")
      expect(result).to eq(success: true, data: { composed: true })
    end

    it "routes system_acme_provision_certificate to AcmeCertificateProvisionExecutor" do
      stub_executor("System::Ai::Skills::AcmeCertificateProvisionExecutor",
                    acme_executor, { success: true, data: { certificate_id: "cert-1" } })

      result = tool.execute(params: {
        action: "system_acme_provision_certificate",
        common_name: "app.example.com",
        issuer: "letsencrypt-prod",
        challenge_type: "dns-01"
      })

      expect(acme_executor).to have_received(:execute).with(
        common_name: "app.example.com", issuer: "letsencrypt-prod", challenge_type: "dns-01"
      )
      expect(result.dig(:data, :certificate_id)).to eq("cert-1")
    end

    it "returns an error for an unknown action" do
      result = tool.execute(params: { action: "system_bogus_action" })
      expect(result[:success]).to be false
      expect(result[:error]).to match(/Unknown action/)
    end
  end

  describe "Sdwan::Service inline CRUD" do
    # The mutators call Sdwan::ServiceExposureWriter.write! for locally-exposed
    # services — stub it so the spec never touches the filesystem.
    before do
      allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
        .and_return(output_path: "/tmp/local-services.yaml", route_count: 0)
    end

    def create_service!(**attrs)
      ::Sdwan::Service.create!({
        account: account, slug: "svc-#{SecureRandom.hex(3)}", name: "Svc",
        protocol: "https", backend_host: "10.0.0.5", backend_port: 3000
      }.merge(attrs))
    end

    it "creates a service (not exposed) via system_create_service" do
      result = tool.execute(params: {
        action: "system_create_service", slug: "grafana", name: "Grafana",
        protocol: "http", backend_host: "10.0.0.9", backend_port: 3000
      })
      expect(result[:success]).to be true
      svc = result.dig(:data, :service)
      expect(svc[:slug]).to eq("grafana")
      expect(svc[:local_enabled]).to be false
      expect(svc[:local_path]).to eq("/svc/grafana")
      expect(::Sdwan::Service.find_by(id: svc[:id], account_id: account.id)).to be_present
    end

    it "surfaces a model validation error (reserved slug) as a failure" do
      result = tool.execute(params: {
        action: "system_create_service", slug: "api", name: "X", backend_host: "h", backend_port: 80
      })
      expect(result[:success]).to be false
      expect(result[:error]).to match(/reserved/i)
    end

    it "lists and filters services" do
      create_service!(slug: "active-one", status: "active")
      create_service!(slug: "disabled-one", status: "disabled")
      all = tool.execute(params: { action: "system_list_services" })
      expect(all.dig(:data, :count)).to eq(2)
      only_active = tool.execute(params: { action: "system_list_services", status: "active" })
      expect(only_active.dig(:data, :count)).to eq(1)
    end

    it "gets a single service scoped to the account" do
      svc = create_service!(slug: "lookup")
      result = tool.execute(params: { action: "system_get_service", service_id: svc.id })
      expect(result.dig(:data, :service, :slug)).to eq("lookup")
    end

    it "updates backend plumbing and regenerates when locally exposed" do
      svc = create_service!(slug: "upd", local_enabled: true)
      result = tool.execute(params: {
        action: "system_update_service", service_id: svc.id, name: "Renamed", backend_port: 9999
      })
      expect(result[:success]).to be true
      expect(svc.reload.name).to eq("Renamed")
      expect(svc.backend_port).to eq(9999)
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    it "does NOT flip local_enabled through update_service (exposure is executor-owned)" do
      svc = create_service!(slug: "noflip", local_enabled: false)
      tool.execute(params: { action: "system_update_service", service_id: svc.id, local_enabled: true })
      expect(svc.reload.local_enabled).to be false
    end

    # Path B (public_enabled) — campaign 019f3458 increments 5 + 10-prereq.
    # edge_mode/client_auth are inert TLS-transport plumbing (identity +
    # backend, same risk class as protocol/backend_port) and are wired through
    # inline CRUD like everything else in this section. public_enabled is the
    # actual exposure-semantics toggle (same risk class as local_enabled,
    # arguably higher — public internet, not just this account's
    # ForwardAuth-gated users) and is deliberately NOT wired here in EITHER
    # direction — it is owned end to end by ExposeServicePublicTcpExecutor
    # (system_expose_service_public_tcp / system_unexpose_service_public_tcp),
    # not this inline CRUD surface. See that executor's spec + the request
    # spec's "system_expose_service_public_tcp / system_unexpose_service_public_tcp"
    # block for its coverage.
    it "creates a service with edge_mode/client_auth (inert plumbing, not exposure)" do
      result = tool.execute(params: {
        action: "system_create_service", slug: "tls-svc", name: "TLS Svc", protocol: "tls",
        backend_host: "10.0.0.9", backend_port: 5432, edge_mode: "terminate", client_auth: "required"
      })
      expect(result[:success]).to be true
      svc = ::Sdwan::Service.find(result.dig(:data, :service, :id))
      expect(svc.edge_mode).to eq("terminate")
      expect(svc.client_auth).to eq("required")
      expect(svc.public_enabled).to be false
    end

    it "updates edge_mode/client_auth via system_update_service" do
      svc = create_service!(slug: "tls-upd", protocol: "tls", edge_mode: "passthrough", client_auth: "none")
      result = tool.execute(params: {
        action: "system_update_service", service_id: svc.id, edge_mode: "terminate", client_auth: "required"
      })
      expect(result[:success]).to be true
      expect(svc.reload.edge_mode).to eq("terminate")
      expect(svc.client_auth).to eq("required")
    end

    it "does NOT flip public_enabled through update_service (no owning executor yet — gap, not a tool)" do
      svc = create_service!(slug: "pub-noflip", protocol: "tls", public_enabled: false)
      tool.execute(params: { action: "system_update_service", service_id: svc.id, public_enabled: true })
      expect(svc.reload.public_enabled).to be false
    end

    it "regenerates the reverse proxy on update when the service is publicly exposed" do
      svc = create_service!(slug: "pub-upd", protocol: "tls", public_enabled: true, edge_mode: "passthrough")
      tool.execute(params: { action: "system_update_service", service_id: svc.id, edge_mode: "terminate" })
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    it "regenerates the reverse proxy on delete when the service was publicly exposed" do
      svc = create_service!(slug: "pub-del", protocol: "tls", public_enabled: true)
      tool.execute(params: { action: "system_delete_service", service_id: svc.id })
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    it "filters list_services by public_enabled and surfaces the new fields on read" do
      create_service!(slug: "pub-one", protocol: "tls", public_enabled: true, edge_mode: "terminate", client_auth: "required")
      create_service!(slug: "local-one", local_enabled: true)

      only_public = tool.execute(params: { action: "system_list_services", public_enabled: true })
      expect(only_public.dig(:data, :count)).to eq(1)

      svc_data = only_public.dig(:data, :services, 0)
      expect(svc_data[:public_enabled]).to be true
      expect(svc_data[:edge_mode]).to eq("terminate")
      expect(svc_data[:client_auth]).to eq("required")
    end

    it "unexposes a service (fail-safe off) and regenerates" do
      svc = create_service!(slug: "off", local_enabled: true)
      result = tool.execute(params: { action: "system_unexpose_service_local", service_id: svc.id })
      expect(result.dig(:data, :local_exposure)).to eq("disabled")
      expect(svc.reload.local_enabled).to be false
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    it "deletes a service and regenerates only if it was exposed" do
      exposed = create_service!(slug: "del-exposed", local_enabled: true)
      tool.execute(params: { action: "system_delete_service", service_id: exposed.id })
      expect(::Sdwan::Service.find_by(id: exposed.id)).to be_nil
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    # Bug: the DB flip (unexpose/delete/update) already committed by the time
    # regen_local_services! runs, but ServiceExposureWriter::WriteError (e.g.
    # an unwritable dynamic-config dir) wasn't rescued here — only
    # RecordNotFound/RecordInvalid were — so it escaped `call` as a raw
    # exception instead of a clean error_result, and the stale on-disk YAML
    # kept routing the just-disabled/deleted service.
    describe "a reverse-proxy regen failure after the DB flip already committed" do
      before do
        allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
          .and_raise(::Sdwan::ServiceExposureWriter::WriteError, "dynamic dir unwritable")
      end

      it "does not escape uncaught from system_unexpose_service_local" do
        svc = create_service!(slug: "off-werr", local_enabled: true)

        result = nil
        expect { result = tool.execute(params: { action: "system_unexpose_service_local", service_id: svc.id }) }
          .not_to raise_error
        expect(result[:success]).to be false
        expect(result[:error]).to match(/regen failed/i)
        expect(svc.reload.local_enabled).to be false
      end

      it "does not escape uncaught from system_delete_service" do
        svc = create_service!(slug: "del-werr", local_enabled: true)

        result = nil
        expect { result = tool.execute(params: { action: "system_delete_service", service_id: svc.id }) }
          .not_to raise_error
        expect(result[:success]).to be false
        expect(result[:error]).to match(/regen failed/i)
        expect(::Sdwan::Service.find_by(id: svc.id)).to be_nil
      end

      it "does not escape uncaught from system_update_service" do
        svc = create_service!(slug: "upd-werr", local_enabled: true)

        result = nil
        expect {
          result = tool.execute(params: { action: "system_update_service", service_id: svc.id, name: "Renamed" })
        }.not_to raise_error
        expect(result[:success]).to be false
        expect(result[:error]).to match(/regen failed/i)
        expect(svc.reload.name).to eq("Renamed")
      end
    end
  end

  describe "permission gating" do
    # A real user lacking the *.manage permissions (has only the read floor).
    let(:restricted_user) { user_with_permissions("system.ingress.read") }
    let(:restricted_tool) { described_class.new(account: restricted_user.account, user: restricted_user) }

    it "denies a user without system.ingress.manage on reverse_proxy_compose" do
      result = restricted_tool.execute(params: {
        action: "system_reverse_proxy_compose", certificate_id: "cert-1"
      })
      expect(result[:success]).to be false
      expect(result[:error]).to match(/permission denied: system\.ingress\.manage/)
    end

    it "denies a user without system.acme.manage on acme_provision_certificate" do
      result = restricted_tool.execute(params: {
        action: "system_acme_provision_certificate",
        common_name: "x.example.com", issuer: "letsencrypt-prod", challenge_type: "dns-01"
      })
      expect(result[:success]).to be false
      expect(result[:error]).to match(/permission denied: system\.acme\.manage/)
    end

    it "checks the per-action permission before dispatching" do
      expect(restricted_user).to receive(:has_permission?).with("system.ingress.manage").and_return(false)
      restricted_tool.execute(params: {
        action: "system_expose_service_publicly",
        service_hostname: "h.example.com", service_protocol: "https",
        sdwan_network_id: "net-1", sdwan_hub_peer_id: "peer-1", backend_port: 1
      })
    end
  end

  # IMP-54bf2643f542 — action_permitted? used to read `@user.nil?` as
  # "internal/system caller" and return true. That premise (MCP callers always
  # carry a user) predates instance principals: an mTLS node cert authenticates
  # with NO user, so every per-action permission here was skipped and the
  # peer's per-tool grant glob was the only remaining control. Sibling of the
  # SystemFleetTool fix (IMP-9030413bc292): the bypass is now two EXPLICIT
  # signals and a bare userless call fails closed.
  describe "principal authorization (IMP-54bf2643f542)" do
    let(:gated_action) { "system_expose_service_publicly" }

    it "denies a bare userless call — no user, no internal flag, no instance grant" do
      bare = described_class.new(account: account, user: nil)

      expect(bare.send(:action_permitted?, gated_action)).to be false
    end

    # The routed executor must never be constructed: the gate has to fail
    # closed BEFORE dispatch, not inside the executor.
    it "surfaces the denial as an error_result rather than routing to the executor" do
      klass = stub_executor("System::Ai::Skills::ExposeServicePubliclyExecutor",
                            expose_executor, { success: true, data: {} })
      bare = described_class.new(account: account, user: nil)

      result = bare.execute(params: { action: gated_action, service_id: "svc-1" })

      expect(klass).not_to have_received(:new)
      expect(result[:success]).to be false
      expect(result[:error]).to include("permission denied")
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
      reader = user_with_permissions("system.ingress.read", account: account)
      user_tool = described_class.new(account: account, user: reader)

      expect(user_tool.send(:action_permitted?, "system_list_services")).to be true
      expect(user_tool.send(:action_permitted?, gated_action)).to be false
    end
  end
end
