# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::AcmeCertificate, type: :model do
  let(:account) { create(:account) }
  let(:dns_cred) { create(:system_acme_dns_credential, :valid, account: account) }

  describe "validations" do
    it "requires common_name + issuer + challenge_type + status" do
      cert = described_class.new(account: account)
      expect(cert).not_to be_valid
      expect(cert.errors[:common_name]).to be_present
    end

    it "enforces issuer whitelist" do
      cert = build(:system_acme_certificate, account: account, dns_credential: dns_cred,
                                              issuer: "fly-by-night-CA")
      expect(cert).not_to be_valid
      expect(cert.errors[:issuer]).to be_present
    end

    it "enforces unique common_name within an account" do
      create(:system_acme_certificate, account: account, dns_credential: dns_cred,
                                       common_name: "hub.example.com")
      dup = build(:system_acme_certificate, account: account, dns_credential: dns_cred,
                                            common_name: "hub.example.com")
      expect(dup).not_to be_valid
      expect(dup.errors[:common_name]).to be_present
    end

    it "requires dns_credential for dns-01 challenge" do
      cert = build(:system_acme_certificate, account: account, dns_credential: nil,
                                              challenge_type: "dns-01")
      expect(cert).not_to be_valid
      expect(cert.errors[:dns_credential_id]).to include(/required for dns-01/)
    end

    it "does NOT require dns_credential for http-01 challenge" do
      cert = build(:system_acme_certificate, :http01, account: account)
      expect(cert).to be_valid
    end
  end

  describe "state machine" do
    let(:cert) { create(:system_acme_certificate, account: account, dns_credential: dns_cred) }

    it "permits pending → issuing → valid" do
      expect(cert.can_transition_to?("issuing")).to be true
      cert.transition_to!("issuing")
      expect(cert.can_transition_to?("valid")).to be true
      cert.transition_to!("valid", attrs: { issued_at: Time.current, expires_at: 90.days.from_now })
      expect(cert.reload.status).to eq("valid")
    end

    it "forbids pending → valid (must go through issuing)" do
      expect(cert.can_transition_to?("valid")).to be false
    end

    it "permits valid → renewing → valid" do
      cert.update!(status: "valid", issued_at: Time.current, expires_at: 60.days.from_now)
      cert.transition_to!("renewing")
      expect(cert.reload.status).to eq("renewing")
      cert.transition_to!("valid", attrs: { issued_at: Time.current, expires_at: 90.days.from_now })
      expect(cert.reload.status).to eq("valid")
    end

    it "captures error_message on failed transition" do
      cert.transition_to!("issuing")
      cert.transition_to!("failed", error_message: "DNS provider 502")
      expect(cert.reload.last_renewal_error).to eq("DNS provider 502")
      expect(cert.last_renewal_attempt_at).to be_present
    end

    it "clears last_renewal_error on transition to valid" do
      cert.update!(status: "failed", last_renewal_error: "old error")
      cert.transition_to!("issuing")  # failed → issuing
      cert.transition_to!("valid", attrs: { issued_at: Time.current, expires_at: 90.days.from_now })
      expect(cert.reload.last_renewal_error).to be_nil
    end

    it "revoked is terminal" do
      cert.update!(status: "revoked")
      expect(cert.can_transition_to?("valid")).to be false
      expect(cert.can_transition_to?("issuing")).to be false
      expect(cert.terminal?).to be true
    end
  end

  describe "expiry predicates" do
    it "expiring_within? true when expires_at is within window" do
      cert = build(:system_acme_certificate, :expiring_soon)
      expect(cert.expiring_within?(described_class::RENEWAL_WINDOW)).to be true
    end

    it "expiring_within? false when expires_at is far future" do
      cert = build(:system_acme_certificate, :valid)
      expect(cert.expiring_within?(described_class::RENEWAL_WINDOW)).to be false
    end

    it "expired? true when past expires_at" do
      cert = build(:system_acme_certificate, :expired)
      expect(cert.expired?).to be true
    end
  end

  describe "scopes" do
    let!(:issued_cert)    { create(:system_acme_certificate, :valid, account: account, dns_credential: dns_cred) }
    let!(:expiring_cert)  { create(:system_acme_certificate, :expiring_soon, account: account, dns_credential: dns_cred) }
    let!(:expired_cert)   { create(:system_acme_certificate, :expired, account: account, dns_credential: dns_cred) }
    let!(:revoked_cert)   { create(:system_acme_certificate, :revoked, account: account, dns_credential: dns_cred) }

    it ".issued returns only status=valid" do
      ids = described_class.issued.pluck(:id)
      expect(ids).to include(issued_cert.id, expiring_cert.id)
      expect(ids).not_to include(expired_cert.id, revoked_cert.id)
    end

    it ".needs_renewal returns valid certs within the renewal window" do
      ids = described_class.needs_renewal.pluck(:id)
      expect(ids).to include(expiring_cert.id)
      expect(ids).not_to include(issued_cert.id)  # 90 days out, not within window
    end

    it ".active_certs excludes terminal states (revoked)" do
      ids = described_class.active_certs.pluck(:id)
      expect(ids).to include(issued_cert.id, expiring_cert.id, expired_cert.id)
      expect(ids).not_to include(revoked_cert.id)
    end
  end
end
