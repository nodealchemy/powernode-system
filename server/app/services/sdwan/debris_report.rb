# frozen_string_literal: true

module Sdwan
  # Read-only enumeration of SDWAN overlay debris — test/smoke networks with
  # no live peer, peers whose node_instance is terminated, and revoked
  # federation rows. Pure data (no I/O, no destructive calls, no logging) so
  # it's fully unit-testable; server/lib/tasks/sdwan_debris.rake is the only
  # place that prints the report or (gated behind CONFIRM_DELETE=yes)
  # executes it.
  #
  # Classification criteria mirror the signal campaign 019f3458 increment 13
  # counted from live dev-DB data (9 networks / 8 dead peers / 2 revoked
  # federation rows, confirmed read-only against powernode_development):
  #   - Sdwan::Network         — safe_to_delete when it has no LIVE peer
  #     (every peer, if any, belongs to a terminated node_instance).
  #   - Sdwan::Peer            — safe_to_delete when node_instance is
  #     missing or terminated.
  #   - System::FederationPeer — safe_to_delete when status == "revoked"
  #     (the terminal state — System::FederationPeer::V1_TRANSITIONS has no
  #     outbound edges from "revoked").
  #
  # Sdwan::Network `has_many :peers, dependent: :destroy` (plus
  # firewall_rules/access_grants/virtual_ips/port_mappings/
  # subnet_advertisements/host_vrf_assignments, all `dependent: :destroy`)
  # — destroying a network CASCADES its own peer rows. The peer-level rows
  # below are listed for audit completeness; running both a network's
  # destroy AND its peers' destroy is redundant, not additive — pick one
  # per network.
  class DebrisReport
    Row = Struct.new(:kind, :id, :label, :safe_to_delete, :reason, :destroy_code, keyword_init: true)

    def self.call
      new.call
    end

    def call
      network_rows + peer_rows + federation_peer_rows
    end

    private

    def network_rows
      ::Sdwan::Network.includes(peers: :node_instance).order(:created_at).map do |network|
        peers = network.peers.to_a
        has_live_peer = peers.any? { |p| p.node_instance && p.node_instance.status != "terminated" }
        safe = !has_live_peer

        Row.new(
          kind: "Sdwan::Network",
          id: network.id,
          label: "name=#{network.name.inspect} slug=#{network.slug} peers=#{peers.size} " \
                 "created_at=#{network.created_at.iso8601}",
          safe_to_delete: safe,
          reason: safe ? "no live peer among #{peers.size} peer(s)" : "has a LIVE (non-terminated-instance) peer",
          destroy_code: "::Sdwan::Network.find(#{network.id.inspect}).destroy!  " \
                        "# cascades peers/keys/firewall_rules/virtual_ips/port_mappings/" \
                        "subnet_advertisements/host_vrf_assignments"
        )
      end
    end

    def peer_rows
      ::Sdwan::Peer.includes(:node_instance, :network).order(:created_at).map do |peer|
        ni = peer.node_instance
        safe = ni.nil? || ni.status == "terminated"

        Row.new(
          kind: "Sdwan::Peer",
          id: peer.id,
          label: "network=#{peer.network&.name} node_instance_id=#{peer.node_instance_id} " \
                 "node_instance_status=#{ni&.status || 'MISSING'}",
          safe_to_delete: safe,
          reason: safe ? "node_instance #{ni ? 'terminated' : 'missing'}" : "node_instance still #{ni.status}",
          destroy_code: "::Sdwan::Peer.find(#{peer.id.inspect}).destroy!  " \
                        "# redundant if the parent network is destroyed instead"
        )
      end
    end

    def federation_peer_rows
      ::System::FederationPeer.order(:created_at).map do |fp|
        safe = fp.status == "revoked"

        Row.new(
          kind: "System::FederationPeer",
          id: fp.id,
          label: "remote_instance_url=#{fp.remote_instance_url} status=#{fp.status} peer_kind=#{fp.peer_kind}",
          safe_to_delete: safe,
          reason: safe ? "status=revoked (terminal — no further transitions)" : "status=#{fp.status} — not terminal",
          destroy_code: "::System::FederationPeer.find(#{fp.id.inspect}).destroy!"
        )
      end
    end
  end
end
