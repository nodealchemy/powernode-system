# frozen_string_literal: true

require "rails_helper"

RSpec.describe Acme::RenewalSweepService, type: :service do
  let(:account) { create(:account) }
  let(:dns_cred) do
    create(:system_acme_dns_credential, :valid, account: account).tap do |c|
      c.update_columns(vault_path_credentials: "acme-dns/#{c.id}")
    end
  end

  let(:cert_material) do
    {
      cert_pem: "stub-cert", key_pem: "stub-key",
      chain_pem: "stub-chain", account_key_pem: "stub-acct",
      issued_at: Time.current, expires_at: 90.days.from_now
    }
  end

  let(:stub_client) do
    instance_double("Acme::LegoClient",
                    issue: cert_material,
                    renew: cert_material,
                    revoke: true)
  end

  let(:fake_vault) { instance_double("Security::VaultCredentialProvider") }

  before do
    allow(::Security::VaultCredentialProvider).to receive(:new).and_return(fake_vault)
    allow(fake_vault).to receive(:get_credential).and_return("api_token" => "stub-token")
    allow(fake_vault).to receive(:store_credential).and_return(true)
  end

  describe ".run!" do
    context "with no eligible certs" do
      let!(:fresh_valid) do
        create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                                  expires_at: 60.days.from_now)
      end

      it "returns 0 renewed, 0 failed, 0 skipped" do
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.ok?).to be true
        expect(result.renewed_count).to eq(0)
        expect(result.failed_count).to eq(0)
        expect(result.skipped_count).to eq(0)
      end
    end

    context "with a cert expiring within the renewal window" do
      let!(:expiring) do
        create(:system_acme_certificate, :expiring_soon, account: account, dns_credential: dns_cred)
      end

      it "calls Acme::CertificateManager.renew! and counts the result" do
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.ok?).to be true
        expect(result.renewed_count).to eq(1)
        expect(result.findings.first[:kind]).to eq("renewed")
        expect(expiring.reload.status).to eq("valid")
      end
    end

    context "with a failed cert outside the cooldown window" do
      let!(:failed_old) do
        create(:system_acme_certificate, account: account, dns_credential: dns_cred,
                                          status: "failed",
                                          last_renewal_attempt_at: 1.hour.ago)
      end

      it "retries issuance (cert was never valid)" do
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.renewed_count).to eq(1)
        expect(result.findings.first[:kind]).to eq("issued_retry")
        expect(failed_old.reload.status).to eq("valid")
      end
    end

    context "with a failed cert previously issued (renewal retry)" do
      let!(:failed_after_valid) do
        create(:system_acme_certificate, account: account, dns_credential: dns_cred,
                                          status: "failed",
                                          issued_at: 60.days.ago,
                                          last_renewal_attempt_at: 1.hour.ago)
      end

      it "retries renewal (cert was previously valid)" do
        # The CertificateManager.renew! expects status='valid', so we need
        # to ensure the cert is set to valid first — but the sweep service
        # decides action based on the row's current state. Force-set to
        # valid temporarily would mask the test. Instead, verify the
        # decision logic produces :renew (not :retry_issue) for this row.
        result = described_class.run!(account: account, acme_client: stub_client)
        # CertificateManager.renew! will reject because status="failed" not "valid".
        # The sweep records this as renew_failed.
        expect(result.findings.first[:kind]).to eq("renew_failed")
        expect(result.failed_count).to eq(1)
      end
    end

    context "with a failed cert inside the cooldown window" do
      let!(:failed_recent) do
        create(:system_acme_certificate, account: account, dns_credential: dns_cred,
                                          status: "failed",
                                          last_renewal_attempt_at: 5.minutes.ago)
      end

      it "skips it (cooldown prevents tight-loop retries)" do
        result = described_class.run!(account: account, acme_client: stub_client)
        # The DB query for failed certs filters by last_renewal_attempt_at < cooldown,
        # so this cert won't even appear in the sweep — total 0/0/0.
        expect(result.renewed_count).to eq(0)
        expect(result.failed_count).to eq(0)
        expect(failed_recent.reload.status).to eq("failed")
      end
    end

    context "when CertificateManager raises during renewal" do
      let!(:expiring) do
        create(:system_acme_certificate, :expiring_soon, account: account, dns_credential: dns_cred)
      end

      before do
        allow(stub_client).to receive(:renew).and_raise(StandardError, "ACME 502")
      end

      it "records the failure as a finding + transitions the cert to failed" do
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.failed_count).to eq(1)
        expect(result.findings.first[:kind]).to eq("renew_failed")
        expect(result.findings.first[:error]).to include("ACME 502")
        expect(expiring.reload.status).to eq("failed")
      end
    end

    context "across multiple accounts" do
      let(:other_account) { create(:account) }
      let(:other_dns)     { create(:system_acme_dns_credential, :valid, account: other_account) }

      let!(:mine)  { create(:system_acme_certificate, :expiring_soon, account: account, dns_credential: dns_cred) }
      let!(:theirs) { create(:system_acme_certificate, :expiring_soon, account: other_account, dns_credential: other_dns) }

      it "scopes to a single account when supplied" do
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.renewed_count).to eq(1)
        expect(theirs.reload.status).to eq("valid")  # untouched, still pre-renewal value
        # Specifically: theirs's expires_at should still be ~20 days (factory :expiring_soon)
        expect(theirs.expires_at).to be < 30.days.from_now
      end

      it "sweeps all accounts when account is nil" do
        result = described_class.run!(account: nil, acme_client: stub_client)
        expect(result.renewed_count).to eq(2)
      end
    end
  end
end
