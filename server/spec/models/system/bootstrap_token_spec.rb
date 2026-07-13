# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.L — BootstrapToken
RSpec.describe System::BootstrapToken, type: :model do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }

  describe ".issue!" do
    it "returns [model, plaintext] and only stores the SHA-256 hash" do
      token, plaintext = described_class.issue!(node: node, intended_subject: "instance-abc")

      expect(plaintext).to be_present
      expect(plaintext).to match(/\A[A-Za-z0-9_-]+\z/) # urlsafe_base64
      expect(token.token_hash).to eq(Digest::SHA256.hexdigest(plaintext))
      expect(token.expires_at).to be_within(5.seconds).of(described_class::DEFAULT_TTL.from_now)
      expect(token.intended_subject).to eq("instance-abc")
      expect(token).to be_single_use
    end

    it "honors a custom TTL and purpose" do
      token, _ = described_class.issue!(
        node: node, intended_subject: "x", ttl: 5.minutes, purpose: "test"
      )
      expect(token.expires_at).to be_within(5.seconds).of(5.minutes.from_now)
      expect(token.purpose).to eq("test")
    end
  end

  describe ".find_active_by_plaintext" do
    it "matches a fresh token by plaintext" do
      token, plaintext = described_class.issue!(node: node, intended_subject: "x")
      expect(described_class.find_active_by_plaintext(plaintext)).to eq(token)
    end

    it "returns nil after consumption" do
      token, plaintext = described_class.issue!(node: node, intended_subject: "x")
      token.consume!
      expect(described_class.find_active_by_plaintext(plaintext)).to be_nil
    end

    it "returns nil after expiry" do
      token, plaintext = described_class.issue!(node: node, intended_subject: "x", ttl: 1.second)
      travel 2.seconds do
        expect(described_class.find_active_by_plaintext(plaintext)).to be_nil
      end
    end
  end

  describe "#consume!" do
    it "stamps consumed_at + consumed_from_ip" do
      token, _ = described_class.issue!(node: node, intended_subject: "x")
      token.consume!(from_ip: "10.0.0.1")
      expect(token.reload.consumed_at).to be_present
      expect(token.consumed_from_ip).to eq("10.0.0.1")
    end

    it "raises on double-consumption" do
      token, _ = described_class.issue!(node: node, intended_subject: "x")
      token.consume!
      expect { token.consume! }.to raise_error(described_class::InvalidConsumption, /already consumed/)
    end

    it "raises when expired" do
      token, _ = described_class.issue!(node: node, intended_subject: "x", ttl: 1.second)
      travel 2.seconds do
        expect { token.reload.consume! }.to raise_error(described_class::InvalidConsumption, /expired/)
      end
    end
  end

  # improvement 019f5cc9 — before the FK on system_bootstrap_tokens.
  # node_instance_id was relaxed to on_delete: :nullify (see
  # db/migrate/20260713140000_nullify_node_instance_on_delete_for_system_bootstrap_tokens.rb),
  # destroying a NodeInstance that still had a token pointing at it raised
  # ActiveRecord::InvalidForeignKey — masking
  # System::InstancePoolService::PoolError, "cloud provision failed: ..."
  # behind an unrelated integrity-constraint crash whenever a pool-warming
  # provider create failed AFTER EnrollmentSeed had already issued a token
  # for the just-created (and now-orphaned) NodeInstance.
  describe "on_delete behavior when the referenced NodeInstance is destroyed" do
    it "does not raise, and nullifies node_instance_id instead of blocking the destroy" do
      instance = create(:system_node_instance, node: node)
      token, _plaintext = described_class.issue!(
        node: node, node_instance: instance, intended_subject: instance.id, purpose: "proxmox_uefi_provision"
      )

      expect { instance.destroy! }.not_to raise_error

      expect(token.reload.node_instance_id).to be_nil
      # The audit record itself (node_id, purpose, token_hash, expires_at)
      # survives — only the dangling FK is cleared.
      expect(token.node_id).to eq(node.id)
      expect(token.purpose).to eq("proxmox_uefi_provision")
    end

    it "cleans up a NodeInstance destroyed via its parent Node (the real provision_warming_member! failure path)" do
      instance = create(:system_node_instance, node: node)
      _token, _plaintext = described_class.issue!(
        node: node, node_instance: instance, intended_subject: instance.id, purpose: "proxmox_uefi_provision"
      )

      expect { node.destroy! }.not_to raise_error
      expect(System::NodeInstance.exists?(instance.id)).to be false
    end
  end

  describe "scopes" do
    it "categorizes tokens by lifecycle state" do
      fresh, _    = described_class.issue!(node: node, intended_subject: "fresh")
      consumed, _ = described_class.issue!(node: node, intended_subject: "consumed")
      consumed.consume!
      stale, _    = described_class.issue!(node: node, intended_subject: "stale", ttl: 1.second)
      travel 2.seconds do
        expect(described_class.active).to include(fresh)
        expect(described_class.active).not_to include(consumed, stale)
        expect(described_class.consumed).to  include(consumed)
        expect(described_class.expired).to   include(stale)
      end
    end
  end
end
