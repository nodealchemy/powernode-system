# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::AcmeCertificates", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.acme.read", account: account) }
  let(:issuer)  { user_with_permissions("system.acme.read", "system.acme.issue", account: account) }
  let(:revoker) { user_with_permissions("system.acme.read", "system.acme.revoke", account: account) }
  let(:base)    { "/api/v1/system/acme_certificates" }

  let(:dns_cred) do
    create(:system_acme_dns_credential, account: account, name: "cf", provider: "cloudflare",
                                        status: "valid")
  end

  describe "GET /acme_certificates" do
    let!(:my_cert) do
      create(:system_acme_certificate, account: account, common_name: "a.example.com",
                                       dns_credential: dns_cred, status: "valid",
                                       issued_at: 1.day.ago, expires_at: 89.days.from_now)
    end
    let!(:other_cert) do
      create(:system_acme_certificate, account: create(:account),
                                       common_name: "leak.example.com", status: "valid",
                                       expires_at: 1.day.from_now)
    end

    it "lists this account's certs only + surfaces days_until_expiry" do
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      names = data["certificates"].map { |c| c["common_name"] }
      expect(names).to eq([ "a.example.com" ])
      expect(names).not_to include("leak.example.com")

      cert = data["certificates"].first
      expect(cert["days_until_expiry"]).to be_within(1).of(89)
      expect(cert["vault_paths_present"]).to be false
    end

    it "filters by status" do
      create(:system_acme_certificate, account: account, common_name: "b.example.com",
                                       dns_credential: dns_cred, status: "pending")
      get base, headers: auth_headers_for(reader), params: { status: "pending" }
      data = JSON.parse(response.body)["data"]
      expect(data["certificates"].map { |c| c["status"] }).to eq([ "pending" ])
    end

    it "forbids without read permission" do
      anon = create(:user, account: account)
      get base, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /acme_certificates" do
    let(:valid_body) do
      {
        common_name: "dev.example.com",
        dns_credential_id: dns_cred.id,
        issuer: "letsencrypt-staging",
        acme_email: "ops@example.com",
        sans: [ "alias.example.com" ]
      }
    end

    it "creates a pending cert + persists acme_email into metadata" do
      expect {
        post base, params: valid_body.to_json,
                    headers: auth_headers_for(issuer).merge("Content-Type" => "application/json")
      }.to change { ::System::AcmeCertificate.count }.by(1)

      expect(response).to have_http_status(:created)
      cert = ::System::AcmeCertificate.order(:created_at).last
      expect(cert.status).to eq("pending")
      expect(cert.issuer).to eq("letsencrypt-staging")
      expect(cert.sans).to eq([ "alias.example.com" ])
      expect(cert.metadata["acme_email"]).to eq("ops@example.com")
    end

    it "rejects unsupported issuers" do
      post base, params: valid_body.merge(issuer: "selfsigned").to_json,
                  headers: auth_headers_for(issuer).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Unsupported issuer")
    end

    it "rejects when dns_credential belongs to another account" do
      other_dns = create(:system_acme_dns_credential, account: create(:account),
                                                       name: "x", provider: "cloudflare")
      post base, params: valid_body.merge(dns_credential_id: other_dns.id).to_json,
                  headers: auth_headers_for(issuer).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "forbids without issue permission" do
      post base, params: valid_body.to_json,
                  headers: auth_headers_for(reader).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /acme_certificates/:id/request_issue" do
    let!(:cert) do
      create(:system_acme_certificate, account: account, common_name: "dev.example.com",
                                       dns_credential: dns_cred, status: "pending")
    end

    context "happy path" do
      before do
        allow(::Acme::CertificateManager).to receive(:issue!) do |args|
          # Simulate cert state machine landing in `valid` after a successful issuance
          c = args[:certificate]
          c.update_columns(status: "valid", issued_at: Time.current, expires_at: 89.days.from_now)
          ::Acme::CertificateManager::Result.new(ok?: true, certificate: c)
        end
      end

      it "fires the manager + returns the updated cert" do
        post "#{base}/#{cert.id}/request_issue",
             headers: auth_headers_for(issuer).merge("Content-Type" => "application/json")
        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)["data"]
        expect(data["ok"]).to be true
        expect(data["certificate"]["status"]).to eq("valid")
      end
    end

    context "manager failure" do
      before do
        allow(::Acme::CertificateManager).to receive(:issue!) do |args|
          args[:certificate].update_columns(status: "failed",
                                             last_renewal_error: "Cloudflare 403")
          ::Acme::CertificateManager::Result.new(
            ok?: false, certificate: args[:certificate], error: "Cloudflare 403"
          )
        end
      end

      it "surfaces the error + leaves cert in failed state" do
        post "#{base}/#{cert.id}/request_issue",
             headers: auth_headers_for(issuer).merge("Content-Type" => "application/json")
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("Cloudflare 403")
        cert.reload
        expect(cert.status).to eq("failed")
      end
    end

    context "guard clauses" do
      it "rejects from non-pending/failed status" do
        cert.update!(status: "valid", issued_at: 1.day.ago, expires_at: 89.days.from_now)
        post "#{base}/#{cert.id}/request_issue",
             headers: auth_headers_for(issuer).merge("Content-Type" => "application/json")
        expect(response).to have_http_status(:conflict)
      end

      it "forbids without issue permission" do
        post "#{base}/#{cert.id}/request_issue",
             headers: auth_headers_for(reader).merge("Content-Type" => "application/json")
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "POST /acme_certificates/:id/renew" do
    let(:renewer) { user_with_permissions("system.acme.read", "system.acme.renew", account: account) }
    let!(:cert) do
      create(:system_acme_certificate, account: account, common_name: "dev.example.com",
                                       dns_credential: dns_cred, status: "valid",
                                       issued_at: 60.days.ago, expires_at: 30.days.from_now,
                                       vault_path_certificate: "/path/cert.crt")
    end

    context "happy path" do
      before do
        allow(::Acme::CertificateManager).to receive(:renew!) do |args|
          c = args[:certificate]
          c.update_columns(issued_at: Time.current, expires_at: 89.days.from_now)
          ::Acme::CertificateManager::Result.new(ok?: true, certificate: c)
        end
      end

      it "fires CertificateManager.renew! + returns refreshed cert" do
        post "#{base}/#{cert.id}/renew",
             headers: auth_headers_for(renewer).merge("Content-Type" => "application/json")
        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)["data"]
        expect(data["ok"]).to be true
        expect(Time.iso8601(data["certificate"]["expires_at"])).to be > 60.days.from_now
      end
    end

    context "failure path" do
      before do
        allow(::Acme::CertificateManager).to receive(:renew!).and_return(
          ::Acme::CertificateManager::Result.new(ok?: false, certificate: cert, error: "ACME 429 rate-limited")
        )
      end

      it "surfaces 422 with the error" do
        post "#{base}/#{cert.id}/renew",
             headers: auth_headers_for(renewer).merge("Content-Type" => "application/json")
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("ACME 429")
      end
    end

    it "rejects renew from non-valid status (HTTP 409)" do
      cert.update!(status: "pending")
      post "#{base}/#{cert.id}/renew",
           headers: auth_headers_for(renewer).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:conflict)
    end

    it "forbids without renew permission" do
      post "#{base}/#{cert.id}/renew",
           headers: auth_headers_for(reader).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /acme_certificates/:id/revoke" do
    let!(:cert) do
      create(:system_acme_certificate, account: account, common_name: "dev.example.com",
                                       dns_credential: dns_cred, status: "valid",
                                       issued_at: 1.day.ago, expires_at: 89.days.from_now,
                                       vault_path_certificate: "acme-certificates/x/y/cert")
    end

    before do
      allow(::Acme::CertificateManager).to receive(:revoke!) do |args|
        args[:certificate].update_columns(status: "revoked")
        ::Acme::CertificateManager::Result.new(ok?: true, certificate: args[:certificate])
      end
    end

    it "transitions to revoked" do
      post "#{base}/#{cert.id}/revoke",
           params: { reason: "rotation" }.to_json,
           headers: auth_headers_for(revoker).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      cert.reload
      expect(cert.status).to eq("revoked")
    end

    it "refuses to re-revoke a revoked cert" do
      cert.update!(status: "revoked")
      post "#{base}/#{cert.id}/revoke",
           headers: auth_headers_for(revoker).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:conflict)
    end

    it "forbids without revoke permission" do
      post "#{base}/#{cert.id}/revoke",
           headers: auth_headers_for(issuer).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /acme_certificates/:id" do
    it "deletes from terminal status" do
      cert = create(:system_acme_certificate, account: account, common_name: "x", status: "revoked")
      delete "#{base}/#{cert.id}", headers: auth_headers_for(revoker)
      expect(response).to have_http_status(:ok)
      expect(::System::AcmeCertificate.where(id: cert.id)).to be_empty
    end

    it "refuses to delete a non-terminal cert" do
      cert = create(:system_acme_certificate, account: account, common_name: "x", status: "valid",
                                              issued_at: 1.day.ago, expires_at: 89.days.from_now)
      delete "#{base}/#{cert.id}", headers: auth_headers_for(revoker)
      expect(response).to have_http_status(:conflict)
    end
  end
end
