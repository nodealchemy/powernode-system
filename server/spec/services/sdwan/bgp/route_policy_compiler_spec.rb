# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sdwan::Bgp::RoutePolicyCompiler, type: :service do
  let(:account) { Account.first || create(:account) }

  before do
    # AccountBgp first — it may reference a RoutePolicy via
    # default_route_policy_id, so clear it before destroying policies.
    Sdwan::AccountBgp.where(account_id: account.id).delete_all
    Sdwan::RoutePolicy.where(account_id: account.id).destroy_all
    Sdwan::Network.where(account_id: account.id).destroy_all
    Sdwan::Configuration.where(account_id: account.id).destroy_all
  end

  let!(:network) { Sdwan::Network.create!(account_id: account.id, name: "rpc-net-#{SecureRandom.hex(3)}", routing_protocol: "ibgp") }
  let!(:node) { sdwan_test_node(account: account) }
  let!(:inst1) { sdwan_test_node_instance(node: node) }
  let!(:inst2) { sdwan_test_node_instance(node: node) }
  let!(:peer1) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst1,
                        publicly_reachable: true, endpoint_host_v6: "2001:db8::1", endpoint_port: 51820)
  end
  let!(:peer2) do
    Sdwan::Peer.create!(account: account, sdwan_network_id: network.id, node_instance: inst2,
                        publicly_reachable: false)
  end

  describe "empty output when no policies match" do
    it "returns zeroed lists" do
      out = described_class.compile_for_peer(peer1)
      expect(out[:prefix_lists]).to be_empty
      expect(out[:route_maps]).to be_empty
      expect(out[:neighbor_assignments]).to be_empty
    end
  end

  describe "v4 + v6 prefix_in match emits two prefix-lists" do
    let!(:policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-#{SecureRandom.hex(3)}",
        scope: "account", direction: "import",
        statements: [
          { "match" => { "prefix_in" => [ "10.0.0.0/8", "fd00::/16" ] },
            "action" => { "type" => "accept", "set_local_pref" => 200 } }
        ]
      )
    end

    it "splits v4 and v6 into separate prefix-lists" do
      out = described_class.compile_for_peer(peer1)
      expect(out[:prefix_lists]).to include(a_string_matching(/permit 10\.0\.0\.0\/8/))
      expect(out[:ipv6_prefix_lists]).to include(a_string_matching(/permit fd00::\/16/))
    end

    it "applies the policy to every other peer's neighbor assignment" do
      out = described_class.compile_for_peer(peer1)
      neighbor_addr = peer2.assigned_address.to_s.split("/").first
      expect(out[:neighbor_assignments][neighbor_addr]).to include(import: a_string_matching(/-import\z/))
    end

    it "emits a route-map clause with set local-preference 200" do
      out = described_class.compile_for_peer(peer1)
      expect(out[:route_maps].join).to include("set local-preference 200")
    end
  end

  describe "as_path_regex match → as-path access-list + match line" do
    let!(:policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-asp-#{SecureRandom.hex(3)}",
        scope: "account", direction: "import",
        statements: [
          { "match" => { "as_path_regex" => "^4200000000_" },
            "action" => { "type" => "reject" } }
        ]
      )
    end

    it "emits an as-path access-list referenced by match line" do
      out = described_class.compile_for_peer(peer1)
      expect(out[:as_path_lists]).to include(a_string_matching(/permit \^4200000000_/))
      expect(out[:route_maps].join).to include("match as-path")
    end

    it "uses 'deny' as the route-map terminator for action.type=reject" do
      out = described_class.compile_for_peer(peer1)
      first_clause = out[:route_maps].first
      expect(first_clause).to match(/route-map .* deny 10/)
    end
  end

  describe "default-deny tail" do
    let!(:policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-tail-#{SecureRandom.hex(3)}",
        scope: "account", direction: "import",
        statements: [ { "match" => {}, "action" => { "type" => "accept" } } ]
      )
    end

    it "appends an explicit final deny clause" do
      out = described_class.compile_for_peer(peer1)
      tail = out[:route_maps].last
      expect(tail).to match(/route-map .* deny \d+/)
    end
  end

  describe "single applicable policy keeps the direct (non-combined) map name" do
    let!(:policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-single-#{SecureRandom.hex(3)}",
        scope: "account", direction: "import",
        statements: [
          { "match" => { "prefix_in" => [ "10.0.0.0/8" ] },
            "action" => { "type" => "accept" } }
        ]
      )
    end

    it "uses the per-policy map name directly without an nbr- combined wrapper" do
      out = described_class.compile_for_peer(peer1)
      neighbor_addr = peer2.assigned_address.to_s.split("/").first
      name = out[:neighbor_assignments][neighbor_addr][:import]
      expect(name).to eq("#{policy.slug}-import")
      expect(name).not_to start_with("nbr-")
    end
  end

  describe "multiple same-direction applicable policies compose into one combined route-map" do
    # An account-scoped baseline allowlist filter AND a peer-scoped
    # policy, both inbound. The pre-fix compiler dropped the account
    # filter (last-write-wins kept only the peer policy) → silent leak.
    let!(:account_policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-acct-#{SecureRandom.hex(3)}",
        scope: "account", direction: "import",
        statements: [
          { "match" => { "prefix_in" => [ "10.0.0.0/8" ] },
            "action" => { "type" => "accept", "set_local_pref" => 100 } }
        ]
      )
    end
    let!(:peer_policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-peer-#{SecureRandom.hex(3)}",
        scope: "peer", scope_resource_id: peer1.id, direction: "import",
        statements: [
          { "match" => { "prefix_in" => [ "10.1.0.0/16" ] },
            "action" => { "type" => "accept", "set_local_pref" => 200 } }
        ]
      )
    end

    let(:neighbor_addr) { peer2.assigned_address.to_s.split("/").first }
    let(:out) { described_class.compile_for_peer(peer1) }
    let(:acct_map) { "#{account_policy.slug}-import" }
    let(:peer_map) { "#{peer_policy.slug}-import" }

    it "attaches a combined nbr-<addr>-import map instead of dropping the account policy" do
      combined = out[:neighbor_assignments][neighbor_addr][:import]
      expect(combined).to match(/\Anbr-.*-import\z/)
      # combined name must be FRR-valid — no colons from IPv6 ULA addrs
      expect(combined).not_to include(":")
    end

    it "renders the combined map into route_maps calling BOTH policy maps in narrowing order" do
      combined_name = out[:neighbor_assignments][neighbor_addr][:import]
      combined_block = out[:route_maps].find { |rm| rm.start_with?("route-map #{combined_name} ") }
      expect(combined_block).not_to be_nil

      expect(combined_block).to include("call #{acct_map}")
      expect(combined_block).to include("call #{peer_map}")
      # narrowing order: account (broadest) called before peer (narrowest)
      expect(combined_block.index("call #{acct_map}")).to be < combined_block.index("call #{peer_map}")
      # on-match next BETWEEN clauses, exactly once, and NOT after the last call
      expect(combined_block.scan(/on-match next/).length).to eq(1)
      expect(combined_block).to match(/call #{Regexp.escape(peer_map)}\n!/)
    end

    it "still renders both per-policy maps so the combined map can call them" do
      joined = out[:route_maps].join("\n")
      expect(joined).to include("route-map #{acct_map} ")
      expect(joined).to include("route-map #{peer_map} ")
    end
  end

  describe "scope=peer policies attach only to the matching peer" do
    let!(:peer_policy) do
      Sdwan::RoutePolicy.create!(
        account_id: account.id, name: "p-scoped-#{SecureRandom.hex(3)}",
        scope: "peer", scope_resource_id: peer1.id,
        direction: "export",
        statements: [
          { "match" => { "prefix_in" => [ "192.0.2.0/24" ] },
            "action" => { "type" => "accept" } }
        ]
      )
    end

    it "is included in compile output for the matching peer" do
      out = described_class.compile_for_peer(peer1)
      neighbor_addr = peer2.assigned_address.to_s.split("/").first
      expect(out[:neighbor_assignments][neighbor_addr]).to include(export: a_string_matching(/-export\z/))
    end

    it "is not applied to a non-matching peer" do
      out = described_class.compile_for_peer(peer2)
      assignments = out[:neighbor_assignments]
      assignments.each_value do |a|
        # peer2's compile output should NOT carry peer1's peer-scoped policy
        # as an inbound route-map for any neighbor.
        expect(a[:export]).not_to match(/p-scoped/) if a[:export]
      end
    end
  end

  describe "AccountBgp#default_route_policy is emitted as the broadest account-wide baseline filter" do
    # Before this fix the column was settable but NO compiler read it:
    # an operator who set an account default route policy got ZERO
    # enforcement (routes accepted/advertised unfiltered — silent gap).
    # It must now be folded into every neighbor's composition in its
    # direction, as the BROADEST (first) clause, treated account-wide
    # regardless of the referenced policy's own scope field.
    let(:neighbor_addr) { peer2.assigned_address.to_s.split("/").first }

    context "with a default policy AND a separate account policy (both import)" do
      # default policy is declared scope=peer (pointing at the OTHER
      # peer) to prove it is applied account-wide regardless of its own
      # scope, and ahead of the genuine account-scoped policy.
      let!(:default_policy) do
        Sdwan::RoutePolicy.create!(
          account_id: account.id, name: "p-default-#{SecureRandom.hex(3)}",
          scope: "peer", scope_resource_id: peer2.id, direction: "import",
          statements: [
            { "match" => { "prefix_in" => [ "203.0.113.0/24" ] },
              "action" => { "type" => "accept", "set_local_pref" => 50 } }
          ]
        )
      end
      let!(:account_policy) do
        Sdwan::RoutePolicy.create!(
          account_id: account.id, name: "p-acct-#{SecureRandom.hex(3)}",
          scope: "account", direction: "import",
          statements: [
            { "match" => { "prefix_in" => [ "10.0.0.0/8" ] },
              "action" => { "type" => "accept", "set_local_pref" => 100 } }
          ]
        )
      end
      let!(:account_bgp) do
        create(:sdwan_account_bgp, account: account, default_route_policy: default_policy)
      end

      let(:out) { described_class.compile_for_peer(peer1) }
      let(:default_map) { "#{default_policy.slug}-import" }
      let(:acct_map) { "#{account_policy.slug}-import" }

      it "composes a combined map that CALLS the default policy's map FIRST (broadest), before the account policy" do
        combined_name = out[:neighbor_assignments][neighbor_addr][:import]
        expect(combined_name).to match(/\Anbr-.*-import\z/)

        combined_block = out[:route_maps].find { |rm| rm.start_with?("route-map #{combined_name} ") }
        expect(combined_block).not_to be_nil
        expect(combined_block).to include("call #{default_map}")
        expect(combined_block).to include("call #{acct_map}")
        # default (account-wide baseline) is the broadest → called first.
        expect(combined_block.index("call #{default_map}")).to be < combined_block.index("call #{acct_map}")
      end

      it "renders the default policy's own per-policy route-map so the combined map can call it" do
        expect(out[:route_maps].join("\n")).to include("route-map #{default_map} ")
      end
    end

    context "when the default policy is the ONLY applicable policy" do
      let!(:default_policy) do
        Sdwan::RoutePolicy.create!(
          account_id: account.id, name: "p-onlydefault-#{SecureRandom.hex(3)}",
          scope: "peer", scope_resource_id: peer2.id, direction: "import",
          statements: [
            { "match" => { "prefix_in" => [ "198.51.100.0/24" ] },
              "action" => { "type" => "accept" } }
          ]
        )
      end
      let!(:account_bgp) do
        create(:sdwan_account_bgp, account: account, default_route_policy: default_policy)
      end

      it "is still applied to every neighbor in its direction (direct map name, no combined wrapper)" do
        out = described_class.compile_for_peer(peer1)
        name = out[:neighbor_assignments][neighbor_addr][:import]
        expect(name).to eq("#{default_policy.slug}-import")
        expect(name).not_to start_with("nbr-")
        expect(out[:route_maps].join("\n")).to include("route-map #{default_policy.slug}-import ")
      end
    end

    context "when the default policy is also independently applicable (account-scoped)" do
      # The SAME policy is both the account default AND returned by
      # applicable_to — it must be applied ONCE, not double-called.
      let!(:default_policy) do
        Sdwan::RoutePolicy.create!(
          account_id: account.id, name: "p-dupe-#{SecureRandom.hex(3)}",
          scope: "account", direction: "import",
          statements: [
            { "match" => { "prefix_in" => [ "10.0.0.0/8" ] },
              "action" => { "type" => "accept" } }
          ]
        )
      end
      let!(:account_bgp) do
        create(:sdwan_account_bgp, account: account, default_route_policy: default_policy)
      end

      it "applies the policy exactly once (direct map name, not a doubled combined map)" do
        out = described_class.compile_for_peer(peer1)
        name = out[:neighbor_assignments][neighbor_addr][:import]
        expect(name).to eq("#{default_policy.slug}-import")
        expect(name).not_to start_with("nbr-")
      end
    end

    context "when the default policy is disabled" do
      let!(:default_policy) do
        Sdwan::RoutePolicy.create!(
          account_id: account.id, name: "p-disabled-#{SecureRandom.hex(3)}",
          scope: "peer", scope_resource_id: peer2.id, direction: "import",
          enabled: false,
          statements: [
            { "match" => { "prefix_in" => [ "192.0.2.0/24" ] },
              "action" => { "type" => "accept" } }
          ]
        )
      end
      let!(:account_bgp) do
        create(:sdwan_account_bgp, account: account, default_route_policy: default_policy)
      end

      it "is NOT applied (no enforcement) — output stays empty when nothing else matches" do
        out = described_class.compile_for_peer(peer1)
        expect(out[:neighbor_assignments]).to be_empty
        expect(out[:route_maps]).to be_empty
      end
    end

    context "when no default policy is set" do
      let!(:account_bgp) { create(:sdwan_account_bgp, account: account) }

      it "behaves exactly as before (no default folded in)" do
        out = described_class.compile_for_peer(peer1)
        expect(out[:neighbor_assignments]).to be_empty
        expect(out[:route_maps]).to be_empty
      end
    end
  end
end
