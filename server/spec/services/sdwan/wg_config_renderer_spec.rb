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

  # Two named readers rather than one tuple: every call site wanted exactly
  # one half, and `_preamble, sections = peer_sections(...)` forced each of
  # them to name and discard the other (iteration-51 nit). Everything before
  # the first [Peer] is the [Interface] preamble.
  def preamble_of(text)
    text.split("[Peer]").first
  end

  def peer_sections(text)
    text.split("[Peer]").drop(1)
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

  # IMP-915b24d21f4f — BYTE-IDENTICAL PIN across the consolidation onto
  # Sdwan::PeerEntry. These are the exact bytes an operator pastes into a real
  # WireGuard client; the field order, the column alignment and the trailing
  # blank line are all part of the contract, and every one of them survived
  # the move unchanged. Written to pass BEFORE and AFTER the refactor.
  describe "rendered [Peer] section (exact bytes)" do
    it "renders a v6-primary hub with a v4 fallback" do
      hub = create(:sdwan_peer, :hub, account: network.account, network: network,
                                      endpoint_host_v4: "203.0.113.10")
      key = add_active_key!(hub)

      expect(peer_sections(described_class.render(device)).first).to eq(<<~INI)

        # Hub: #{hub.node_instance.name} (v6 primary)
        PublicKey  = #{key.public_key}
        Endpoint   = [fd00:abcd:1::1]:51820
        # Fallback (IPv4): 203.0.113.10:51820
        AllowedIPs = #{network.cidr_64}
        PersistentKeepalive = 25

      INI
    end

    it "renders a v4-only hub with no fallback comment" do
      hub = create(:sdwan_peer, account: network.account, network: network,
                                publicly_reachable: true, endpoint_host_v6: nil,
                                endpoint_host_v4: "203.0.113.11", endpoint_port: 51_820)
      key = add_active_key!(hub)

      expect(peer_sections(described_class.render(device)).first).to eq(<<~INI)

        # Hub: #{hub.node_instance.name} (v4 primary)
        PublicKey  = #{key.public_key}
        Endpoint   = 203.0.113.11:51820
        AllowedIPs = #{network.cidr_64}
        PersistentKeepalive = 25

      INI
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
    it "emits each hub's own active public key inside its [Peer] section" do
      hub_a = create(:sdwan_peer, :hub, account: network.account, network: network)
      hub_b = create(:sdwan_peer, :hub, account: network.account, network: network,
                                        endpoint_host_v6: "fd00:abcd:1::2")
      key_a = add_active_key!(hub_a)
      key_b = add_active_key!(hub_b)

      sections = peer_sections(described_class.render(device))
      expect(sections.length).to eq(2)

      section_a = sections.find { |s| s.include?("[fd00:abcd:1::1]:51820") }
      section_b = sections.find { |s| s.include?("[fd00:abcd:1::2]:51820") }
      expect(section_a).to include("PublicKey  = #{key_a.public_key}")
      expect(section_b).to include("PublicKey  = #{key_b.public_key}")
    end

    it "never places a peer PublicKey in the [Interface] preamble (wg semantics)" do
      hub = create(:sdwan_peer, :hub, account: network.account, network: network)
      key = add_active_key!(hub)

      text = described_class.render(device)
      preamble = preamble_of(text)
      sections = peer_sections(text)

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

      text = described_class.render(device)
      preamble = preamble_of(text)
      sections = peer_sections(text)

      expect(sections).to be_empty
      # IMP-3b49cd166b8c: skipping a keyless hub must not be SILENT — the
      # class header promises "an explicit comment so operators understand
      # why connection attempts will fail." Named by hub_label, matching the
      # [Peer] section comment wording used elsewhere in this file.
      expect(preamble).to include("WARNING")
      expect(preamble).to include(hub.node_instance.name)
    end
  end

  # IMP-3b49cd166b8c: a hub can pass the @hubs reachability filter and still
  # have no active key (revoked mid-rotation, or a genesis key not yet
  # generated). The renderer used to `next unless key` in the render loop
  # with zero explanation — a network whose hubs are all keyless rendered a
  # 200 OK config with an [Interface] section and NO [Peer] sections, and no
  # comment saying why. Operator direction: a keyless hub must be NAMED in a
  # preamble warning, worded differently depending on whether OTHER hubs
  # still render a usable [Peer] section (degraded redundancy) or not (total
  # failure — nothing to connect to).
  describe "keyless-hub preamble warning" do
    it "names the hub and states total failure when every hub is keyless" do
      hub = create(:sdwan_peer, :hub, account: network.account, network: network)
      # No add_active_key! at all — genesis key never generated.

      text = described_class.render(device)
      preamble = preamble_of(text)
      sections = peer_sections(text)

      expect(sections).to be_empty
      expect(preamble).to include("WARNING")
      expect(preamble).to include(hub.node_instance.name)
      # Total-failure wording: nothing usable remains.
      expect(preamble).to match(/cannot connect/i)
    end

    it "names the keyless hub as degraded redundancy when another hub is keyed" do
      keyless_hub = create(:sdwan_peer, :hub, account: network.account, network: network)
      keyed_hub = create(:sdwan_peer, :hub, account: network.account, network: network,
                                             endpoint_host_v6: "fd00:abcd:1::2")
      add_active_key!(keyed_hub)
      # keyless_hub gets no key at all.

      text = described_class.render(device)
      preamble = preamble_of(text)
      sections = peer_sections(text)

      # The keyed hub still renders its section — this config IS usable.
      expect(sections.length).to eq(1)
      expect(preamble).to include("WARNING")
      expect(preamble).to include(keyless_hub.node_instance.name)
      expect(preamble).not_to include(keyed_hub.node_instance.name)
      # Degraded-redundancy wording, distinct from the total-failure case:
      # the config is NOT described as unable to connect.
      expect(preamble).to match(/degraded/i)
      expect(preamble).not_to match(/cannot connect/i)
    end

    it "adds no keyless-hub warning to a fully-keyed network's preamble" do
      hub_a = create(:sdwan_peer, :hub, account: network.account, network: network)
      hub_b = create(:sdwan_peer, :hub, account: network.account, network: network,
                                        endpoint_host_v6: "fd00:abcd:1::2")
      add_active_key!(hub_a)
      add_active_key!(hub_b)

      text = described_class.render(device)
      preamble = preamble_of(text)
      sections = peer_sections(text)

      expect(sections.length).to eq(2)
      expect(preamble).not_to include("WARNING")
    end

    # Reviewer-flagged gap: every example above uses exactly ONE keyless hub,
    # so the plural branch of the wording (hub/hubs, has/have, was/were,
    # it is/they are) was never exercised — a swapped singular/plural
    # ternary would have passed all of them. These two cover ≥2 keyless hubs
    # for both the total-failure and degraded-redundancy wordings.
    it "names both hubs and uses plural wording when every hub is keyless (>1 hub)" do
      hub_a = create(:sdwan_peer, :hub, account: network.account, network: network)
      hub_b = create(:sdwan_peer, :hub, account: network.account, network: network,
                                        endpoint_host_v6: "fd00:abcd:1::2")
      # Neither hub gets a key.

      text = described_class.render(device)
      preamble = preamble_of(text)
      sections = peer_sections(text)

      expect(sections).to be_empty
      expect(preamble).to include(hub_a.node_instance.name)
      expect(preamble).to include(hub_b.node_instance.name)
      # Total-failure wording doesn't inflect on hub count ("every ... hub"),
      # so just confirm it's still there and unbroken.
      expect(preamble).to match(/cannot connect/i)
    end

    it "uses plural wording (hubs/have/were/they are) for >1 keyless hub in the degraded case" do
      keyless_a = create(:sdwan_peer, :hub, account: network.account, network: network)
      keyless_b = create(:sdwan_peer, :hub, account: network.account, network: network,
                                            endpoint_host_v6: "fd00:abcd:1::2")
      keyed_hub = create(:sdwan_peer, :hub, account: network.account, network: network,
                                            endpoint_host_v6: "fd00:abcd:1::3")
      add_active_key!(keyed_hub)
      # keyless_a and keyless_b get no key.

      text = described_class.render(device)
      preamble = preamble_of(text)
      sections = peer_sections(text)

      expect(sections.length).to eq(1)
      expect(preamble).to include(keyless_a.node_instance.name)
      expect(preamble).to include(keyless_b.node_instance.name)
      expect(preamble).not_to include(keyed_hub.node_instance.name)
      # The plural forms — a swapped/unswapped ternary bug would break these
      # exact substrings (singular "hub ... has ... was ... it is" would not
      # match).
      expect(preamble).to include("hubs ")
      expect(preamble).to include(" have no active key")
      expect(preamble).to include("were excluded")
      expect(preamble).to include("until they are re-keyed")
      expect(preamble).to match(/degraded/i)
      expect(preamble).not_to match(/cannot connect/i)
    end
  end
end

# IMP-94f3ec671b15 — AllowedIPs is a CRYPTOGRAPHIC ROUTING FILTER, not a label.
#
# The user-device config hardcoded `AllowedIPs = <network.cidr_64>`, so the
# tunnel handshakes and then the client OS silently declines to route anything
# outside that /64 into it. HubAndSpoke#spoke_view folds the same four prefix
# classes into a node spoke's AllowedIPs for exactly this reason — its own
# comment says "or the packets are dropped before they reach the tunnel" — and
# the user-device plane simply never received that enrichment.
#
# ENTITLEMENT, re-verified on HEAD before widening anything: Sdwan::AccessGrant
# is "a user's entitlement to attach VPN clients to ONE SDWAN network", and its
# `tags` column scopes nothing — SelectorResolver resolves PEER tags, and no
# service reads grant tags at all. So the grant's scope IS the network, and
# these prefixes are that network's own reachable surface. Nothing here widens
# past it.
RSpec.describe Sdwan::WgConfigRenderer, "AllowedIPs completeness" do
  let(:network) { create(:sdwan_network) }
  let(:grant)   { create(:sdwan_access_grant, account: network.account, network: network) }
  let(:device)  { create(:sdwan_user_device, access_grant: grant) }

  let!(:hub) do
    peer = create(:sdwan_peer, account: network.account, network: network,
                               publicly_reachable: true, endpoint_host: "hub.example.com",
                               endpoint_port: 51_820)
    Sdwan::PeerKey.create!(peer: peer, public_key: Base64.strict_encode64(SecureRandom.bytes(32)))
    peer
  end

  before { allow(device).to receive(:private_key_b64).and_return("FAKE-TEST-PLACEHOLDER") }

  def allowed_ips
    line = described_class.render(device).lines.map(&:chomp).find { |l| l.start_with?("AllowedIPs") }
    line.to_s.split("=", 2).last.to_s.split(",").map(&:strip)
  end

  it "still carries the network's own /64" do
    expect(allowed_ips).to include(network.cidr_64)
  end

  # A VirtualIp's CIDR is operator-supplied and NOT containment-checked against
  # cidr_64 (virtual_ip.rb; CreateVirtualIp passes attrs straight to create!),
  # so it routinely sits outside the /64 the old line permitted.
  it "routes the network's active VIP CIDRs" do
    vip = create(:sdwan_virtual_ip, account: network.account, network: network,
                                    cidr: "fd00:beef:1::/64", state: "active")

    expect(allowed_ips).to include(vip.cidr)
  end

  it "routes prefixes a peer advertises as lan_subnets" do
    create(:sdwan_peer, account: network.account, network: network,
                        lan_subnets: [ "10.50.0.0/16" ])

    expect(allowed_ips).to include("10.50.0.0/16")
  end

  # Not gated on the routing mode, for the reason spoke_view states for the
  # same class: a WG client cannot learn a route dynamically, so the filter
  # must permit the prefix however the route is distributed.
  it "routes federated remote prefixes" do
    # Drives the REAL resolver off a real peer rather than stubbing it: a stub
    # would pin the renderer's use of a seam without proving the seam yields
    # anything for a federation that actually exists.
    create(:system_federation_peer, :platform, account: network.account,
                                               status: "active",
                                               remote_prefix_advertisement: "fd00:fed:7::/48")

    expect(allowed_ips).to include("fd00:fed:7::/48")
  end

  # THE SECURITY DIRECTION, asserted rather than assumed: widen only to what the
  # grant scopes. A VIP belonging to a DIFFERENT network is not this grant's
  # business and must not appear.
  it "does not route another network's VIP" do
    other = create(:sdwan_network, account: network.account)
    foreign = create(:sdwan_virtual_ip, account: network.account, network: other,
                                        cidr: "fd00:beef:9::/64", state: "active")

    expect(allowed_ips).not_to include(foreign.cidr)
  end

  # An unassigned VIP is not reachable, so permitting it would widen the filter
  # past the live surface. `unassigned` (not "released" — see VirtualIp::STATES)
  # is outside the active/pending pair the compiler's all_vip_cidrs selects, and
  # this asserts the renderer uses the same window rather than every row.
  it "does not route an unassigned VIP" do
    idle = create(:sdwan_virtual_ip, account: network.account, network: network,
                                     cidr: "fd00:beef:2::/64", state: "unassigned")

    expect(allowed_ips).not_to include(idle.cidr)
  end
end
