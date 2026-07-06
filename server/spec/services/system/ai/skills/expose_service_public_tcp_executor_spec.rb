# frozen_string_literal: true

require "rails_helper"

# Path-B-owning executor (campaign 019f3458 increment 10 prerequisite,
# improvement 019f34f9): the SOLE owner of Sdwan::Service#public_enabled in
# BOTH directions. SystemIngressTool's inline `system_update_service` CRUD
# refuses to touch public_enabled (regression-pinned by its "does NOT flip
# public_enabled through update_service" spec) — this executor is the only
# way to flip it, either direction. The ServiceExposureWriter is stubbed at
# its boundary so this spec asserts orchestration + validation, not YAML
# rendering (covered by service_exposure_writer_spec).
RSpec.describe System::Ai::Skills::ExposeServicePublicTcpExecutor do
  let(:account)  { create(:account) }
  let(:exec)     { described_class.new(account: account) }
  let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }
  let!(:cert) do
    create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                             common_name: "tls.example.test")
  end

  def create_service!(**attrs)
    ::Sdwan::Service.create!({
      account: account, slug: "tls-svc-#{SecureRandom.hex(3)}", name: "TLS Service",
      protocol: "tls", backend_host: "10.30.0.7", backend_port: 5432,
      local_certificate: cert
    }.merge(attrs))
  end

  before do
    allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
      .and_return(output_path: "/tmp/local-services.yaml", route_count: 1)
  end

  describe ".descriptor" do
    it "advertises inputs, outputs, and approval gating" do
      d = described_class.descriptor
      expect(d[:name]).to eq("expose_service_public_tcp")
      expect(d[:category]).to eq("devops")
      expect(d[:requires_approval]).to be true
      expect(d[:inputs].keys).to contain_exactly(:service_id, :enabled)
      expect(d[:inputs][:service_id][:required]).to be true
      expect(d[:outputs].keys).to include(:service_id, :slug, :public_enabled, :edge_mode,
                                          :client_auth, :host, :routes_configured)
    end
  end

  describe "#execute — EXPOSE (enabled: true, default)" do
    it "enables public_enabled and regenerates the reverse proxy" do
      svc = create_service!
      r = exec.execute(service_id: svc.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :public_enabled)).to be true
      expect(r.dig(:data, :slug)).to eq(svc.slug)
      expect(r.dig(:data, :host)).to eq("tls.example.test")
      expect(r.dig(:data, :routes_configured)).to eq(1)
      expect(svc.reload.public_enabled).to be true
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    it "defaults enabled to true when omitted" do
      svc = create_service!
      exec.execute(service_id: svc.id)
      expect(svc.reload.public_enabled).to be true
    end

    it "rejects a non-tls protocol with a clear message" do
      svc = create_service!(protocol: "https", backend_vip_id: nil, backend_host: "10.0.0.1")
      r = exec.execute(service_id: svc.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/requires the tls protocol/)
      expect(svc.reload.public_enabled).to be false
    end

    it "rejects when no host is resolvable (no explicit cert, no account-wide valid cert)" do
      svc = create_service!(local_certificate: nil)
      ::System::AcmeCertificate.where(account_id: account.id).update_all(status: "revoked")

      r = exec.execute(service_id: svc.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/no resolvable host/)
      expect(svc.reload.public_enabled).to be false
    end

    it "rejects edge_mode terminate with no matching valid certificate for the resolved host" do
      # local_certificate resolves the host to "tls.example.test", but that
      # cert's own account-wide "valid" copy has been revoked — no valid
      # AcmeCertificate anywhere has that common_name.
      svc = create_service!(edge_mode: "terminate")
      cert.update!(status: "revoked")

      r = exec.execute(service_id: svc.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/edge_mode terminate requires a valid System::AcmeCertificate/)
      expect(svc.reload.public_enabled).to be false
    end

    it "accepts edge_mode terminate when a valid certificate matches the resolved host" do
      svc = create_service!(edge_mode: "terminate")
      r = exec.execute(service_id: svc.id)

      expect(r[:success]).to be true
      expect(svc.reload.public_enabled).to be true
      expect(svc.edge_mode).to eq("terminate")
    end

    it "fails clearly when the service_id is unknown" do
      r = exec.execute(service_id: SecureRandom.uuid)
      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found/)
    end

    it "denies a service_id that belongs to another account (cross-account denial)" do
      other_account = create(:account)
      foreign_svc = create_service!(account: other_account, local_certificate: nil)

      r = exec.execute(service_id: foreign_svc.id)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found/)
      expect(foreign_svc.reload.public_enabled).to be false
    end
  end

  describe "#execute — UNEXPOSE (enabled: false)" do
    it "disables public_enabled and regenerates the reverse proxy, with no protocol/host preconditions" do
      svc = create_service!(public_enabled: true)
      r = exec.execute(service_id: svc.id, enabled: false)

      expect(r[:success]).to be true
      expect(r.dig(:data, :public_enabled)).to be false
      expect(svc.reload.public_enabled).to be false
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    it "unexposes even a service with no resolvable host (fail-safe off has no preconditions)" do
      svc = create_service!(public_enabled: true, local_certificate: nil)
      ::System::AcmeCertificate.where(account_id: account.id).update_all(status: "revoked")

      r = exec.execute(service_id: svc.id, enabled: false)

      expect(r[:success]).to be true
      expect(svc.reload.public_enabled).to be false
    end

    it "denies a service_id that belongs to another account (cross-account denial)" do
      other_account = create(:account)
      foreign_svc = create_service!(account: other_account, public_enabled: true, local_certificate: nil)

      r = exec.execute(service_id: foreign_svc.id, enabled: false)

      expect(r[:success]).to be false
      expect(r[:error]).to match(/not found/)
      expect(foreign_svc.reload.public_enabled).to be true
    end
  end
end
