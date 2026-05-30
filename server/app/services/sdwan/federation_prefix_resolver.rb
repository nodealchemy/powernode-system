# frozen_string_literal: true

# Sdwan::FederationPrefixResolver — the canonical source of federated
# remote prefixes for the SDWAN data plane.
#
# A platform that federates with a remote Powernode install advertises a
# ULA prefix (`System::FederationPeer#remote_prefix_advertisement`, a
# /48, /56, or /64) that the remote owns. For cross-region reachability
# the local data plane must learn those prefixes so that:
#
#   * WireGuard AllowedIPs carries them (the overlay forwards packets
#     destined to a federated prefix toward the local hub egress), and
#   * eBGP announces them (iBGP networks propagate the federated prefix
#     across the route-reflector fabric).
#
# Prior to this resolver, `Sdwan::TopologyCompiler` hard-wired its
# `federation_resolver` to `->(_) { [] }`, so federated prefixes never
# entered the data plane — the federation peer rows existed but were
# inert. This service replaces that stub with a real lookup.
#
# Scope + selection rules:
#   * Account-scoped — a network only learns prefixes advertised by
#     federation peers belonging to the same account that owns the
#     network. Cross-account federation trust is a later phase.
#   * Liveness is owned by the model: which peers contribute is the
#     `System::FederationPeer.federation_prefix_contributing` scope,
#     composed from the model's own `reachable` (platform) / `live`
#     (sdwan_only) liveness scopes. The resolver does NOT re-list
#     statuses — it can't drift from the peer state machine. Concretely
#     that scope yields: `reachable` platform peers (enrolled / active /
#     degraded — the window FederationPeer#reachable? gates on) plus
#     `live` sdwan_only peers (which additionally includes `accepted`,
#     since sdwan_only peers stop at accepted and their whole purpose is
#     prefix advertisement). `proposed` peers and `suspended`/`revoked`
#     peers contribute nothing — the latter must never leak prefixes.
#   * Rows with a blank `remote_prefix_advertisement` are skipped —
#     nothing to advertise.
#   * De-duplicated by prefix so two peers advertising the same prefix
#     don't double-fold into AllowedIPs / BGP networks.
#
# Return shape (Array of Hashes, stable order by prefix):
#   [
#     {
#       federation_peer_id: "<uuid>",
#       remote_instance_id: "<uuid|nil>",
#       remote_instance_url: "https://peer.example/",
#       prefix: "fd12:3456:789a::/48",
#       status: "active",
#       peer_kind: "platform"
#     }, ...
#   ]
#
# The resolver is callable two ways to match the TopologyCompiler
# `federation_resolver` contract (a `->(network)` lambda):
#   * `Sdwan::FederationPrefixResolver.resolve(network)` — returns the
#     structured entries.
#   * `Sdwan::FederationPrefixResolver.prefixes_for(network)` — returns
#     just the prefix strings (what the data plane folds into AllowedIPs
#     and BGP `network` statements).
#
# Phase 3 (Federation & Multi-Site) — SDWAN data-plane completion.
module Sdwan
  class FederationPrefixResolver
    # Matches the TopologyCompiler `federation_resolver:` lambda contract.
    # Returns the structured federation entries for `network`'s account.
    def self.resolve(network)
      new(network).resolve
    end

    # Convenience for data-plane folding — just the de-duplicated prefix
    # strings, stable-ordered. Empty array when nothing federated.
    def self.prefixes_for(network)
      new(network).prefixes
    end

    def initialize(network)
      @network = network
    end

    def resolve
      return [] unless account_id

      entries = contributing_peers.filter_map do |peer|
        prefix = peer.remote_prefix_advertisement.to_s.strip
        next nil if prefix.blank?

        {
          federation_peer_id: peer.id,
          remote_instance_id: peer.remote_instance_id,
          remote_instance_url: peer.remote_instance_url,
          prefix: prefix,
          status: peer.status,
          peer_kind: peer.peer_kind
        }
      end

      # De-dup by prefix (first writer wins) then sort by prefix so the
      # compiled output is byte-stable across runs — the same idempotency
      # contract the OVN + topology compilers already honor.
      entries
        .uniq { |e| e[:prefix] }
        .sort_by { |e| e[:prefix] }
    end

    def prefixes
      resolve.map { |e| e[:prefix] }
    end

    private

    # Federation peers are not loaded when the network is un-persisted
    # (dry-run preview) or when the network has no resolvable account —
    # both collapse to "no federated prefixes".
    def account_id
      @account_id ||= @network&.account_id
    end

    # Liveness selection is delegated to the model's
    # `federation_prefix_contributing` scope (composed from the peer
    # state machine's own `reachable`/`live` scopes), so this resolver
    # can't drift from the status semantics FederationPeer owns. Here we
    # only layer on the resolver's own concerns: account scoping and
    # skipping rows with no prefix to advertise.
    def contributing_peers
      return ::System::FederationPeer.none unless defined?(::System::FederationPeer)

      ::System::FederationPeer
        .federation_prefix_contributing
        .where(account_id: account_id)
        .where.not(remote_prefix_advertisement: [ nil, "" ])
    end
  end
end
