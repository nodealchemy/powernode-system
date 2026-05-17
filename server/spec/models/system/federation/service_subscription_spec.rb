# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Federation::ServiceSubscription, type: :model do
  let(:account) { create(:account) }

  describe "validations" do
    it "requires service_offering_slug, local_hostname, protocol, backend_port, status" do
      sub = described_class.new(account: account)
      expect(sub).not_to be_valid
      expect(sub.errors[:local_hostname]).to be_present
      expect(sub.errors[:backend_port]).to be_present
    end

    it "rejects unknown protocol" do
      sub = build(:system_federation_service_subscription, account: account, protocol: "smoke-signal")
      expect(sub).not_to be_valid
    end

    it "enforces unique local_hostname within account" do
      create(:system_federation_service_subscription, account: account, local_hostname: "git.example.com")
      dup = build(:system_federation_service_subscription, account: account, local_hostname: "git.example.com")
      expect(dup).not_to be_valid
    end

    it "allows the same hostname across different accounts" do
      other_account = create(:account)
      create(:system_federation_service_subscription, account: account, local_hostname: "git.example.com")
      other = build(:system_federation_service_subscription, account: other_account, local_hostname: "git.example.com")
      expect(other).to be_valid
    end
  end

  describe "TLS vs site-local cert requirements" do
    it "requires acme_certificate for https subscriptions" do
      sub = build(:system_federation_service_subscription, account: account, protocol: "https",
                                                            acme_certificate: nil)
      expect(sub).not_to be_valid
      expect(sub.errors[:acme_certificate_id]).to include(/required for https/)
    end

    it "requires acme_certificate for tls (raw TLS) subscriptions" do
      sub = build(:system_federation_service_subscription, :tcp,
                                                            account: account,
                                                            protocol: "tls",
                                                            acme_certificate: nil)
      expect(sub).not_to be_valid
    end

    it "permits no cert for site-local TCP forwards" do
      sub = build(:system_federation_service_subscription, :site_local, account: account)
      expect(sub).to be_valid
    end

    it "rejects a site-local subscription that erroneously has a cert" do
      sub = build(:system_federation_service_subscription, :site_local, account: account,
                                                                         acme_certificate: create(:system_acme_certificate, :valid, account: account))
      expect(sub).not_to be_valid
      expect(sub.errors[:acme_certificate_id]).to include(/must be nil for site-local/)
    end

    it "permits http subscriptions without a cert (rare; TLS handled upstream)" do
      sub = build(:system_federation_service_subscription, account: account, protocol: "http",
                                                            acme_certificate: nil)
      expect(sub).to be_valid
    end
  end

  describe "state machine" do
    let(:sub) { create(:system_federation_service_subscription, account: account) }

    it "permits pending → active" do
      expect(sub.activate!).to be true
      expect(sub.reload.status).to eq("active")
      expect(sub.activated_at).to be_present
    end

    it "permits active → suspended → active (re-activate)" do
      sub.activate!
      sub.suspend!(reason: "operator pause")
      expect(sub.reload.status).to eq("suspended")
      expect(sub.metadata["suspension_reason"]).to eq("operator pause")

      sub.activate!
      expect(sub.reload.status).to eq("active")
    end

    it "permits any non-terminal → cancelled" do
      sub.cancel!(reason: "subscriber tear-down")
      expect(sub.reload.status).to eq("cancelled")
      expect(sub.terminal?).to be true
    end

    it "refuses transitions from cancelled (terminal)" do
      sub.update!(status: "cancelled")
      expect(sub.activate!).to be false
      expect(sub.suspend!).to be false
    end
  end

  describe "#site_local?" do
    it "is true for localhost:<port> hostnames" do
      sub = build(:system_federation_service_subscription, :site_local)
      expect(sub.site_local?).to be true
    end

    it "is true for 127.0.0.1:<port> hostnames" do
      sub = build(:system_federation_service_subscription, :site_local,
                                                            local_hostname: "127.0.0.1:6379",
                                                            acme_certificate: nil)
      expect(sub.site_local?).to be true
    end

    it "is false for public hostnames" do
      sub = build(:system_federation_service_subscription)
      expect(sub.site_local?).to be false
    end
  end

  describe "scopes" do
    let!(:pending)   { create(:system_federation_service_subscription, account: account) }
    let!(:active)    { create(:system_federation_service_subscription, :active, account: account) }
    let!(:suspended) { create(:system_federation_service_subscription, :suspended, account: account) }
    let!(:cancelled) { create(:system_federation_service_subscription, :cancelled, account: account) }

    it ".active_subscriptions returns only active" do
      expect(described_class.active_subscriptions.pluck(:id)).to eq([ active.id ])
    end

    it ".live returns pending + active + suspended (everything non-terminal)" do
      expect(described_class.live.pluck(:id)).to match_array([ pending.id, active.id, suspended.id ])
    end

    it ".terminal returns only cancelled" do
      expect(described_class.terminal.pluck(:id)).to eq([ cancelled.id ])
    end
  end
end
