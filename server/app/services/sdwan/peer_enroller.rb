# frozen_string_literal: true

# High-level "join a node-instance to a network" service. Wraps the steps
# operators / MCP tools / autonomy actions all need to perform consistently:
#
#   1. Validate the node-instance belongs to the network's account.
#   2. Create the Sdwan::Peer (which auto-allocates the /128 host address
#      via the Sdwan::Network before_validation callback).
#   3. Generate the genesis keypair via Sdwan::KeyDistributor.
#   4. Mirror the SDWAN capability into the existing System::NodeInstancePeer
#      row's `capabilities.sdwan` JSONB so the central peer registry sees
#      this membership.
#   5. Promote the network from `registered` to `active` if this is its
#      first peer.
#
# Returns the persisted Sdwan::Peer, or raises ActiveRecord::RecordInvalid
# on validation failure (the entire transaction rolls back).
#
# Slice 1 of the SDWAN plan.
module Sdwan
  class PeerEnroller
    class CrossAccountError < StandardError; end

    # Required:  network:, node_instance:
    # Optional:  publicly_reachable:, endpoint_host:, endpoint_port:,
    #            listen_port:, capabilities:
    def self.call(network:, node_instance:, **opts)
      new(network: network, node_instance: node_instance, **opts).call
    end

    def initialize(network:, node_instance:, publicly_reachable: false,
                   endpoint_host: nil, endpoint_host_v6: nil, endpoint_host_v4: nil,
                   endpoint_port: nil, listen_port: 51820, capabilities: {},
                   lan_subnets: [], bgp_route_reflector_client: false)
      @network = network
      @node_instance = node_instance
      @publicly_reachable = publicly_reachable
      @endpoint_host = endpoint_host
      @endpoint_host_v6 = endpoint_host_v6
      @endpoint_host_v4 = endpoint_host_v4
      @endpoint_port = endpoint_port
      @listen_port = listen_port
      @capabilities = capabilities
      # Slice 9a — declarative routing fields. lan_subnets is the
      # operator's source-of-truth for "external prefixes this peer can
      # reach"; the after_save callback on Sdwan::Peer materializes
      # Sdwan::SubnetAdvertisement rows immediately on create.
      @lan_subnets = Array(lan_subnets)
      @bgp_route_reflector_client = bgp_route_reflector_client
    end

    def call
      verify_account_alignment!

      ::Sdwan::Peer.transaction do
        peer = ::Sdwan::Peer.create!(
          network: @network,
          node_instance: @node_instance,
          account_id: @network.account_id,
          publicly_reachable: @publicly_reachable,
          endpoint_host: @endpoint_host,
          endpoint_host_v6: @endpoint_host_v6,
          endpoint_host_v4: @endpoint_host_v4,
          endpoint_port: @endpoint_port,
          listen_port: @listen_port,
          capabilities: @capabilities,
          lan_subnets: @lan_subnets,
          bgp_route_reflector_client: @bgp_route_reflector_client
        )

        ::Sdwan::KeyDistributor.ensure_key_for!(peer)

        promote_network!
        mirror_capability_to_node_instance_peer(peer)

        peer.reload
      end
    end

    private

    def verify_account_alignment!
      return if @node_instance.account_id == @network.account_id

      raise CrossAccountError,
            "node_instance #{@node_instance.id} belongs to a different account than network #{@network.id}"
    end

    def promote_network!
      return unless @network.status == "registered"

      @network.update!(status: "active")
    end

    # The central NodeInstancePeer row already exists for any running
    # instance. We don't overwrite it — we merge SDWAN-specific advertising
    # into its `capabilities.sdwan` JSONB so the rest of the platform
    # (mention picker, fleet autonomy, agent introspection) sees the
    # membership without needing to know about SDWAN tables.
    def mirror_capability_to_node_instance_peer(peer)
      central = ::System::NodeInstancePeer.find_by(node_instance_id: @node_instance.id)
      return unless central

      capabilities = central.capabilities.is_a?(Hash) ? central.capabilities.deep_dup : {}
      sdwan_block = capabilities["sdwan"] || {}
      networks = Array(sdwan_block["networks"])
      networks << {
        "network_id" => @network.id,
        "address"    => peer.assigned_address,
        "publicly_reachable" => peer.publicly_reachable
      }
      sdwan_block["networks"] = networks
      sdwan_block["wg_pubkey"] = peer.active_key&.public_key
      capabilities["sdwan"] = sdwan_block

      central.update!(capabilities: capabilities)
    end
  end
end
