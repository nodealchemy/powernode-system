# frozen_string_literal: true

require "rails_helper"

# Skill: acme_certificate_provision — issues a new ACME TLS certificate.
# ::Acme::CertificateManager.issue! is always stubbed so no ACME / network
# work happens; we assert the row is created, the manager is driven, and the
# return shape + validation guards hold.
RSpec.describe System::Ai::Skills::AcmeCertificateProvisionExecutor do
  let(:account)        { create(:account) }

  # APO-1c (IMP-7e2bdc1774e4). This executor declares `requires_approval: true`,
  # and BaseSkillExecutor#execute now resolves Ai::InterventionPolicy BEFORE
  # #perform — an unconfigured category defaults to require_approval, so every
  # example below would park an approval instead of performing. These examples
  # are about what #perform DOES, so an operator policy puts the gate on its
  # proceed branch rather than removing it: the real entry point still runs.
  # See spec/support/skill_gate_helpers.rb.
  before { auto_execute_skill_policy!(account, described_class) }
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

    # Re-provision idempotency. The model scopes common_name uniqueness to
    # NON-terminal rows (only `revoked` is terminal), so a leftover `failed`
    # / `pending` / `issuing` row blocks a fresh `create!` for the same CN.
    # The executor must REUSE an existing non-terminal row instead of trying
    # to create a duplicate — otherwise an operator can't retry after a
    # transient ACME failure.
    context "re-provisioning a common name that already has a row" do
      # REPRODUCES THE BUG: with a leftover `failed` row for the CN, a
      # naive create! hits "Common name has already been taken". Against
      # the unfixed executor this example fails (RecordInvalid surfaced as
      # `Could not create certificate: ... Common name has already been
      # taken`, success=false, AND a brand-new row is never created).
      it "reuses an existing failed row and re-issues without a uniqueness error" do
        existing = create(
          :system_acme_certificate, :http01,
          account: account, common_name: "retry.example.com",
          issuer: "letsencrypt-staging", status: "failed"
        )

        stub_successful_issue!

        result = nil
        expect do
          result = exec.execute(
            common_name: "retry.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
        end.not_to change(System::AcmeCertificate, :count)

        expect(result[:success]).to be true
        expect(result[:error]).to be_nil
        # Same row, re-issued through the same CertificateManager path.
        expect(result[:data][:certificate_id]).to eq(existing.id)
        expect(result[:data][:status]).to eq("valid")
        # Mutable request fields are refreshed onto the reused row.
        expect(existing.reload.issuer).to eq("letsencrypt-prod")
      end

      it "reuses a leftover pending row (aborted issuance) for the same CN" do
        existing = create(
          :system_acme_certificate, :http01,
          account: account, common_name: "aborted.example.com", status: "pending"
        )

        stub_successful_issue!

        expect do
          r = exec.execute(
            common_name: "aborted.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
          expect(r[:success]).to be true
          expect(r[:data][:certificate_id]).to eq(existing.id)
        end.not_to change(System::AcmeCertificate, :count)
      end

      it "reuses a leftover issuing row (crashed mid-issuance) for the same CN" do
        existing = create(
          :system_acme_certificate, :http01,
          account: account, common_name: "stuck.example.com", status: "issuing"
        )

        stub_successful_issue!

        expect do
          r = exec.execute(
            common_name: "stuck.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
          expect(r[:success]).to be true
          expect(r[:data][:certificate_id]).to eq(existing.id)
        end.not_to change(System::AcmeCertificate, :count)
      end

      it "reuses a valid + unexpired row without re-issuing" do
        existing = create(
          :system_acme_certificate, :http01, :valid,
          account: account, common_name: "live.example.com"
        )

        # A valid+unexpired cert is reused as-is; no ACME work happens.
        expect(::Acme::CertificateManager).not_to receive(:issue!)

        result = nil
        expect do
          result = exec.execute(
            common_name: "live.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
        end.not_to change(System::AcmeCertificate, :count)

        expect(result[:success]).to be true
        expect(result[:data][:certificate_id]).to eq(existing.id)
        expect(result[:data][:status]).to eq("valid")
      end

      it "does not silently treat a valid-but-expired row as live (routes to renewal)" do
        existing = create(
          :system_acme_certificate, :http01,
          account: account, common_name: "stale.example.com",
          status: "valid", issued_at: 100.days.ago, expires_at: 1.day.ago
        )

        # An expired `valid` row is NOT reusable as-is, and the state machine
        # has no `valid → issuing` edge — re-issuance for it belongs to the
        # renewal path (AcmeCertificateRenewalJob), not this provision skill.
        # We must NOT create a duplicate and must NOT claim success.
        expect(::Acme::CertificateManager).not_to receive(:issue!)

        result = nil
        expect do
          result = exec.execute(
            common_name: "stale.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
        end.not_to change(System::AcmeCertificate, :count)

        expect(result[:success]).to be false
        expect(result[:error]).to match(/renew/i)
        expect(existing.reload.status).to eq("valid")
      end

      it "creates a fresh row for a brand-new common name" do
        stub_successful_issue!

        result = nil
        expect do
          result = exec.execute(
            common_name: "brand-new.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
        end.to change(System::AcmeCertificate, :count).by(1)

        expect(result[:success]).to be true
        created = System::AcmeCertificate.find_by(common_name: "brand-new.example.com", account: account)
        expect(result[:data][:certificate_id]).to eq(created.id)
      end

      it "does not reuse a row belonging to a different account" do
        other_account = create(:account)
        create(
          :system_acme_certificate, :http01,
          account: other_account, common_name: "scoped.example.com", status: "failed"
        )

        stub_successful_issue!

        result = nil
        expect do
          result = exec.execute(
            common_name: "scoped.example.com",
            issuer: "letsencrypt-prod",
            challenge_type: "http-01"
          )
        end.to change { System::AcmeCertificate.where(account: account).count }.by(1)

        expect(result[:success]).to be true
      end
    end
  end
end
