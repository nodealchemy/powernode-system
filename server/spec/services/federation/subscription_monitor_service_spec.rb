# frozen_string_literal: true

require "rails_helper"

RSpec.describe Federation::SubscriptionMonitorService, type: :service do
  let(:account) { create(:account) }
  let(:peer)    { create(:system_federation_peer, :platform, :active, account: account) }
  let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }

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

  # Helper: build an active subscription with a known grant expiry + cert state.
  def make_subscription(grant_expires_at:, cert_status: "valid", sub_status: "active")
    grant = create(:system_federation_grant,
                   account: account, federation_peer: peer, grantor_user: nil,
                   remote_subject: "service-sub-#{SecureRandom.uuid}",
                   resource_kind: "service_offering",
                   resource_id: SecureRandom.uuid,
                   permission_scopes: %w[read],
                   issued_at: 30.days.ago,
                   expires_at: grant_expires_at)
    cert_traits = case cert_status
                  when "valid"  then [ :valid ]
                  when "failed" then []
                  else []
                  end
    cert = create(:system_acme_certificate, *cert_traits,
                  account: account, dns_credential: dns_cred,
                  status: cert_status)
    if cert_status == "failed"
      cert.update_columns(last_renewal_attempt_at: 1.hour.ago)
    end

    sub_traits = sub_status == "active" ? [ :active ] : []
    sub = create(:system_federation_service_subscription, *sub_traits,
                  account: account, federation_peer: peer,
                  federation_grant: grant, acme_certificate: cert,
                  status: sub_status)
    sub
  end

  describe ".run!" do
    context "with no subscriptions needing attention" do
      let!(:healthy_sub) { make_subscription(grant_expires_at: 60.days.from_now) }

      it "returns 0/0/0 with no findings" do
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.ok?).to be true
        expect(result.suspended_count).to eq(0)
        expect(result.cert_retried_count).to eq(0)
        expect(result.auto_cancelled_count).to eq(0)
        expect(result.findings).to be_empty
      end
    end

    context "with an expired-grant subscription" do
      let!(:expired_sub) { make_subscription(grant_expires_at: 1.day.ago) }

      it "suspends the subscription" do
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.suspended_count).to eq(1)
        expect(expired_sub.reload.status).to eq("suspended")
        expect(expired_sub.metadata["suspension_reason"]).to eq("federation_grant_expired")
        expect(result.findings.first[:kind]).to eq("suspended_expired_grant")
      end

      it "does not touch a subscription whose grant expires in the future" do
        healthy = make_subscription(grant_expires_at: 60.days.from_now)
        described_class.run!(account: account, acme_client: stub_client)
        expect(healthy.reload.status).to eq("active")
      end
    end

    context "with a failed-cert subscription past the cooldown" do
      let!(:cert_failed_sub) do
        make_subscription(grant_expires_at: 60.days.from_now, cert_status: "failed")
      end

      it "retries cert issuance via Acme::CertificateManager" do
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.cert_retried_count).to eq(1)
        expect(cert_failed_sub.acme_certificate.reload.status).to eq("valid")
        expect(result.findings.first[:kind]).to eq("cert_retried_success")
      end

      it "does NOT retry a failed cert still in the cooldown window" do
        cert_failed_sub.acme_certificate.update_columns(last_renewal_attempt_at: 5.minutes.ago)
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.cert_retried_count).to eq(0)
        expect(cert_failed_sub.acme_certificate.reload.status).to eq("failed")
      end

      it "records failure when CertificateManager raises" do
        allow(stub_client).to receive(:issue).and_raise(StandardError, "ACME 502")
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.cert_retried_count).to eq(0)
        expect(result.findings.first[:kind]).to eq("cert_retried_failure")
        expect(result.findings.first[:error]).to include("ACME 502")
      end
    end

    context "with a stale suspended subscription" do
      let!(:stale_sub) do
        make_subscription(grant_expires_at: 60.days.from_now, sub_status: "suspended")
          .tap { |s| s.update_columns(suspended_at: 45.days.ago) }
      end

      it "auto-cancels it" do
        result = described_class.run!(account: account, acme_client: stub_client)
        expect(result.auto_cancelled_count).to eq(1)
        expect(stale_sub.reload.status).to eq("cancelled")
        expect(stale_sub.metadata["cancellation_reason"]).to eq("auto_cancel_stale_suspension")
      end

      it "leaves a recently-suspended subscription untouched" do
        recent = make_subscription(grant_expires_at: 60.days.from_now, sub_status: "suspended")
        recent.update_columns(suspended_at: 5.days.ago)
        described_class.run!(account: account, acme_client: stub_client)
        expect(recent.reload.status).to eq("suspended")
      end
    end

    context "with mixed account scope" do
      let(:other_account) { create(:account) }
      let(:other_peer) { create(:system_federation_peer, :platform, :active, account: other_account) }
      let(:other_dns) { create(:system_acme_dns_credential, :valid, account: other_account) }

      let!(:mine) { make_subscription(grant_expires_at: 1.day.ago) }

      before do
        # Build an expired-grant subscription in another account
        other_grant = create(:system_federation_grant,
                              account: other_account, federation_peer: other_peer, grantor_user: nil,
                              remote_subject: "other-sub", resource_kind: "service_offering",
                              resource_id: SecureRandom.uuid,
                              permission_scopes: %w[read],
                              issued_at: 30.days.ago, expires_at: 1.day.ago)
        other_cert = create(:system_acme_certificate, :valid, account: other_account, dns_credential: other_dns)
        @other_sub = create(:system_federation_service_subscription, :active,
                             account: other_account, federation_peer: other_peer,
                             federation_grant: other_grant, acme_certificate: other_cert)
      end

      it "only sweeps the supplied account when scoped" do
        described_class.run!(account: account, acme_client: stub_client)
        expect(mine.reload.status).to eq("suspended")
        expect(@other_sub.reload.status).to eq("active")  # untouched
      end

      it "sweeps every account when account is nil" do
        described_class.run!(account: nil, acme_client: stub_client)
        expect(mine.reload.status).to eq("suspended")
        expect(@other_sub.reload.status).to eq("suspended")
      end
    end
  end
end
