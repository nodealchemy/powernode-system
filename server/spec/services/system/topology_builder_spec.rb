# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::TopologyBuilder, type: :service do
  let(:account) { create(:account) }

  describe ".build" do
    it "always returns a self node at the top-center origin" do
      result = described_class.build(account: account)
      self_node = result.nodes.find { |n| n[:id] == "self" }
      expect(self_node).to be_present
      expect(self_node[:type]).to eq("self")
      # Self anchors the top tier at x=0, y=TIER_SELF_Y.
      expect(self_node[:position]).to eq(x: 0, y: described_class::TIER_SELF_Y)
    end

    it "returns zero edges when no networks/peers/bridges/grants exist" do
      result = described_class.build(account: account)
      expect(result.edges).to be_empty
      expect(result.stats[:peer_count]).to eq(0)
      expect(result.stats[:network_count]).to eq(0)
    end

    context "with SDWAN networks" do
      it "adds a network node + membership edge per network" do
        net1 = create(:sdwan_network, account: account)
        net2 = create(:sdwan_network, account: account)
        result = described_class.build(account: account)

        network_nodes = result.nodes.select { |n| n[:type] == "network" }
        expect(network_nodes.size).to eq(2)
        expect(network_nodes.map { |n| n[:id] }).to match_array([ "network-#{net1.id}", "network-#{net2.id}" ])

        membership_edges = result.edges.select { |e| e[:type] == "membership" }
        expect(membership_edges.size).to eq(2)
        expect(membership_edges.all? { |e| e[:source] == "self" }).to be true
      end

      it "places network nodes on the mid-tier row (Cisco/AWS layered layout)" do
        create_list(:sdwan_network, 4, account: account)
        result = described_class.build(account: account)
        network_nodes = result.nodes.select { |n| n[:type] == "network" }
        # All networks share the same Y (TIER_NETWORK_Y).
        ys = network_nodes.map { |n| n[:position][:y] }.uniq
        expect(ys).to eq([ described_class::TIER_NETWORK_Y ])
        # X-coordinates are evenly spaced + centered around 0.
        xs = network_nodes.map { |n| n[:position][:x] }.sort
        diffs = xs.each_cons(2).map { |a, b| b - a }.uniq
        expect(diffs).to eq([ described_class::NETWORK_SPACING ])
        expect((xs.first + xs.last).abs).to be <= 1  # centered
      end
    end

    context "with federation peers" do
      it "renders platform peers and sdwan-only peers with distinct types" do
        platform_peer = create(:system_federation_peer, :active, account: account)
        sdwan_peer = create(:system_federation_peer, account: account, peer_kind: "sdwan_only", status: "accepted")
        result = described_class.build(account: account)

        platform_node = result.nodes.find { |n| n[:id] == "peer-#{platform_peer.id}" }
        sdwan_node = result.nodes.find { |n| n[:id] == "peer-#{sdwan_peer.id}" }
        expect(platform_node[:type]).to eq("peer-platform")
        expect(sdwan_node[:type]).to eq("peer-sdwan")
      end

      it "excludes revoked peers" do
        peer = create(:system_federation_peer, :active, account: account)
        peer.update_columns(status: "revoked")
        result = described_class.build(account: account)
        expect(result.nodes.map { |n| n[:id] }).not_to include("peer-#{peer.id}")
      end
    end

    context "with bridges" do
      it "adds a bridge edge per FederationNetworkBridge" do
        peer = create(:system_federation_peer, :active, account: account)
        net = create(:sdwan_network, account: account)
        bridge = create(:system_federation_network_bridge, :active,
                        account: account, federation_peer: peer, sdwan_network: net)

        result = described_class.build(account: account)
        bridge_edges = result.edges.select { |e| e[:type] == "bridge" }
        expect(bridge_edges.size).to eq(1)
        edge = bridge_edges.first
        expect(edge[:source]).to eq("peer-#{peer.id}")
        expect(edge[:target]).to eq("network-#{net.id}")
        expect(edge[:data][:bridge_id]).to eq(bridge.id)
        expect(edge[:data][:state]).to eq("active")
        expect(edge[:animated]).to be true
      end

      it "marks non-active bridges as non-animated" do
        peer = create(:system_federation_peer, :active, account: account)
        net = create(:sdwan_network, account: account)
        create(:system_federation_network_bridge,
               account: account, federation_peer: peer, sdwan_network: net)

        result = described_class.build(account: account)
        bridge_edges = result.edges.select { |e| e[:type] == "bridge" }
        expect(bridge_edges.first[:animated]).to be false
      end
    end

    context "with grants" do
      it "adds a grant_summary edge per peer with active grants" do
        peer = create(:system_federation_peer, :active, account: account)
        create_list(:system_federation_grant, 3,
                    account: account, federation_peer: peer,
                    grantor_user: create(:user, account: account))

        result = described_class.build(account: account)
        summary_edges = result.edges.select { |e| e[:type] == "grant_summary" }
        expect(summary_edges.size).to eq(1)
        edge = summary_edges.first
        expect(edge[:source]).to eq("self")
        expect(edge[:target]).to eq("peer-#{peer.id}")
        expect(edge[:data][:grant_count]).to eq(3)
        expect(edge[:data][:label]).to eq("3 grants")
      end

      it "skips peers with no active grants" do
        peer = create(:system_federation_peer, :active, account: account)
        result = described_class.build(account: account)
        summary_edges = result.edges.select { |e| e[:type] == "grant_summary" }
        expect(summary_edges).to be_empty
      end

      it "annotates broad-scope + unrestricted grant counts in edge data" do
        peer = create(:system_federation_peer, :active, account: account)
        grantor = create(:user, account: account)
        # 1 read-only restricted
        create(:system_federation_grant, account: account, federation_peer: peer,
                                          grantor_user: grantor,
                                          permission_scopes: %w[read],
                                          node_instance_ids: %w[some-instance])
        # 1 admin scope, unrestricted
        create(:system_federation_grant, account: account, federation_peer: peer,
                                          grantor_user: grantor,
                                          permission_scopes: %w[read admin])

        result = described_class.build(account: account)
        edge = result.edges.find { |e| e[:type] == "grant_summary" }
        expect(edge[:data][:broad_scope_count]).to eq(1)
        expect(edge[:data][:unrestricted_count]).to eq(1)
      end
    end

    context "with multi-handle slot assignment" do
      it "assigns a source_handle + target_handle to every edge" do
        net1 = create(:sdwan_network, account: account)
        net2 = create(:sdwan_network, account: account)
        peer = create(:system_federation_peer, :active, account: account)
        create(:system_federation_network_bridge, :active,
               account: account, federation_peer: peer, sdwan_network: net1)
        create(:system_federation_network_bridge, :active,
               account: account, federation_peer: peer, sdwan_network: net2)

        result = described_class.build(account: account)
        expect(result.edges).to all(include(:source_handle, :target_handle))
      end

      it "stamps each node with handle_counts in its data" do
        create(:sdwan_network, account: account)
        result = described_class.build(account: account)
        result.nodes.each do |node|
          expect(node[:data][:handle_counts]).to include(
            :source_top, :source_bottom, :target_top, :target_bottom
          )
        end
      end

      it "orders incoming bridges into target_bottom slots by source peer X" do
        net = create(:sdwan_network, account: account)
        # Two peers will sit in the same lane under `net`; assign bridges from each.
        peer_a = create(:system_federation_peer, :active, account: account)
        peer_b = create(:system_federation_peer, :active, account: account)
        create(:system_federation_network_bridge, :active,
               account: account, federation_peer: peer_a, sdwan_network: net)
        create(:system_federation_network_bridge, :active,
               account: account, federation_peer: peer_b, sdwan_network: net)

        result = described_class.build(account: account)
        bridges = result.edges.select { |e| e[:type] == "bridge" }
        peer_x = result.nodes.to_h { |n| [ n[:id], n[:position][:x] ] }
        sorted = bridges.sort_by { |b| peer_x.fetch(b[:source]) }
        expect(sorted.map { |b| b[:target_handle] }).to eq([ "t_bot_0", "t_bot_1" ])
      end

      it "spreads self's membership edges across distinct source_bottom slots" do
        create_list(:sdwan_network, 4, account: account)
        result = described_class.build(account: account)
        memberships = result.edges.select { |e| e[:type] == "membership" }
        handles = memberships.map { |e| e[:source_handle] }
        expect(handles.uniq.size).to eq(4)
        expect(handles).to all(start_with("s_bot_"))
      end

      it "assigns each edge a per-type center_y lane (no horizontal-line pile-up)" do
        create_list(:sdwan_network, 4, account: account)
        result = described_class.build(account: account)
        memberships = result.edges.select { |e| e[:type] == "membership" }

        # All membership edges live inside the 70-130 band, with
        # distinct y-lanes for each edge.
        center_ys = memberships.map { |e| e[:data][:center_y] }
        band = described_class::CENTER_Y_BANDS["membership"]
        lo, hi = band[:base] - band[:range] / 2, band[:base] + band[:range] / 2
        expect(center_ys).to all(be_between(lo, hi))
        expect(center_ys.uniq.size).to eq(memberships.size)
      end

      it "assigns single-edge families the band base center_y (no spread needed)" do
        create(:sdwan_network, account: account)
        result = described_class.build(account: account)
        membership = result.edges.find { |e| e[:type] == "membership" }
        # Only one membership edge → lands exactly on the band base
        # (any other y would be arbitrary asymmetry).
        expect(membership[:data][:center_y]).to eq(described_class::CENTER_Y_BANDS["membership"][:base])
      end
    end

    describe "stats" do
      it "tallies counts across all entity kinds" do
        create_list(:sdwan_network, 2, account: account)
        platform_peer = create(:system_federation_peer, :active, account: account)
        sdwan_peer = create(:system_federation_peer, account: account, peer_kind: "sdwan_only", status: "accepted")
        create(:system_federation_network_bridge, :active,
               account: account, federation_peer: platform_peer)
        create(:system_federation_grant, account: account, federation_peer: platform_peer,
                                          grantor_user: create(:user, account: account))

        stats = described_class.build(account: account).stats
        expect(stats[:network_count]).to eq(3)  # 2 + 1 created by the bridge factory
        expect(stats[:peer_count]).to eq(2)
        expect(stats[:platform_peer_count]).to eq(1)
        expect(stats[:sdwan_only_peer_count]).to eq(1)
        expect(stats[:bridge_count]).to eq(1)
        expect(stats[:active_bridge_count]).to eq(1)
        expect(stats[:grant_count]).to eq(1)
        expect(stats[:generated_at]).to be_present
      end
    end
  end
end
