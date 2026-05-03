# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M0.H — Node SSH keypair auto-generation + authorized_keys aggregation.
# Reference: ~/Drive/Projects/powernode-server/app/models/node.rb:50-58, 134-145.
RSpec.describe System::Node, type: :model do
  let(:account) { create(:account) }

  describe "SSH keypair auto-generation on create" do
    context "with default platform config" do
      let(:node_template) { create(:system_node_template, account: account) }

      it "auto-generates Ed25519 identity and host keypairs" do
        node = described_class.create!(
          account: account,
          node_template: node_template,
          name: "ed25519-node"
        )

        expect(node.ssh_key).to be_present
        expect(node.ssh_host_key).to be_present
        expect(node.ssh_key_type).to eq("ed25519")

        identity = OpenSSL::PKey.read(node.ssh_key)
        host = OpenSSL::PKey.read(node.ssh_host_key)
        expect(identity.oid).to eq("ED25519")
        expect(host.oid).to eq("ED25519")
        expect(identity.private_to_pem).not_to eq(host.private_to_pem)
      end

      it "computes fingerprints in SHA256:<base64-no-padding> form" do
        node = described_class.create!(
          account: account,
          node_template: node_template,
          name: "fp-node"
        )

        expect(node.ssh_key_fingerprint).to match(%r{\ASHA256:[A-Za-z0-9+/]+\z})
        expect(node.ssh_host_key_fingerprint).to match(%r{\ASHA256:[A-Za-z0-9+/]+\z})
        expect(node.ssh_key_fingerprint).not_to eq(node.ssh_host_key_fingerprint)
      end

      it "does not regenerate keys on subsequent saves" do
        node = described_class.create!(
          account: account,
          node_template: node_template,
          name: "stable-node"
        )
        original_identity = node.ssh_key
        original_host = node.ssh_host_key
        original_fp = node.ssh_key_fingerprint

        node.update!(name: "renamed-node")
        node.reload

        expect(node.ssh_key).to eq(original_identity)
        expect(node.ssh_host_key).to eq(original_host)
        expect(node.ssh_key_fingerprint).to eq(original_fp)
      end

      it "does not overwrite a pre-set ssh_key" do
        custom_pem = OpenSSL::PKey.generate_key("ED25519").private_to_pem
        node = described_class.create!(
          account: account,
          node_template: node_template,
          name: "custom-key-node",
          ssh_key: custom_pem
        )
        expect(node.ssh_key).to eq(custom_pem)
        # Host key still gets generated since only identity was supplied.
        expect(node.ssh_host_key).to be_present
        expect(node.ssh_host_key).not_to eq(custom_pem)
      end
    end

    context "with legacy_rsa_keys set in node_template.config" do
      let(:node_template) do
        create(:system_node_template, account: account, config: { "legacy_rsa_keys" => true })
      end

      it "generates RSA 2048 keys instead of Ed25519" do
        node = described_class.create!(
          account: account,
          node_template: node_template,
          name: "rsa-node"
        )

        expect(node.ssh_key_type).to eq("rsa")
        identity = OpenSSL::PKey.read(node.ssh_key)
        expect(identity).to be_a(OpenSSL::PKey::RSA)
        expect(identity.n.num_bits).to eq(2048)
      end
    end
  end

  describe "#ssh_public_key / #ssh_host_public_key" do
    let(:node_template) { create(:system_node_template, account: account) }
    let(:node) { create(:system_node, account: account, node_template: node_template) }

    it "returns the public key in PEM format" do
      expect(node.ssh_public_key).to be_present
      expect(node.ssh_public_key).to include("PUBLIC KEY")
    end

    it "returns the host public key in PEM format" do
      expect(node.ssh_host_public_key).to be_present
      expect(node.ssh_host_public_key).to include("PUBLIC KEY")
    end

    it "returns nil when ssh_key is blank" do
      allow(node).to receive(:ssh_key).and_return(nil)
      expect(node.ssh_public_key).to be_nil
    end

    it "returns nil and logs an error when private key is malformed" do
      allow(node).to receive(:ssh_key).and_return("NOT A REAL KEY")
      expect(Rails.logger).to receive(:error).with(/Failed to derive public key/)
      expect(node.ssh_public_key).to be_nil
    end
  end

  describe "#authorized_keys" do
    let(:node_template) { create(:system_node_template, account: account) }
    let(:node) { create(:system_node, account: account, node_template: node_template) }

    it "includes the node's own public key" do
      expect(node.authorized_keys).to include(node.ssh_public_key)
    end

    it "includes operator-supplied keys from config['authorized_keys']" do
      operator_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... operator@example.com"
      node.update!(config: { "authorized_keys" => [ operator_key ] })

      expect(node.authorized_keys).to include(operator_key)
      expect(node.authorized_keys).to include(node.ssh_public_key)
    end

    it "deduplicates entries" do
      key = node.ssh_public_key
      node.update!(config: { "authorized_keys" => [ key, key ] })
      expect(node.authorized_keys.count(key)).to eq(1)
    end
  end

  describe "#authorized_keys_text" do
    let(:node_template) { create(:system_node_template, account: account) }
    let(:node) { create(:system_node, account: account, node_template: node_template) }

    it "joins keys with newlines and ends with a trailing newline" do
      text = node.authorized_keys_text
      expect(text).to end_with("\n")
      expect(text.lines.count).to be >= 1
    end

    it "returns empty string when authorized_keys is empty" do
      allow(node).to receive(:authorized_keys).and_return([])
      expect(node.authorized_keys_text).to eq("")
    end
  end

  describe "validation" do
    let(:node_template) { create(:system_node_template, account: account) }

    it "rejects an invalid ssh_key_type" do
      node = build(:system_node, account: account, node_template: node_template, ssh_key_type: "wat")
      expect(node).not_to be_valid
      expect(node.errors[:ssh_key_type]).to be_present
    end

    it "accepts ed25519 and rsa" do
      %w[ed25519 rsa].each do |type|
        node = build(:system_node, account: account, node_template: node_template, ssh_key_type: type)
        # name uniqueness is per-account; build with sequence-distinct names
        node.name = "node-type-#{type}"
        expect(node).to be_valid
      end
    end
  end
end
