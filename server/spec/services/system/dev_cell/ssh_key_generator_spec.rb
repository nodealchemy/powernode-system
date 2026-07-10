# frozen_string_literal: true

require "rails_helper"
require "net/ssh"

# Correctness gate for the in-service OpenSSH Ed25519 encoding. A broken
# private-key blob (wrong checkint, padding, or field framing) would fail to
# parse in Net::SSH::KeyFactory — so a green round-trip proves the generated
# key actually works for git-over-SSH without ever shelling out to ssh-keygen.
#
# SECURITY: this spec asserts SHAPE + internal consistency only. No private key
# value is printed, logged, or persisted.
RSpec.describe System::DevCell::SshKeyGenerator do
  subject(:keypair) { described_class.generate(comment: "dev-cell-abc123") }

  it "generates an Ed25519 keypair in-service (no shell)" do
    expect(keypair.algorithm).to eq("ed25519")
  end

  it "produces an OpenSSH public key line for the Gitea deploy key" do
    expect(keypair.public_key_openssh).to start_with("ssh-ed25519 ")
    expect(keypair.public_key_openssh).to end_with(" dev-cell-abc123")
  end

  it "produces an OpenSSH private key in the git-consumable format" do
    expect(keypair.private_key_openssh).to start_with("-----BEGIN OPENSSH PRIVATE KEY-----\n")
    expect(keypair.private_key_openssh).to end_with("-----END OPENSSH PRIVATE KEY-----\n")
  end

  it "computes a SHA256 public-key fingerprint" do
    expect(keypair.fingerprint).to match(/\ASHA256:[A-Za-z0-9+\/]+\z/)
  end

  it "round-trips: the private + public encodings parse and are a matching pair" do
    priv = Net::SSH::KeyFactory.load_data_private_key(keypair.private_key_openssh)
    pub  = Net::SSH::KeyFactory.load_data_public_key(keypair.public_key_openssh)

    expect(priv.public_key.to_blob).to eq(pub.to_blob)
  end

  it "generates a distinct keypair each call" do
    other = described_class.generate(comment: "dev-cell-abc123")
    expect(other.public_key_openssh).not_to eq(keypair.public_key_openssh)
  end
end
