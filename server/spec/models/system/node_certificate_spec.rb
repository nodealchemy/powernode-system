# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.L — NodeCertificate
RSpec.describe System::NodeCertificate, type: :model do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let(:default_attrs) do
    {
      node_instance: instance,
      serial: SecureRandom.hex(16),
      subject: "CN=#{instance.id}",
      not_before: Time.current,
      not_after: 90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    }
  end

  describe "validations" do
    it "is valid with sane defaults" do
      expect(described_class.new(default_attrs)).to be_valid
    end

    it "rejects not_after <= not_before" do
      cert = described_class.new(default_attrs.merge(not_after: 1.day.ago))
      expect(cert).not_to be_valid
      expect(cert.errors[:not_after]).to be_present
    end

    it "enforces serial uniqueness" do
      described_class.create!(default_attrs)
      dup = described_class.new(default_attrs.merge(node_instance: create(:system_node_instance, :running, node: node)))
      expect(dup).not_to be_valid
      expect(dup.errors[:serial]).to be_present
    end
  end

  describe "lifecycle predicates" do
    let(:cert) { described_class.create!(default_attrs) }

    it "is active when not revoked and not expired" do
      expect(cert).to be_active
      expect(cert).not_to be_revoked
      expect(cert).not_to be_expired
    end

    it "becomes revoked after #revoke!" do
      cert.revoke!(reason: "test rotation")
      expect(cert).to be_revoked
      expect(cert).not_to be_active
      expect(cert.revocation_reason).to eq("test rotation")
    end

    it "raises on double-revocation" do
      cert.revoke!(reason: "x")
      expect { cert.revoke!(reason: "y") }.to raise_error(described_class::AlreadyRevoked)
    end

    it "becomes expired past not_after" do
      cert # force creation now so `let` doesn't lazily build inside the travel block
      travel 91.days do
        expect(cert.reload).to be_expired
        expect(cert).not_to be_active
      end
    end
  end

  describe "#due_for_rotation?" do
    it "is false when fresh" do
      cert = described_class.create!(default_attrs)
      expect(cert).not_to be_due_for_rotation
    end

    it "is true past 75% of lifetime" do
      cert = described_class.create!(default_attrs.merge(
        not_before: 80.days.ago, not_after: 10.days.from_now
      ))
      expect(cert).to be_due_for_rotation
    end

    it "is false after revocation" do
      cert = described_class.create!(default_attrs.merge(
        not_before: 80.days.ago, not_after: 10.days.from_now
      ))
      cert.revoke!(reason: "x")
      expect(cert).not_to be_due_for_rotation
    end
  end

  describe "scopes" do
    let!(:active_cert) { described_class.create!(default_attrs) }
    let!(:revoked_cert) do
      cert = described_class.create!(default_attrs.merge(serial: SecureRandom.hex(16),
                                                         node_instance: create(:system_node_instance, :running, node: node)))
      cert.revoke!(reason: "x")
      cert
    end
    let!(:expiring_cert) do
      described_class.create!(default_attrs.merge(serial: SecureRandom.hex(16),
                                                  node_instance: create(:system_node_instance, :running, node: node),
                                                  not_after: 3.days.from_now))
    end

    it "categorizes" do
      expect(described_class.active).to        include(active_cert, expiring_cert)
      expect(described_class.active).not_to    include(revoked_cert)
      expect(described_class.revoked).to       include(revoked_cert)
      expect(described_class.expiring_soon).to include(expiring_cert)
      expect(described_class.expiring_soon).not_to include(active_cert) # 90 days out
    end
  end

  describe "VaultCredential integration" do
    it "declares vault_credential_type = node_pki" do
      expect(described_class.vault_credential_type).to eq("node_pki")
    end
  end
end
