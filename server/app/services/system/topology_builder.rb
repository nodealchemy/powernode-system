# frozen_string_literal: true

module System
  # Assembles the system-wide topology graph for an account: federation
  # peers + SDWAN networks + bridges + grant summaries, rendered as a
  # node/edge structure consumable by @xyflow/react.
  #
  # Node types:
  #   - self          (always one — the local platform)
  #   - peer-platform (FederationPeer with peer_kind="platform")
  #   - peer-sdwan    (FederationPeer with peer_kind="sdwan_only")
  #   - network       (Sdwan::Network)
  #
  # Edge types:
  #   - bridge        (FederationNetworkBridge: peer ⇄ network)
  #   - membership    (self → network — this platform is on every local network)
  #   - grant_summary (self → peer — aggregate grant count, label-only)
  #
  # Layout: **layered hierarchy** (Cisco / AWS / draw.io convention).
  #   - Self at top center (TIER_SELF_Y)
  #   - SDWAN networks as a horizontal mid-tier (TIER_NETWORK_Y),
  #     spaced evenly across the available width
  #   - Federation peers at the bottom (TIER_PEER_Y), grouped under
  #     their primary bridged network in vertical "lanes"; peers
  #     without a bridge land in an overflow lane to the right
  #
  # Edges use smoothstep routing (right-angle bends with rounded
  # corners) for the engineered/professional look. Grant-summary
  # edges skip from the top tier down to the peer tier — smoothstep
  # routes them around the network tier automatically.
  #
  # Plan reference: Decentralized Federation §K.5 + P4.5.7 + P4.5.9.
  class TopologyBuilder
    Result = Struct.new(:self_id, :self_label, :nodes, :edges, :stats,
                        keyword_init: true)

    # Tier Y coordinates (top → bottom). Spaced enough that smoothstep
    # edges between tiers don't crowd labels.
    TIER_SELF_Y    = 0
    TIER_NETWORK_Y = 200
    TIER_PEER_Y    = 440

    # Horizontal spacing.
    NETWORK_SPACING = 320  # gap between adjacent network columns
    PEER_SPACING    = 220  # gap between peers within a lane
    PEER_ROW_HEIGHT = 110  # gap when peers stack into multiple rows
    LANE_MAX_PER_ROW = 3   # at most this many peers per row in a lane

    class << self
      def build(account:)
        new(account: account).build
      end
    end

    def initialize(account:)
      @account = account
    end

    def build
      networks = ::Sdwan::Network.where(account_id: @account.id).to_a
      peers    = ::System::FederationPeer.where(account_id: @account.id).where.not(status: "revoked").to_a
      bridges  = ::System::FederationNetworkBridge.where(account_id: @account.id).to_a
      grants   = ::System::FederationGrant.active.where(account_id: @account.id).to_a

      nodes = []
      edges = []

      bridges_by_peer = bridges.group_by(&:federation_peer_id)
      grants_by_peer  = grants.group_by(&:federation_peer_id)

      # 1. Self node — top center
      nodes << {
        id: "self",
        type: "self",
        position: { x: 0, y: TIER_SELF_Y },
        data: {
          label: "This platform",
          subtitle: @account.try(:name) || "account:#{@account.id[0, 8]}",
          account_id: @account.id
        }
      }

      # 2. Network nodes — horizontal mid-tier row
      network_positions = layered_network_positions(networks.size)
      networks.each_with_index do |network, i|
        nodes << {
          id: "network-#{network.id}",
          type: "network",
          position: network_positions[i],
          data: {
            label: network.name,
            slug: network.slug,
            cidr_64: network.cidr_64,
            routing_protocol: network.routing_protocol,
            status: network.status
          }
        }
        edges << {
          id: "membership-self-#{network.id}",
          source: "self",
          target: "network-#{network.id}",
          type: "membership",
          data: { label: "member" },
          animated: false
        }
      end

      # 3. Peer nodes — bottom tier, grouped into lanes by primary bridged network
      peer_positions = layered_peer_positions(peers, networks, network_positions, bridges_by_peer)

      peers.each_with_index do |peer, i|
        peer_bridges = bridges_by_peer[peer.id] || []
        peer_grants  = grants_by_peer[peer.id] || []
        nodes << {
          id: "peer-#{peer.id}",
          type: peer.peer_kind == "platform" ? "peer-platform" : "peer-sdwan",
          position: peer_positions[i],
          data: {
            label: peer_label(peer),
            status: peer.status,
            peer_kind: peer.peer_kind,
            spawn_role: peer.spawn_role,
            remote_instance_url: peer.remote_instance_url,
            bridge_count: peer_bridges.size,
            active_bridge_count: peer_bridges.count(&:active?),
            grant_count: peer_grants.size,
            last_heartbeat_at: peer.last_heartbeat_at&.iso8601
          }
        }

        peer_bridges.each do |bridge|
          edges << {
            id: "bridge-#{bridge.id}",
            source: "peer-#{peer.id}",
            target: "network-#{bridge.sdwan_network_id}",
            type: "bridge",
            data: {
              label: bridge.state,
              bridge_id: bridge.id,
              state: bridge.state,
              activated_at: bridge.activated_at&.iso8601
            },
            animated: bridge.active?
          }
        end

        if peer_grants.any?
          edges << {
            id: "grant_summary-self-#{peer.id}",
            source: "self",
            target: "peer-#{peer.id}",
            type: "grant_summary",
            data: {
              label: "#{peer_grants.size} grant#{'s' unless peer_grants.size == 1}",
              grant_count: peer_grants.size,
              broad_scope_count: peer_grants.count { |g| (g.permission_scopes & %w[admin migrate]).any? },
              unrestricted_count: peer_grants.count(&:unrestricted?)
            }
          }
        end
      end

      assign_handle_slots!(nodes, edges)
      assign_center_y!(edges, nodes)

      Result.new(
        self_id: "self",
        self_label: "This platform",
        nodes: nodes,
        edges: edges,
        stats: {
          peer_count: peers.size,
          platform_peer_count: peers.count { |p| p.peer_kind == "platform" },
          sdwan_only_peer_count: peers.count { |p| p.peer_kind == "sdwan_only" },
          network_count: networks.size,
          bridge_count: bridges.size,
          active_bridge_count: bridges.count(&:active?),
          grant_count: grants.size,
          generated_at: Time.current.iso8601
        }
      )
    end

    private

    # Edge-type → [source_role, target_role] mapping. Roles encode
    # which side of which node the handle lives on:
    #   - source_bottom: handle on the source node's bottom edge
    #   - source_top:    handle on the source node's top edge
    #   - target_top:    handle on the target node's top edge
    #   - target_bottom: handle on the target node's bottom edge
    #
    # Membership + grant_summary flow DOWN the layered hierarchy
    # (self at top → network/peer below), so their source handle
    # exits self's bottom and enters the network/peer at its top.
    # Bridges flow UP (peer at bottom → network in middle), so
    # their source handle exits the peer's top and enters the
    # network at its bottom.
    EDGE_ROLES = {
      "membership"    => [ :source_bottom, :target_top ],
      "grant_summary" => [ :source_bottom, :target_top ],
      "bridge"        => [ :source_top,    :target_bottom ]
    }.freeze

    # Assigns each edge a `source_handle` + `target_handle` string id
    # (e.g., "s_bot_3") and stamps each node's data with the count of
    # handles it needs to render in each role. Slots within a (node,
    # role) group are ordered by the other endpoint's X coordinate so
    # edges fan out left-to-right rather than crossing.
    def assign_handle_slots!(nodes, edges)
      node_x = nodes.to_h { |n| [ n[:id], n[:position][:x] ] }

      source_groups = edges.group_by { |e| [ e[:source], EDGE_ROLES.fetch(e[:type])[0] ] }
      target_groups = edges.group_by { |e| [ e[:target], EDGE_ROLES.fetch(e[:type])[1] ] }

      source_groups.each do |(_node_id, role), group|
        group.sort_by! { |e| node_x[e[:target]] || 0 }
        group.each_with_index { |e, i| e[:source_handle] = handle_id(role, i) }
      end

      target_groups.each do |(_node_id, role), group|
        group.sort_by! { |e| node_x[e[:source]] || 0 }
        group.each_with_index { |e, i| e[:target_handle] = handle_id(role, i) }
      end

      counts_by_node = Hash.new { |h, k| h[k] = { source_top: 0, source_bottom: 0, target_top: 0, target_bottom: 0 } }
      source_groups.each { |(node_id, role), g| counts_by_node[node_id][role] = g.size }
      target_groups.each { |(node_id, role), g| counts_by_node[node_id][role] = g.size }

      nodes.each { |node| node[:data][:handle_counts] = counts_by_node[node[:id]] }
    end

    # Compact handle id form. The Position enum + role determines
    # which side of which node the handle lives on; the index
    # disambiguates among siblings on the same side.
    HANDLE_ROLE_PREFIX = {
      source_top: "s_top", source_bottom: "s_bot",
      target_top: "t_top", target_bottom: "t_bot"
    }.freeze

    def handle_id(role, index)
      "#{HANDLE_ROLE_PREFIX.fetch(role)}_#{index}"
    end

    # Per-edge-type horizontal routing bands. Each band gives that
    # edge family its own y-coordinate range for the horizontal
    # middle segment of its smoothstep path, so parallel edges in
    # the same family fan out vertically instead of stacking on one
    # line at the midpoint.
    #
    # Bands are tuned to live entirely between two tiers (no band
    # ever crosses through a node's vertical extent):
    #   - membership:    self → network. Band 70-130, fully inside
    #                    the 200px gap between self (y=0) and the
    #                    network tier (y=200).
    #   - grant_summary: self → peer. Band 60-100, ABOVE the network
    #                    tier so the horizontal middle doesn't visually
    #                    pass through a network node body. The vertical
    #                    drop from there to the peer tier may briefly
    #                    pass behind a network (xyflow renders edges
    #                    behind nodes, so it stays hidden).
    #   - bridge:        peer → network. Band 280-360, fully inside
    #                    the 240px gap between networks (y=200) and
    #                    peers (y=440).
    CENTER_Y_BANDS = {
      "membership"    => { base: 100, range: 60 },
      "grant_summary" => { base: 80,  range: 40 },
      "bridge"        => { base: 320, range: 80 }
    }.freeze

    # Assigns a `center_y` per edge inside edge[:data]. Edges of the
    # same type share a band; within the band, lanes are assigned in
    # target-X order so adjacent target columns get adjacent lanes
    # (visually clean fan pattern, no crossings within a family).
    def assign_center_y!(edges, nodes)
      node_x = nodes.to_h { |n| [ n[:id], n[:position][:x] ] }

      edges.group_by { |e| e[:type] }.each do |type, group|
        config = CENTER_Y_BANDS[type]
        next unless config  # unknown edge types: frontend falls back to default midpoint

        base, range = config[:base], config[:range]
        sorted = group.sort_by { |e| node_x[e[:target]] || 0 }
        count = sorted.size

        if count <= 1
          sorted.each { |e| e[:data][:center_y] = base }
          next
        end

        step = range.to_f / (count - 1)
        sorted.each_with_index do |e, i|
          offset = (i * step) - range / 2.0
          e[:data][:center_y] = (base + offset).round
        end
      end
    end


    def peer_label(peer)
      base = peer.name.presence || URI(peer.remote_instance_url).host rescue nil
      base ||= "peer-#{peer.id[0, 8]}"
      base.to_s
    end

    # Network nodes laid out on a single horizontal row, centered on x=0.
    def layered_network_positions(count)
      return [] if count.zero?
      half = (count - 1) / 2.0
      (0...count).map do |i|
        { x: ((i - half) * NETWORK_SPACING).round, y: TIER_NETWORK_Y }
      end
    end

    # Peer nodes grouped into a vertical lane under each network. Peers
    # with no bridge land in an "overflow" lane to the right of the
    # last network's column. Within a lane, peers fan out horizontally
    # up to LANE_MAX_PER_ROW per row, then wrap to a second row.
    def layered_peer_positions(peers, networks, network_positions, bridges_by_peer)
      network_index = networks.each_with_index.to_h { |n, i| [ n.id, i ] }

      # Group peer indices by their primary bridged network id (nil for unbridged).
      groups = Hash.new { |h, k| h[k] = [] }
      peers.each_with_index do |peer, idx|
        first_network = (bridges_by_peer[peer.id] || []).first&.sdwan_network_id
        key = network_index.key?(first_network) ? first_network : nil
        groups[key] << idx
      end

      positions = Array.new(peers.size)

      groups.each do |network_id, peer_indices|
        lane_center_x =
          if network_id && network_index[network_id]
            network_positions[network_index[network_id]][:x]
          else
            # Overflow lane: place to the right of the last network column
            last_x = (network_positions.last&.dig(:x)) || 0
            last_x + NETWORK_SPACING
          end

        peer_indices.each_with_index do |peer_idx, lane_pos|
          row = lane_pos / LANE_MAX_PER_ROW
          col_in_row = lane_pos % LANE_MAX_PER_ROW
          row_size = [ peer_indices.size - row * LANE_MAX_PER_ROW, LANE_MAX_PER_ROW ].min
          row_half = (row_size - 1) / 2.0
          positions[peer_idx] = {
            x: (lane_center_x + (col_in_row - row_half) * PEER_SPACING).round,
            y: TIER_PEER_Y + row * PEER_ROW_HEIGHT
          }
        end
      end

      positions
    end
  end
end
