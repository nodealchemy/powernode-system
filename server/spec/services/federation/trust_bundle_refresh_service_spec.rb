# frozen_string_literal: true

require "rails_helper"

RSpec.describe Federation::TrustBundleRefreshService, type: :service do
  let(:account) { create(:account) }

  def symmetric_peer(ca_pem)
    p = create(:system_federation_peer, :active, account: account)
    p.update_columns(inbound_subject: "fed:#{p.id}", trusted_ca_pem: ca_pem)
    p
  end

  # A fake PeerClient factory returning a canned trust_bundle response.
  def factory_returning(ca_pem)
    fake = Class.new do
      def initialize(pem) = (@pem = pem)
      def fetch_trust_bundle = { "ca_bundle_pem" => @pem }
    end
    ->(_peer) { fake.new(ca_pem) }
  end

  it "updates trusted_ca_pem when the peer's CA rotated, then rewrites the bundle" do
    peer = symmetric_peer("-----BEGIN CERTIFICATE-----\nOLD\n-----END CERTIFICATE-----\n")
    expect(::Acme::TraefikConfigWriter).to receive(:write_client_auth_bundle!)

    result = described_class.run!(
      account: account,
      client_factory: factory_returning("-----BEGIN CERTIFICATE-----\nNEW\n-----END CERTIFICATE-----\n")
    )

    expect(result.updated).to eq(1)
    expect(peer.reload.trusted_ca_pem).to include("NEW")
  end

  it "is a no-op when the peer's CA is unchanged" do
    same = "-----BEGIN CERTIFICATE-----\nSAME\n-----END CERTIFICATE-----\n"
    peer = symmetric_peer(same)

    result = described_class.run!(account: account, client_factory: factory_returning(same))

    expect(result.updated).to eq(0)
    expect(peer.reload.trusted_ca_pem).to eq(same)
  end

  it "skips hierarchical peers (which have no trusted_ca_pem)" do
    create(:system_federation_peer, :active, account: account)
      .update_columns(inbound_subject: "fed:hier-#{SecureRandom.hex(4)}")

    result = described_class.run!(account: account, client_factory: factory_returning("X"))
    expect(result.checked).to eq(0)
  end

  it "collects per-peer failures without aborting the sweep" do
    symmetric_peer("OLD")
    failing = ->(_peer) { Class.new { def fetch_trust_bundle = raise("boom") }.new }

    result = described_class.run!(account: account, client_factory: failing)
    expect(result.failures.size).to eq(1)
  end
end
