# frozen_string_literal: true

# Compiles a per-peer view of an SDWAN network — the desired-state envelope
# that the agent reads from /api/v1/system/node_api/config/sdwan and applies
# via wgctrl-go.
#
# The compiler is topology-pluggable: it picks a strategy class based on
# the network's settings["topology_strategy"] value (defaulting to
# "hub_and_spoke" in v1). Strategies are responsible for emitting the
# `peers:` list — interface metadata is identical across strategies.
#
# Output shape (per peer):
#   {
#     interface: {
#       name: "wg-sdwan-<8>",
#       address: "fd...:.../128",
#       listen_port: 51820,
#       mtu: 1420,
#       private_key_ref: { peer_key_id: "<uuid>" }   # agent fetches via key_distributor
#     },
#     peers: [
#       {
#         peer_id: "<uuid>",
#         public_key: "...",
#         endpoint: "host:port"  | nil,
#         allowed_ips: ["fd...:.../128", "fd...:.../64"],
#         persistent_keepalive: 25
#       }
#     ],
#     federation: []  # forward-compat; always [] in v1
#   }
#
# Slice 1 of the SDWAN plan.
module Sdwan
  class TopologyCompiler
    DEFAULT_MTU = 1420
    DEFAULT_PERSISTENT_KEEPALIVE = 25

    class UnknownStrategy < StandardError; end

    def self.compile_for_peer(peer, federation_resolver: ->(_) { [] }, include_private_key: false)
      new(peer.network, federation_resolver: federation_resolver, include_private_key: include_private_key)
        .compile_peer_view(peer)
    end

    # Compiles all peers in a network at once — useful for the per-network
    # ActionCable broadcast and for previewing topology changes. Never
    # includes private-key material (this is the operator-facing path).
    def self.compile_for_network(network, federation_resolver: ->(_) { [] })
      compiler = new(network, federation_resolver: federation_resolver, include_private_key: false)
      network.peers.includes(:keys).map { |peer| compiler.compile_peer_view(peer) }
    end

    def initialize(network, federation_resolver:, include_private_key: false)
      @network = network
      @federation_resolver = federation_resolver
      @include_private_key = include_private_key
      @strategy = strategy_for(network)
    end

    def compile_peer_view(peer)
      {
        peer_id: peer.id,
        interface: interface_block(peer),
        peers: @strategy.peers_for(peer),
        firewall: ::Sdwan::FirewallCompiler.compile_for_peer(peer),
        # Slice 7b — hub DNAT rules. Empty for spokes; populated for
        # hubs where operators have declared port mappings. Agent's
        # nat_applier.go writes this to nft as a sister chain to the
        # firewall ruleset.
        nat: ::Sdwan::NatCompiler.compile_for_peer(peer),
        # Slice 9b — VIPs this peer currently holds. The agent's vip_applier
        # configures each cidr on its loopback interface so kernel routing
        # delivers traffic destined to the VIP to local processes.
        vips_held: vips_held_by(peer),
        # Slice 9c — BGP config when network.routing_protocol == "ibgp".
        # When static, the compiler returns { enabled: false } so the
        # agent disables FRR for this network. The frr_applier consumes
        # this block.
        bgp: ::Sdwan::Bgp::ConfigCompiler.compile_for_peer(peer),
        federation: @federation_resolver.call(@network) # [] in v1
      }
    end

    private

    def interface_block(peer)
      key = peer.active_key
      block = {
        name: interface_name(peer),
        address: peer.assigned_address,
        listen_port: peer.listen_port,
        mtu: @network.settings.fetch("mtu", DEFAULT_MTU),
        private_key_ref: key ? { peer_key_id: key.id } : nil,
        public_key: key&.public_key
      }
      # Inline the private key only on the node-side path. The operator
      # topology endpoint never sets include_private_key — that path serves
      # the UI, where private key material has no business appearing.
      if @include_private_key && key
        block[:private_key] = key.private_key
      end
      block
    end

    def interface_name(peer)
      "wg-sdwan-#{@network.id.to_s.delete('-').first(8)}"
    end

    # Slice 9b — VIP CIDRs that THIS peer should advertise locally. Static
    # mode picks the primary holder; anycast mode includes every holder.
    # The agent's vip_applier configures each CIDR on the local loopback.
    def vips_held_by(peer)
      return [] unless @network.respond_to?(:virtual_ips)

      @network.virtual_ips.where(state: %w[active pending]).filter_map do |vip|
        holders = Array(vip.holder_peer_ids)
        next nil if holders.empty?
        # Static mode: only the primary (head of the list) holds.
        # Anycast mode: every entry holds.
        next nil unless vip.anycast? ? holders.include?(peer.id) : holders.first == peer.id

        {
          virtual_ip_id: vip.id,
          name: vip.name,
          cidr: vip.cidr,
          anycast: vip.anycast?,
          advertised_med: vip.advertised_med,
          advertised_local_pref: vip.advertised_local_pref
        }
      end
    end

    def strategy_for(network)
      name = network.settings.fetch("topology_strategy", "hub_and_spoke")
      class_name = "Sdwan::TopologyStrategies::#{name.camelize}"
      class_name.constantize.new(network: network)
    rescue NameError
      raise UnknownStrategy, "unknown SDWAN topology strategy: #{name.inspect}"
    end
  end
end
