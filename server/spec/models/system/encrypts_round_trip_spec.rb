# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse polish #2 — verifies that every Rails 7+ `encrypts :foo`
# declaration in the System extension actually persists + round-trips through
# the database. Catches the M0.H-style `_ciphertext` column-name mismatch
# (Rails-encrypts expects `foo`, attr_encrypted used `foo_ciphertext`).
RSpec.describe "System extension encrypts round-trip", type: :model do
  let(:account) { create(:account) }

  describe "System::Node SSH keys" do
    let(:template) { create(:system_node_template, account: account) }

    it "persists ssh_key + ssh_host_key through reload" do
      node = create(:system_node, account: account, node_template: template)
      original_identity = node.ssh_key
      original_host     = node.ssh_host_key
      node.reload
      expect(node.ssh_key).to       eq(original_identity).and be_present
      expect(node.ssh_host_key).to  eq(original_host).and be_present
    end
  end

  describe "System::ProviderConnection access/secret keys" do
    let(:provider) { create(:system_provider, account: account) }

    it "persists access_key + secret_key through reload" do
      conn = create(:system_provider_connection, account: account, provider: provider,
                    access_key: "AKIA-test-12345", secret_key: "secret-test-abcdef")
      conn.reload
      expect(conn.access_key).to eq("AKIA-test-12345")
      expect(conn.secret_key).to eq("secret-test-abcdef")
    end
  end

  describe "System::NodeInstance key" do
    let(:template) { create(:system_node_template, account: account) }
    let(:node)     { create(:system_node, account: account, node_template: template) }

    it "persists key through reload" do
      instance = create(:system_node_instance, :running, node: node)
      instance.update!(key: "instance-secret-#{SecureRandom.hex(8)}")
      original = instance.key
      instance.reload
      expect(instance.key).to eq(original).and be_present
    end
  end
end
