# frozen_string_literal: true

# Inverse of Sdwan::PeerEnroller — removes a node-instance's SDWAN overlay
# membership. Wraps the steps consistently:
#
#   1. Find the Sdwan::Peer for this node_instance (optionally scoped to a
#      specific network, when a node-instance could plausibly belong to more
#      than one overlay).
#   2. Unmirror the capability from the central System::NodeInstancePeer row's
#      `capabilities.sdwan` JSONB (the inverse of PeerEnroller's
#      `mirror_capability_to_node_instance_peer`).
#   3. Destroy the Sdwan::Peer row (cascades to its keys + subnet_advertisements
#      via `dependent: :destroy`, same as Sdwan::Executors::DeletePeer).
#
# Idempotent / safe to call on a node-instance with no SDWAN membership at
# all — a no-op returning an empty array. Auto-detach call sites (provision
# terminate/recycle) are best-effort and must never raise; callers that need
# raise-on-failure semantics can rescue Sdwan::Peer errors directly.
module Sdwan
  class PeerDetacher
    # Required: node_instance:
    # Optional: network: — scope detachment to a single overlay; omitted
    #           detaches ALL of this node_instance's SDWAN memberships.
    # Returns the array of destroyed Sdwan::Peer ids (empty if none existed).
    def self.call(node_instance:, network: nil)
      new(node_instance: node_instance, network: network).call
    end

    def initialize(node_instance:, network: nil)
      @node_instance = node_instance
      @network = network
    end

    def call
      detached = peers.map do |peer|
        ::Sdwan::Peer.transaction do
          unmirror_capability_from_node_instance_peer(peer)
          peer.destroy!
        end
        peer.id
      end

      # IMP-2f34679b6b73 — the inverse of PeerEnroller#flag_multi_ibgp_host!.
      # A host that drops back to a single iBGP network is no longer in the
      # shape where an unscoped BGP poll is unattributable, and a flag left
      # standing would keep the sensor escalating for a condition that ended.
      #
      # Sdwan::Peer's after_commit(on: :destroy) already covers this — and has
      # to, because Sdwan::Executors::DeletePeer and the Network cascade never
      # come through here. Kept anyway so the detach seam reads symmetrically
      # with the enroll seam; the flagger is idempotent.
      ::Sdwan::MultiIbgpHostFlagger.refresh!(node_instance: @node_instance) if detached.any?

      detached
    end

    private

    def peers
      scope = ::Sdwan::Peer.where(node_instance_id: @node_instance.id)
      scope = scope.where(sdwan_network_id: @network.id) if @network
      scope.to_a
    end

    # Inverse of PeerEnroller#mirror_capability_to_node_instance_peer — drops
    # this peer's network entry out of the central NodeInstancePeer row's
    # `capabilities.sdwan.networks` array so the rest of the platform stops
    # seeing this membership. Clears the whole `sdwan` block when it was the
    # last membership.
    def unmirror_capability_from_node_instance_peer(peer)
      central = ::System::NodeInstancePeer.find_by(node_instance_id: @node_instance.id)
      return unless central

      capabilities = central.capabilities.is_a?(Hash) ? central.capabilities.deep_dup : {}
      sdwan_block = capabilities["sdwan"]
      return unless sdwan_block.is_a?(Hash)

      networks = Array(sdwan_block["networks"]).reject { |n| n.is_a?(Hash) && n["network_id"] == peer.sdwan_network_id }

      if networks.empty?
        capabilities.delete("sdwan")
      else
        sdwan_block["networks"] = networks
        capabilities["sdwan"] = sdwan_block
      end

      central.update!(capabilities: capabilities)
    end
  end
end
