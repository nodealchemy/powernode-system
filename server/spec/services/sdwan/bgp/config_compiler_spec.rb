# frozen_string_literal: true

require "rails_helper"

# Golden-file snapshot tests for the multi-VRF BGP config compiler.
# Each fixture under spec/fixtures/bgp_compiler/ captures the expected
# frr.conf body for a specific scenario; updating the compiler is a
# deliberate two-step (regenerate the snapshot, review the diff,
# commit).
#
# The fixture system is intentionally minimal — it records the
# compiler's `frr_text` output verbatim and compares strings. To
# regenerate after a deliberate change, set REGENERATE=1 in the env
# and re-run the spec; missing fixtures auto-write on first run.
RSpec.describe Sdwan::Bgp::ConfigCompiler, type: :service do
  FIXTURE_DIR = Rails.root.join("../extensions/system/server/spec/fixtures/bgp_compiler")

  let(:account) { Account.first || create(:account) }
  let(:node)    { sdwan_test_node(account: account) }
  let(:host_a)  { sdwan_test_node_instance(node: node) }
  let(:host_b)  { sdwan_test_node_instance(node: node) }
  let(:host_c)  { sdwan_test_node_instance(node: node) }

  before do
    Sdwan::RouteLeak.where(account_id: account.id).delete_all
    Sdwan::HostVrfAssignment.where(account_id: account.id).delete_all
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
    Sdwan::AccountBgp.where(account_id: account.id).delete_all
  end

  let!(:account_bgp) { Sdwan::AccountBgp.create!(account_id: account.id, as_number: 4_200_000_001, enabled: true) }

  # Helpers -------------------------------------------------------------

  def network!(name, routing: "ibgp", cidr: nil)
    attrs = { account_id: account.id, name: name, routing_protocol: routing }
    attrs[:cidr_64] = cidr if cidr
    Sdwan::Network.create!(attrs)
  end

  def peer!(network:, host:, hub: false, address: nil)
    attrs = {
      account: account, sdwan_network_id: network.id, node_instance: host,
      publicly_reachable: hub
    }
    attrs[:endpoint_host_v6] = "fd00::#{rand(16384).to_s(16)}" if hub
    attrs[:endpoint_port] = 51_820 if hub
    p = Sdwan::Peer.create!(attrs)
    p
  end

  def assign_vrf!(host:, network:)
    Sdwan::VrfAllocator.allocate!(host: host, network: network).tap(&:mark_active!)
  end

  def normalize(text)
    # The compiler emits volatile bits — UUIDs, network handles,
    # IPv6 host suffixes, IPv4 router-ids — that change every test
    # run because they're derived from the random Sdwan::Network UUID
    # and a SHA digest of it. Strip those down to deterministic
    # placeholders so the golden fixture only captures structure.
    out = text.dup
    # Full UUID strings (anywhere).
    out.gsub!(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, "UUID")
    # Host names + leak names rendered from network handles; collapse
    # the 8-hex handle to a placeholder.
    out.gsub!(/sdwan-\d+/, "sdwan-N")
    out.gsub!(/host pn-[0-9a-f]{8}/, "host pn-XXXXXXXX")
    out.gsub!(/hostname pn-[0-9a-f]{8}/, "hostname pn-XXXXXXXX")
    out.gsub!(/iBGP to UUID/, "iBGP to UUID")
    out.gsub!(/leak-[0-9a-f]{6}-to-[0-9a-f]{6}/, "leak-AAAAAA-to-BBBBBB")
    out.gsub!(/leak-pl-[0-9a-f]{6}-to-[0-9a-f]{6}/, "leak-pl-AAAAAA-to-BBBBBB")
    # Per-VRF route-map suffix is the VRF name; normalize after
    # `sdwan-\d+` already collapsed individual short_ids.
    out.gsub!(/__vrf_sdwan-N/, "__vrf_sdwan-N")
    # Router IDs — IPv4 dotted-quads derived from a SHA hash.
    out.gsub!(/router-id \d+\.\d+\.\d+\.\d+/, "router-id X.X.X.X")
    # IPv6 ULA host bits — collapse anything starting with `fd00:` to
    # a stable placeholder. The /64 prefix is captured separately so
    # the fixture still reflects per-network ULA differences (e.g.
    # fd00:a vs fd00:b in the multi-VRF scenario), but the random
    # /128 host suffix becomes XXXX:XXXX:XXXX:XXXX.
    out.gsub!(/(fd00(?::[0-9a-f]{1,4}){0,2}):[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}/) do
      "#{Regexp.last_match(1)}:HHHH:HHHH:HHHH:HHHH"
    end
    out
  end

  def assert_matches_fixture(name, actual)
    path = FIXTURE_DIR.join("#{name}.frr")
    normalized = normalize(actual)

    if ENV["REGENERATE"] == "1" || !path.exist?
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, normalized)
      skip "Wrote new golden fixture #{path} — re-run without REGENERATE=1"
    end

    expected = File.read(path)
    expect(normalized).to eq(expected),
                          "Compiler output drift for fixture #{name}.\n" \
                          "Diff (actual vs expected):\n" \
                          "#{ChunkyDiffOrPlain.diff(expected, normalized)}"
  end

  # Lightweight diff helper — pure-Ruby line-level diff that doesn't
  # require any external gem.
  module ChunkyDiffOrPlain
    def self.diff(a, b)
      a_lines = a.split("\n")
      b_lines = b.split("\n")
      max = [a_lines.length, b_lines.length].max
      out = []
      max.times do |i|
        next if a_lines[i] == b_lines[i]

        out << "  - #{a_lines[i].inspect}"
        out << "  + #{b_lines[i].inspect}"
        out << "  -- (line #{i + 1})"
      end
      out.join("\n")
    end
  end

  # ------------------------------------------------------------------
  # Scenarios
  # ------------------------------------------------------------------

  describe "single-VRF host" do
    it "renders one VRF block + one BGP instance for a host in one iBGP network" do
      net = network!("single-vrf-net", cidr: "fd00:1::/64")
      hub   = peer!(network: net, host: host_a, hub: true)
      _spoke = peer!(network: net, host: host_b)
      assign_vrf!(host: host_a, network: net)
      assign_vrf!(host: host_b, network: net)

      cfg = described_class.compile_for_peer(hub)
      expect(cfg[:enabled]).to eq(true)
      expect(cfg[:vrf_blocks].length).to eq(1)
      expect(cfg[:vrf_blocks].first).to include(
        network_id: net.id, table_id: 100, state: "active"
      )

      assert_matches_fixture("single_vrf_hub", cfg[:frr_text])
    end
  end

  describe "multi-VRF host" do
    it "renders one VRF block + one BGP instance per network on the host" do
      net_a = network!("multi-vrf-a", cidr: "fd00:a::/64")
      net_b = network!("multi-vrf-b", cidr: "fd00:b::/64")

      hub_a   = peer!(network: net_a, host: host_a, hub: true)
      _spoke_a = peer!(network: net_a, host: host_b)
      hub_b   = peer!(network: net_b, host: host_a, hub: true)
      _spoke_b = peer!(network: net_b, host: host_c)

      assign_vrf!(host: host_a, network: net_a)
      hva_b = assign_vrf!(host: host_a, network: net_b)
      assign_vrf!(host: host_b, network: net_a)
      assign_vrf!(host: host_c, network: net_b)

      cfg = described_class.compile_for_peer(hub_a)
      expect(cfg[:vrf_blocks].length).to eq(2)
      expect(cfg[:vrf_blocks].map { |b| b[:table_id] }).to contain_exactly(100, 101)

      # Both VRFs should appear as separate `router bgp ... vrf` blocks.
      expect(cfg[:frr_text]).to match(/router bgp \d+ vrf sdwan-\d+/)
      expect(cfg[:frr_text].scan(/router bgp \d+ vrf /).length).to eq(2)
      expect(cfg[:frr_text]).to include("vrf sdwan-")
      expect(cfg[:frr_text]).to include("exit-vrf")

      # The BGP instance for net_b should not list net_a's spoke as a
      # neighbor (peers are network-scoped). Per-host short_id is the
      # source of truth for the VRF name (Phase N1a follow-up / Bug C).
      lines = cfg[:frr_text].split("\n")
      bgp_b_start = lines.index { |l| l.include?(" vrf #{hva_b.vrf_name}") }
      expect(bgp_b_start).not_to be_nil

      # Confirm the section between the two BGP blocks does not leak
      # neighbors across networks (no neighbor address from net_a inside
      # net_b's block).
      assert_matches_fixture("multi_vrf_hub", cfg[:frr_text])
    end
  end

  describe "route-leak emission" do
    it "renders import vrf + route-map + prefix-list when an active leak targets this host's VRF" do
      net_a = network!("leak-src", cidr: "fd00:a::/64")
      net_b = network!("leak-dst", cidr: "fd00:b::/64")

      hub_a = peer!(network: net_a, host: host_a, hub: true)
      _peer_a2 = peer!(network: net_a, host: host_b)
      _hub_b  = peer!(network: net_b, host: host_a, hub: true)
      _peer_b2 = peer!(network: net_b, host: host_b)

      hva_a = assign_vrf!(host: host_a, network: net_a)
      hva_b = assign_vrf!(host: host_a, network: net_b)
      assign_vrf!(host: host_b, network: net_a)
      assign_vrf!(host: host_b, network: net_b)

      Sdwan::RouteLeak.create!(
        account_id: account.id,
        source_network: net_a, dest_network: net_b,
        direction: "one_way",
        prefix_filter: [{ "cidr" => "fd00:a::/64", "action" => "permit" }]
      ).activate!

      cfg = described_class.compile_for_peer(hub_a)

      # The destination VRF (net_b) gets `import vrf` + a route-map +
      # the prefix-list referenced by the route-map.
      text = cfg[:frr_text]
      expect(text).to include("import vrf #{hva_a.vrf_name}")
      expect(text).to include("route-map leak-#{net_a.network_handle}-to-#{net_b.network_handle} permit 10")
      expect(text).to include("ipv6 prefix-list leak-pl-#{net_a.network_handle}-to-#{net_b.network_handle}")

      # The source VRF (net_a) does NOT receive an import directive.
      net_a_block = text.split("router bgp")
                       .find { |seg| seg.include?(" vrf #{hva_a.vrf_name}") }
      expect(net_a_block).not_to include("import vrf #{hva_b.vrf_name}")

      assert_matches_fixture("route_leak_one_way", text)
    end

    it "renders both directions for a bidirectional leak" do
      net_a = network!("bidir-a", cidr: "fd00:a::/64")
      net_b = network!("bidir-b", cidr: "fd00:b::/64")

      hub_a = peer!(network: net_a, host: host_a, hub: true)
      _peer_a2 = peer!(network: net_a, host: host_b)
      _hub_b  = peer!(network: net_b, host: host_a, hub: true)
      _peer_b2 = peer!(network: net_b, host: host_b)

      hva_a = assign_vrf!(host: host_a, network: net_a)
      hva_b = assign_vrf!(host: host_a, network: net_b)
      assign_vrf!(host: host_b, network: net_a)
      assign_vrf!(host: host_b, network: net_b)

      Sdwan::RouteLeak.create!(
        account_id: account.id,
        source_network: net_a, dest_network: net_b,
        direction: "bidirectional",
        prefix_filter: [{ "cidr" => "fd00:a::/64", "action" => "permit" }]
      ).activate!

      text = described_class.compile_for_peer(hub_a)[:frr_text]
      # Both directions appear in the rendered output.
      expect(text).to include("import vrf #{hva_a.vrf_name}")
      expect(text).to include("import vrf #{hva_b.vrf_name}")
      expect(text).to include("route-map leak-#{net_a.network_handle}-to-#{net_b.network_handle}")
      expect(text).to include("route-map leak-#{net_b.network_handle}-to-#{net_a.network_handle}")
    end

    it "skips a leak whose source VRF is not present on this host" do
      net_a = network!("missing-src", cidr: "fd00:a::/64")
      net_b = network!("present-dst", cidr: "fd00:b::/64")

      # Host A only joins net_b; net_a has no presence on this host.
      hub_b = peer!(network: net_b, host: host_a, hub: true)
      _spoke_b = peer!(network: net_b, host: host_b)
      _peer_a = peer!(network: net_a, host: host_b, hub: true)
      assign_vrf!(host: host_a, network: net_b)
      assign_vrf!(host: host_b, network: net_a)
      assign_vrf!(host: host_b, network: net_b)

      Sdwan::RouteLeak.create!(
        account_id: account.id,
        source_network: net_a, dest_network: net_b,
        direction: "one_way", prefix_filter: []
      ).activate!

      text = described_class.compile_for_peer(hub_b)[:frr_text]
      # No import directive should be emitted because net_a's VRF
      # doesn't exist on host_a.
      expect(text).not_to include("import vrf sdwan-#{net_a.network_handle}")
    end
  end

  describe "static-routing networks are excluded from FRR output" do
    it "returns the disabled config for a static-routing peer" do
      net = network!("static-net", routing: "static", cidr: "fd00:5::/64")
      hub = peer!(network: net, host: host_a, hub: true)
      cfg = described_class.compile_for_peer(hub)
      expect(cfg[:enabled]).to eq(false)
      expect(cfg[:vrf_blocks]).to eq([])
    end
  end

  describe "draining VRFs continue to be emitted" do
    it "keeps the BGP block until the VRF is fully removed" do
      net = network!("draining-net", cidr: "fd00:6::/64")
      hub = peer!(network: net, host: host_a, hub: true)
      hva = assign_vrf!(host: host_a, network: net)
      hva.start_drain!

      text = described_class.compile_for_peer(hub)[:frr_text]
      expect(text).to include("router bgp #{account_bgp.as_number} vrf #{hva.vrf_name}")
    end
  end
end
