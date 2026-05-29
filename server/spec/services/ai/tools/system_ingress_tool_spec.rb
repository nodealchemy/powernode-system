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
  let(:permissive_user) { user_with_permissions("system.ingress.manage", "system.acme.manage") }
  let(:account)         { permissive_user.account }

  # Stub the three executors the tool routes to. They are constructed by the
  # tool via `.new(account:, agent:, user:).execute(**inputs)`.
  let(:reverse_proxy_executor) { instance_double("System::Ai::Skills::ReverseProxyComposeExecutor") }
  let(:expose_executor)        { instance_double("System::Ai::Skills::ExposeServicePubliclyExecutor") }
  let(:acme_executor)          { instance_double("System::Ai::Skills::AcmeCertificateProvisionExecutor") }

  let(:tool) { described_class.new(account: account, user: permissive_user) }

  def stub_executor(const_name, double_obj, result)
    klass = class_double(const_name).as_stubbed_const
    allow(klass).to receive(:new).and_return(double_obj)
    allow(double_obj).to receive(:execute).and_return(result)
    klass
  end

  describe ".action_definitions" do
    it "registers all three ingress/acme actions" do
      keys = described_class.action_definitions.keys
      expect(keys).to contain_exactly(
        "system_reverse_proxy_compose",
        "system_expose_service_publicly",
        "system_acme_provision_certificate"
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
        .to include(:service_hostname, :service_protocol, :sdwan_network_id, :sdwan_hub_peer_id, :backend_port)
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
        backend_port: 8080
      })

      expect(expose_executor).to have_received(:execute).with(
        service_hostname: "app.example.com", service_protocol: "https",
        sdwan_network_id: "net-1", sdwan_hub_peer_id: "peer-1", backend_port: 8080
      )
      expect(result[:success]).to be true
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
end
