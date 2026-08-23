# frozen_string_literal: true

require "rails_helper"

# IMP-915b24d21f4f — the WireGuard [Peer] field-set had THREE independent
# implementations (WgConfigRenderer's render loop, HubAndSpoke#build_peer_entry,
# FullMesh#build_peer_entry). The cost was realized twice: the missing PublicKey
# line (IMP-651ec6336654) existed only because the renderer re-implemented what
# build_peer_entry always carried, and an AllowedIPs enrichment divergence is
# live today (offer 019ffee4-8a76-7196-9d00-1648f37d23f7).
#
# Sdwan::PeerEntry is now the single builder. This file pins the builder itself;
# spec/integration/sdwan_peer_entry_single_source_spec.rb is the ratchet that
# keeps all three consumers routed through it.
#
# DATA-PLANE NOTE: `build` output is written verbatim into a node's live
# WireGuard config by the agent (state.go -> wg_applier.go), and `to_ini` output
# is pasted by an operator into a real WG client. Any change to what a given
# input renders is a data-plane change, not a cosmetic one.
RSpec.describe Sdwan::PeerEntry do
  # Doubles rather than records: build/to_ini are pure functions of the
  # endpoint tuples, and the real-record coverage lives in the consumer
  # specs (topology_compiler_spec, full_mesh_spec, wg_config_renderer_spec)
  # plus the cross-consumer integration ratchet.
  def peer_double(primary:, fallback: nil, id: "11111111-2222-3333-4444-555555555555")
    instance_double(Sdwan::Peer, id: id, primary_endpoint: primary, fallback_endpoint: fallback)
  end

  def key_double(public_key: "kFAKEPUBLICKEYPLACEHOLDERNOTREALKEYMATERIAL=")
    instance_double(Sdwan::PeerKey, public_key: public_key)
  end

  describe ".build" do
    it "carries the whole canonical field set" do
      entry = described_class.build(
        peer: peer_double(primary: { host: "203.0.113.10", port: 51_820, family: :v4 }),
        key: key_double, allowed_ips: [ "fd00::1/128" ], keepalive: 25
      )

      expect(entry.keys).to eq(described_class::FIELDS)
    end

    it "brackets an IPv6-literal endpoint and stringifies the family" do
      entry = described_class.build(
        peer: peer_double(primary: { host: "fd00:abcd:1::1", port: 51_820, family: :v6 }),
        key: key_double, allowed_ips: [], keepalive: 25
      )

      expect(entry[:endpoint]).to eq("[fd00:abcd:1::1]:51820")
      expect(entry[:endpoint_family]).to eq("v6")
    end

    it "leaves a hostname in the v6 column unbracketed (positive twin)" do
      entry = described_class.build(
        peer: peer_double(primary: { host: "edge.example.net", port: 51_820, family: :v6 }),
        key: key_double, allowed_ips: [], keepalive: 25
      )

      expect(entry[:endpoint]).to eq("edge.example.net:51820")
    end

    it "nils the endpoint fields when the peer advertises none" do
      entry = described_class.build(peer: peer_double(primary: nil), key: key_double,
                                    allowed_ips: [], keepalive: nil)

      expect(entry[:endpoint]).to be_nil
      expect(entry[:endpoint_family]).to be_nil
    end

    it "emits the v4 fallback as a structured hint with a stringified family" do
      entry = described_class.build(
        peer: peer_double(primary: { host: "fd00:abcd:1::1", port: 51_820, family: :v6 },
                          fallback: { host: "203.0.113.10", port: 51_820, family: :v4 }),
        key: key_double, allowed_ips: [], keepalive: 25
      )

      expect(entry[:fallback_endpoint]).to eq(host: "203.0.113.10", port: 51_820, family: "v4")
    end

    it "nils fallback_endpoint when the peer has no v4 alternative" do
      entry = described_class.build(
        peer: peer_double(primary: { host: "fd00:abcd:1::1", port: 51_820, family: :v6 }),
        key: key_double, allowed_ips: [], keepalive: 25
      )

      expect(entry[:fallback_endpoint]).to be_nil
    end

    it "passes allowed_ips and keepalive through verbatim (caller-supplied policy)" do
      # DELIBERATE: AllowedIPs stays an INJECTED input. The renderer's
      # device-scoped list and each strategy's per-view list differ by design
      # (and their divergence is tracked by its own offer) — one builder
      # cannot emit two AllowedIPs, so it emits neither and takes what it is
      # given. Same for keepalive, which HubAndSpoke nils toward spokes.
      entry = described_class.build(
        peer: peer_double(primary: { host: "203.0.113.10", port: 51_820, family: :v4 }),
        key: key_double, allowed_ips: [ "a", "b" ], keepalive: nil
      )

      expect(entry[:allowed_ips]).to eq([ "a", "b" ])
      expect(entry[:persistent_keepalive]).to be_nil
    end
  end

  describe ".user_device" do
    it "emits an endpoint-less, keepalive-less entry tagged as a user_device" do
      dev = instance_double(Sdwan::UserDevice, id: "dev-id", public_key: "kDEVICEPUBLICKEYPLACEHOLDER=",
                                               assigned_address: "fd00:abcd:1::9/128")

      entry = described_class.user_device(dev)

      expect(entry).to eq(
        peer_id: "dev-id",
        public_key: "kDEVICEPUBLICKEYPLACEHOLDER=",
        endpoint: nil,
        endpoint_family: nil,
        fallback_endpoint: nil,
        allowed_ips: [ "fd00:abcd:1::9/128" ],
        persistent_keepalive: nil,
        kind: "user_device"
      )
    end
  end

  describe ".to_ini" do
    let(:entry) do
      described_class.build(
        peer: peer_double(primary: { host: "fd00:abcd:1::1", port: 51_820, family: :v6 },
                          fallback: { host: "203.0.113.10", port: 51_820, family: :v4 }),
        key: key_double(public_key: "kFAKE="), allowed_ips: [ "fd00:abcd:1::/64", "10.50.0.0/16" ],
        keepalive: 25
      )
    end

    # BYTE-FOR-BYTE pin. These are the exact bytes an operator pastes into a
    # WireGuard client, column alignment included — the pre-consolidation
    # renderer emitted precisely this and must continue to.
    it "renders the exact section text for a v6 primary with a v4 fallback" do
      expect(described_class.to_ini(entry, hub_label: "edge-1")).to eq(<<~INI)
        [Peer]
        # Hub: edge-1 (v6 primary)
        PublicKey  = kFAKE=
        Endpoint   = [fd00:abcd:1::1]:51820
        # Fallback (IPv4): 203.0.113.10:51820
        AllowedIPs = fd00:abcd:1::/64, 10.50.0.0/16
        PersistentKeepalive = 25

      INI
    end

    it "omits the fallback comment when the peer has no v4 alternative" do
      v4_only = described_class.build(
        peer: peer_double(primary: { host: "203.0.113.10", port: 51_820, family: :v4 }),
        key: key_double(public_key: "kFAKE="), allowed_ips: [ "fd00:abcd:1::/64" ], keepalive: 25
      )

      expect(described_class.to_ini(v4_only, hub_label: "edge-2")).to eq(<<~INI)
        [Peer]
        # Hub: edge-2 (v4 primary)
        PublicKey  = kFAKE=
        Endpoint   = 203.0.113.10:51820
        AllowedIPs = fd00:abcd:1::/64
        PersistentKeepalive = 25

      INI
    end

    # Not reachable from WgConfigRenderer (it pre-filters hubs on
    # primary_endpoint), but to_ini is now a shared seam. An absent Endpoint
    # line is the WG-valid spelling of "this peer dials me" — emitting
    # "Endpoint   = " would be malformed config.
    it "omits the Endpoint line entirely for an endpoint-less entry" do
      endpointless = described_class.build(peer: peer_double(primary: nil), key: key_double(public_key: "kFAKE="),
                                           allowed_ips: [ "fd00::/64" ], keepalive: nil)

      ini = described_class.to_ini(endpointless, hub_label: nil)

      expect(ini).not_to match(/^Endpoint/)
      # Same reasoning for a nil keepalive: HubAndSpoke passes nil toward a
      # spoke, and "PersistentKeepalive = " is not a line WireGuard accepts.
      expect(ini).not_to match(/^PersistentKeepalive/)
      expect(ini).to include("PublicKey  = kFAKE=")
    end
  end
end
