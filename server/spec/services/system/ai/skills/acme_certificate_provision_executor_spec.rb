# frozen_string_literal: true

require "rails_helper"

# Skill: acme_certificate_provision — issues a new ACME TLS certificate.
# ::Acme::CertificateManager.issue! is always stubbed so no ACME / network
# work happens; we assert the row is created, the manager is driven, and the
# return shape + validation guards hold.
RSpec.describe System::Ai::Skills::AcmeCertificateProvisionExecutor do
  let(:account)        { create(:account) }
  let(:dns_credential) { create(:system_acme_dns_credential, :valid, account: account) }
  let(:exec)           { described_class.new(account: account) }

  # A Result-like stub: the manager mutates the row's lifecycle columns on a
  # real issuance; here we stamp the post-issuance attrs and return ok?=true.
  def stub_successful_issue!
    allow(::Acme::CertificateManager).to receive(:issue!) do |certificate:|
      certificate.update_columns(
        status: "valid",
        issued_at: Time.current,
        expires_at: 90.days.from_now,
        vault_path_certificate: "acme-certificates/#{account.id}/#{certificate.id}/cert",
        vault_path_private_key: "acme-certificates/#{account.id}/#{certificate.id}/key",
        vault_path_chain: "acme-certificates/#{account.id}/#{certificate.id}/chain"
      )
      ::Acme::CertificateManager::Result.new(ok?: true, certificate: certificate)
    end
  end

  describe ".descriptor" do
    it "is an approval-gated devops skill with the expected inputs" do
      d = described_class.descriptor
      expect(d[:name]).to eq("acme_certificate_provision")
      expect(d[:category]).to eq("devops")
      expect(d[:requires_approval]).to be true
      expect(d.dig(:inputs, :common_name, :required)).to be true
      expect(d.dig(:inputs, :issuer, :required)).to be true
      expect(d.dig(:inputs, :challenge_type, :required)).to be true
    end
  end

  describe "#execute" do
    context "with a valid dns-01 request" do
      before { stub_successful_issue! }

      it "creates an AcmeCertificate row and drives issuance" do
        expect(::Acme::CertificateManager).to receive(:issue!)
          .with(certificate: instance_of(System::AcmeCertificate)).and_call_original

        expect do
          exec.execute(
            common_name: "ops.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "dns-01",
            dns_credential_id: dns_credential.id
          )
        end.to change(System::AcmeCertificate, :count).by(1)

        cert = System::AcmeCertificate.order(:created_at).last
        expect(cert.account_id).to eq(account.id)
        expect(cert.common_name).to eq("ops.example.com")
        expect(cert.dns_credential_id).to eq(dns_credential.id)
      end

      it "returns the certificate attributes after a successful issue" do
        r = exec.execute(
          common_name: "ops.example.com",
          sans: [ "www.ops.example.com" ],
          issuer: "letsencrypt-prod",
          challenge_type: "dns-01",
          dns_credential_id: dns_credential.id,
          acme_email: "ops@example.com"
        )

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:common_name]).to eq("ops.example.com")
        expect(d[:issuer]).to eq("letsencrypt-prod")
        expect(d[:challenge_type]).to eq("dns-01")
        expect(d[:status]).to eq("valid")
        expect(d[:certificate_id]).to be_present
        expect(d[:issued_at]).to be_present
        expect(d[:expires_at]).to be_present
        expect(d[:vault_path_certificate]).to include("cert")
        expect(d[:vault_path_private_key]).to include("key")
        expect(d[:vault_path_chain]).to include("chain")
      end

      it "persists acme_email into metadata" do
        exec.execute(
          common_name: "ops.example.com",
          issuer: "letsencrypt-prod",
          challenge_type: "dns-01",
          dns_credential_id: dns_credential.id,
          acme_email: "ops@example.com"
        )
        cert = System::AcmeCertificate.order(:created_at).last
        expect(cert.metadata["acme_email"]).to eq("ops@example.com")
      end
    end

    context "with an http-01 request (no dns credential needed)" do
      before { stub_successful_issue! }

      it "succeeds without a dns_credential_id" do
        expect do
          r = exec.execute(
            common_name: "ops.example.com",
            issuer: "letsencrypt-staging",
            challenge_type: "http-01"
          )
          expect(r[:success]).to be true
        end.to change(System::AcmeCertificate, :count).by(1)
      end
    end

    context "validation failures" do
      it "rejects an unknown issuer without creating a row" do
        expect do
          r = exec.execute(
            common_name: "ops.example.com",
            issuer: "self-signed-bogus",
            challenge_type: "http-01"
          )
          expect(r[:success]).to be false
          expect(r[:error]).to match(/Invalid issuer/)
        end.not_to change(System::AcmeCertificate, :count)
      end

      it "rejects an unknown challenge_type" do
        r = exec.execute(
          common_name: "ops.example.com",
          issuer: "letsencrypt-prod",
          challenge_type: "carrier-pigeon"
        )
        expect(r[:success]).to be false
        expect(r[:error]).to match(/Invalid challenge_type/)
      end

      it "requires a dns_credential_id for dns-01" do
        expect do
          r = exec.execute(
            common_name: "ops.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "dns-01"
          )
          expect(r[:success]).to be false
          expect(r[:error]).to match(/dns_credential_id is required/)
        end.not_to change(System::AcmeCertificate, :count)
      end

      it "fails when the dns credential is not found in the account" do
        r = exec.execute(
          common_name: "ops.example.com",
          issuer: "letsencrypt-prod",
          challenge_type: "dns-01",
          dns_credential_id: SecureRandom.uuid
        )
        expect(r[:success]).to be false
        expect(r[:error]).to match(/DNS credential not found/)
      end

      it "fails fast on a missing required input before touching the manager" do
        expect(::Acme::CertificateManager).not_to receive(:issue!)
        r = exec.execute(issuer: "letsencrypt-prod", challenge_type: "http-01")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/missing required input: common_name/)
      end
    end

    context "when issuance fails" do
      before do
        allow(::Acme::CertificateManager).to receive(:issue!) do |certificate:|
          certificate.transition_to!("failed", error_message: "ACME server unreachable")
          ::Acme::CertificateManager::Result.new(
            ok?: false, certificate: certificate, error: "ACME server unreachable"
          )
        end
      end

      it "returns a failure wrapping the manager error and keeps the row" do
        expect do
          r = exec.execute(
            common_name: "ops.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
          expect(r[:success]).to be false
          expect(r[:error]).to match(/issuance failed.*ACME server unreachable/)
        end.to change(System::AcmeCertificate, :count).by(1)
      end
    end
  end
end
