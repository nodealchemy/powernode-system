# frozen_string_literal: true

require "rails_helper"

# IMP-1c08ab7f5ecd — the Endpoint line is DATA-PLANE text: an operator pastes
# this config into a real WireGuard client. WireGuard's Endpoint syntax
# requires an IPv6 literal to be bracketed (`Endpoint = [fd00::1]:51820`);
# unbracketed, host and port are not separable and the client cannot parse it.
#
# NO-KEY-OUTPUT RULE: the renderer emits a PrivateKey line, so every example
# neutralizes the Vault-backed key read (UserDevice#private_key_b64) with an
# obviously-fake placeholder. Never run this renderer outside this test seam,
# and never put real or realistic key material in fixtures or assertions.
RSpec.describe Sdwan::WgConfigRenderer do
  let(:network) { create(:sdwan_network) }
  let(:grant)   { create(:sdwan_access_grant, account: network.account, network: network) }
  let(:device)  { create(:sdwan_user_device, access_grant: grant) }

  let(:fake_private_key) { "FAKE-TEST-PLACEHOLDER-NOT-A-REAL-PRIVATE-KEY" }

  before do
    allow(device).to receive(:private_key_b64).and_return(fake_private_key)
  end

  def add_active_key!(peer)
    # 44-char base64 of random bytes — a PUBLIC key stand-in (not secret),
    # matching the PeerKey format validation. No private half exists.
    Sdwan::PeerKey.create!(peer: peer, public_key: Base64.strict_encode64(SecureRandom.bytes(32)))
  end

  def rendered_lines
    described_class.render(device).lines.map(&:chomp)
  end

  describe "Endpoint line" do
    it "brackets an IPv6-literal hub endpoint (exact line)" do
      hub = create(:sdwan_peer, :hub, account: network.account, network: network)
      add_active_key!(hub)

      lines = rendered_lines

      expect(lines).to include("Endpoint   = [fd00:abcd:1::1]:51820")
      expect(lines).not_to include("Endpoint   = fd00:abcd:1::1:51820")
    end

    it "leaves a hostname stored in the v6 column unbracketed (positive twin)" do
      # endpoint_host_v6_must_be_v6_or_hostname accepts hostnames (DNS hands
      # back the AAAA), so family :v6 does not imply a literal —
      # "[edge.example.net]:51820" would be an address no client can use.
      hub = create(:sdwan_peer, :hub, account: network.account, network: network,
                                      endpoint_host_v6: "edge.example.net")
      add_active_key!(hub)

      lines = rendered_lines

      expect(lines).to include("Endpoint   = edge.example.net:51820")
      expect(lines.join("\n")).not_to include("[edge.example.net]")
    end
  end

  describe "key material seam" do
    it "emits the stubbed placeholder, proving the Vault read is neutralized" do
      hub = create(:sdwan_peer, :hub, account: network.account, network: network)
      add_active_key!(hub)

      expect(rendered_lines).to include("PrivateKey = #{fake_private_key}")
    end
  end
end
