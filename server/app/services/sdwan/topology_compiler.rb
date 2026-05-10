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
    #
    # Accepts un-persisted `Sdwan::Network` instances for dry-run rendering
    # (M1 ProvisioningTool plan-review surface). When the network has not
    # been saved, no peers exist yet — we skip the AR query and return an
    # empty Array so callers (e.g. TopologyRendererService) can synthesize
    # a hypothetical preview from the brief instead. No DB writes occur in
    # either branch.
    def self.compile_for_network(network, federation_resolver: ->(_) { [] })
      return [] unless network&.persisted?

      compiler = new(network, federation_resolver: federation_resolver, include_private_key: false)
      network.peers.includes(:keys).map { |peer| compiler.compile_peer_view(peer) }
    end

    # Phase O1 — per-host bridge list. One entry per platform-managed
    # bridge (Sdwan::HostBridge) on the instance. The agent's BridgeApplier
    # consumes this directly: each entry maps to one Linux (or, in Phase O2,
    # OVS) bridge that should exist on the host. Includes only compilable
    # rows (active or draining) so the agent doesn't apply pending plans
    # or chase removed rows. Returns [] when no bridges exist for the host.
    def self.host_bridges_for(instance)
      ipfix_payload = ipfix_payload_for(instance)
      ::Sdwan::HostBridge
        .for_host(instance)
        .compilable
        .order(:short_id)
        .map do |hb|
          entry = {
            host_bridge_id: hb.id,
            short_id: hb.short_id,
            name: hb.bridge_name,
            kind: hb.kind,
            state: hb.state,
            ipv4_cidr: hb.ipv4_cidr,
            ipv6_cidr: hb.ipv6_cidr
          }
          # Phase O5 — only OVS bridges support IPFIX. Linux bridges
          # ignore the field (their applier filters on Kind anyway).
          entry[:ipfix] = ipfix_payload if hb.kind == "ovs" && ipfix_payload
          entry
        end
    end

    # Phase O5 — per-host IPFIX collector intent. Returns the
    # exporter config the OvsBridgeApplier wires onto each ovs-kind
    # bridge, or nil when the account has no active IpfixCollector.
    # All ovs bridges on the same host export to the same collector
    # for now; multi-collector fan-out is a later refinement.
    def self.ipfix_payload_for(instance)
      collector = ::Sdwan::IpfixCollector
                    .for_account(instance.account)
                    .active
                    .order(:created_at)
                    .first
      return nil unless collector

      {
        collector_id: collector.id,
        targets: [collector.target_endpoint],
        sampling: collector.sampling_rate
      }
    end

    # Phase O3 — per-host OVN control payload. The on-host
    # ovn-controller daemon connects to the deployment's SB DB; this
    # returns the endpoints it needs (plus the NB endpoint for operator
    # tooling). Returns nil for lightweight hosts or accounts with no
    # active OVN deployment — the agent treats nil as "OVN not enabled,
    # skip the OVN reconcile step".
    def self.ovn_control_for(instance)
      return nil unless instance.network_profile == "heavyweight"

      deployment = ::Sdwan::OvnDeployment
                     .where(account_id: instance.account_id, status: "active")
                     .first
      return nil unless deployment

      {
        deployment_id: deployment.id,
        nb_db_endpoint: deployment.nb_db_endpoint,
        sb_db_endpoint: deployment.sb_db_endpoint,
        northd_host: deployment.northd_host,
        settings: deployment.settings,
        # The agent's DesiredOvnControl wire fields. EncapIp is the
        # host's SDWAN /128 — derived from any Sdwan::Peer the host
        # already has; if none yet, leave blank and the agent skips
        # ovn-controller startup until the next reconcile after a peer
        # exists.
        encap_type: "geneve",
        encap_ip: derive_sdwan_encap_ip(instance),
        chassis_name: instance.id
      }
    end

    # Derives the host's SDWAN overlay address (the /128 without prefix
    # length) for use as the OVN Geneve tunnel endpoint. Returns "" when
    # the host has no SDWAN peers yet — the agent's OvnControllerApplier
    # validates this and skips ovn-controller startup until populated.
    def self.derive_sdwan_encap_ip(instance)
      first_peer = ::Sdwan::Peer
                     .where(node_instance_id: instance.id)
                     .order(:created_at)
                     .first
      return "" unless first_peer&.assigned_address

      first_peer.assigned_address.to_s.split("/").first.to_s
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
        federation: @federation_resolver.call(@network), # [] in v1
        # Phase N0 — signed membership credential. Carries the canonical
        # JSON envelope, Ed25519 signature, constellation handle, and
        # validity window. The agent verifies this every reconcile;
        # missing or invalid MC = tunnel torn down for this tick.
        # ensure_fresh! is idempotent within the refresh window.
        mc_envelope: ::Sdwan::MembershipCredentialSigner.ensure_fresh!(peer: peer).to_wire
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
        public_key: key&.public_key,
        # Phase N1a — name of the VRF this iface should be bound to.
        # Empty when the host has no active HostVrfAssignment for this
        # network (transient state during enrollment); wg_applier
        # tolerates an empty value by leaving the iface in the default
        # routing context until the VRF lands on a later tick.
        vrf_name: vrf_name_for(peer)
      }
      # Inline the private key only on the node-side path. The operator
      # topology endpoint never sets include_private_key — that path serves
      # the UI, where private key material has no business appearing.
      if @include_private_key && key
        block[:private_key] = key.private_key
      end
      block
    end

    # Phase N1a — looks up the VRF the holder host is using for this
    # network. Returns "" when no active assignment exists yet.
    def vrf_name_for(peer)
      host_vrf_assignment_for(peer)&.vrf_name.to_s
    end

    # Centralized HVA lookup so interface_name and vrf_name_for share
    # the same source of truth. Cache per (host, network) per compiler
    # instance — multiple peers on the same network resolve to the
    # same HVA (one per host).
    def host_vrf_assignment_for(peer)
      return nil unless peer.node_instance_id
      @hva_cache ||= {}
      cache_key = [peer.node_instance_id, peer.sdwan_network_id]
      return @hva_cache[cache_key] if @hva_cache.key?(cache_key)
      @hva_cache[cache_key] = ::Sdwan::HostVrfAssignment.where(
        node_instance_id: peer.node_instance_id,
        sdwan_network_id: peer.sdwan_network_id,
        state: %w[active draining]
      ).first
    end

    def interface_name(peer)
      hva = host_vrf_assignment_for(peer)
      # When a HostVrfAssignment exists (iBGP networks), derive the
      # iface name from its short_id — single source of truth that's
      # collision-free, IFNAMSIZ-safe, and stable across compiler runs.
      return hva.wg_iface_name if hva

      # Fallback for static-only networks where no HVA is allocated.
      # Single network per host in this path means no collision risk.
      "wg-sdwan-#{@network.network_handle}"
    end

    # Slice 9b — VIP CIDRs that THIS peer should advertise locally. Static
    # mode picks the primary holder; anycast mode includes every holder.
    # The agent's vip_applier configures each CIDR on the local loopback.
    def vips_held_by(peer)
      return [] unless @network.respond_to?(:virtual_ips)

      # Phase N1a — peer's host always uses the same VRF for this
      # network's traffic, so we can resolve it once per call.
      vrf_name = vrf_name_for(peer)

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
          advertised_local_pref: vip.advertised_local_pref,
          # Phase N1a — tells vip_applier which per-VRF dummy iface to
          # configure the VIP on (`dummy-sdwan-<handle>` bound to the
          # VRF master). Empty value causes vip_applier to skip this
          # entry rather than installing on the global loopback.
          vrf_name: vrf_name
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
