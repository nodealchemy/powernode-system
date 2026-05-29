# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Fleet::Sensors::CertExpirySensor do
  let(:account) { create(:account) }
  let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }
  let(:sensor) { described_class.new(account: account) }

  before do
    System::AcmeCertificate.where(account_id: account.id).delete_all
  end

  describe "#sense" do
    it "emits no signals when there are no certificates" do
      expect(sensor.sense).to eq([])
    end

    it "ignores a valid cert well outside the renewal window" do
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                               expires_at: 60.days.from_now)
      expect(sensor.sense).to be_empty
    end

    it "emits a medium-severity signal for a cert inside the 30-day advisory window" do
      cert = create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                                      expires_at: 20.days.from_now)
      signals = sensor.sense
      sig = signals.find { |s| s.kind == "system.acme_cert_expiring" }
      expect(sig).not_to be_nil
      expect(sig.severity).to eq(:medium)
      expect(sig.payload["certificate_id"]).to eq(cert.id)
      expect(sig.payload["remediation_action"]).to eq("system.acme_cert_rotate")
    end

    it "escalates to high severity inside the 7-day urgent window" do
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                               expires_at: 3.days.from_now)
      sig = sensor.sense.find { |s| s.kind == "system.acme_cert_expiring" }
      expect(sig.severity).to eq(:high)
    end

    it "uses a stable per-certificate fingerprint" do
      cert = create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                                      expires_at: 10.days.from_now)
      sig = sensor.sense.find { |s| s.kind == "system.acme_cert_expiring" }
      expect(sig.fingerprint).to eq("acme_cert_expiring:#{cert.id}")
    end

    it "ignores certs that are not in the valid state (the needs_renewal scope filters them)" do
      # An expired (non-valid) row whose expires_at is within the window
      # must NOT emit — only `valid` certs are renewable via cert_rotate.
      create(:system_acme_certificate, :expired, account: account, dns_credential: dns_cred,
                                                 expires_at: 5.days.from_now)
      expect(sensor.sense).to be_empty
    end

    it "does not renew or mutate the cert — purely senses" do
      cert = create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                                      expires_at: 5.days.from_now)
      expect { sensor.sense }.not_to change { cert.reload.status }
      expect(cert.reload.status).to eq("valid")
    end

    it "scopes to the current account" do
      other_account = create(:account)
      other_cred = create(:system_acme_dns_credential, :valid, account: other_account)
      create(:system_acme_certificate, :valid, account: other_account, dns_credential: other_cred,
                                               expires_at: 5.days.from_now)
      expect(sensor.sense).to be_empty
    end

    it "emits for every expiring cert and none of the healthy ones" do
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                               common_name: "expiring-1.example.com",
                                               expires_at: 10.days.from_now)
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                               common_name: "expiring-2.example.com",
                                               expires_at: 25.days.from_now)
      create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred,
                                               common_name: "healthy.example.com",
                                               expires_at: 80.days.from_now)

      signals = sensor.sense
      expect(signals.size).to eq(2)
      expect(signals.map { |s| s.payload["common_name"] }).to match_array(
        %w[expiring-1.example.com expiring-2.example.com]
      )
    end
  end
end
