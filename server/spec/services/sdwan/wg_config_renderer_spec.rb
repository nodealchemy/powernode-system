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

  # IMP-651ec6336654 — WireGuard requires `PublicKey = <base64>` in every
  # [Peer] section; without it wg setconf / every WG client rejects the
  # config outright. Only the hub's PUBLIC key (column-stored, non-secret)
  # may ever appear here — never the private half.
  describe "[Peer] PublicKey line" do
    def peer_sections(text)
      # Everything before the first [Peer] is the [Interface] preamble.
      preamble, *sections = text.split("[Peer]")
      [preamble, sections]
    end

    it "emits each hub's own active public key inside its [Peer] section" do
      hub_a = create(:sdwan_peer, :hub, account: network.account, network: network)
      hub_b = create(:sdwan_peer, :hub, account: network.account, network: network,
                                        endpoint_host_v6: "fd00:abcd:1::2")
      key_a = add_active_key!(hub_a)
      key_b = add_active_key!(hub_b)

      _preamble, sections = peer_sections(described_class.render(device))
      expect(sections.length).to eq(2)

      section_a = sections.find { |s| s.include?("[fd00:abcd:1::1]:51820") }
      section_b = sections.find { |s| s.include?("[fd00:abcd:1::2]:51820") }
      expect(section_a).to include("PublicKey  = #{key_a.public_key}")
      expect(section_b).to include("PublicKey  = #{key_b.public_key}")
    end

    it "never places a peer PublicKey in the [Interface] preamble (wg semantics)" do
      hub = create(:sdwan_peer, :hub, account: network.account, network: network)
      key = add_active_key!(hub)

      preamble, sections = peer_sections(described_class.render(device))

      expect(preamble).not_to include("PublicKey")
      expect(sections.length).to eq(1)
      expect(sections.first).to include("PublicKey  = #{key.public_key}")
    end

    it "still omits the whole [Peer] section for a hub with only a revoked key" do
      # Negative control for the guard the fix makes load-bearing: with no
      # active key there is nothing to put on the PublicKey line, so the
      # renderer must skip the section rather than emit an unusable one.
      # (Positive twin: the examples above, where an active key exists.)
      hub = create(:sdwan_peer, :hub, account: network.account, network: network)
      add_active_key!(hub).revoke!(reason: "test rotation")

      _preamble, sections = peer_sections(described_class.render(device))

      expect(sections).to be_empty
    end
  end
end
