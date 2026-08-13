# frozen_string_literal: true

# Sdwan::OverlayAddressResolver — the single seam for "what is this
# NodeInstance's SDWAN overlay attachment?"
#
# Seven call sites previously inlined the same `Sdwan::Peer.where(
# node_instance_id: ...)` lookup with subtly different tails, which made
# the fleet's notion of "a workload's overlay identity" a copy-pasted
# query rather than a named concept:
#
#   DockerDaemonProvisionerService#resolve_overlay_address!     (address)
#   KubernetesClusterProvisionerService#resolve_overlay_address! (address)
#   KubernetesClusterProvisionerService — bootstrap_peer (API VIP network)
#   KubernetesClusterProvisionerService — joiner_peer    (VIP failover)
#   KubernetesClusterProvisionerService — new_peer       (VIP holder refresh)
#   Ai::Skills::DockerProvisionExecutor#build_plan              (peer row)
#   NodeApi::RuntimeConfigBuilder                               (peer network)
#   TopologyCompiler.derive_sdwan_encap_ip           (OVN Geneve encap IP)
#
# Three of the Kubernetes ones were byte-identical copies of the first
# two's query. This class names the concept without changing any of
# their behavior.
#
# Two entry points, deliberately NOT unified:
#
#   * `addressed_peer_for` / `address_for` order by `created_at` and
#     filter on a non-NULL `assigned_address` — the shape the three
#     address-consuming callers used.
#   * `attachment_peer_for` does neither, because RuntimeConfigBuilder
#     wants the peer's *network* (to derive the flannel interface name)
#     and never ordered its lookup. Kept separate purely to preserve
#     that call site's original query — NOT because the two resolve
#     differently: ActiveRecord's `.first` on an unordered relation
#     injects `ORDER BY id ASC` (finder_methods.rb#ordered_relation),
#     and ids are UUIDv7, so in practice it picks the same oldest peer
#     that `order(:created_at)` does. No spec pins a divergence.
#
# On the `assigned_address` NOT NULL filter: it is currently dead —
# the column is `null: false` in the schema AND presence-validated on
# Sdwan::Peer, so no row can fail it. It is retained because it was
# present in the original queries and because it keeps the intent
# readable if the column is ever relaxed; it costs one indexed
# predicate. Absence of a peer is therefore the only way these lookups
# come up empty.
#
# Errors are the caller's business: each address caller raises its own
# `MissingSdwanPeerError` constant, and at least one of them is rescued
# BY CLASS elsewhere (DockerProvisionExecutor rescues
# `DockerDaemonProvisionerService::MissingSdwanPeerError`). Raising a
# single shared error here would break that rescue, so the seam reports
# absence as `nil` and leaves the raise with the caller.
module Sdwan
  class OverlayAddressResolver
    # The oldest peer on this instance that carries an assigned overlay
    # address, or nil when the instance has no peer at all.
    def self.addressed_peer_for(node_instance)
      ::Sdwan::Peer.where(node_instance_id: node_instance.id)
                   .where.not(assigned_address: nil)
                   .order(:created_at)
                   .first
    end

    # The instance's overlay address with the CIDR prefix length
    # stripped (`fd00::1/128` → `fd00::1`), or nil when unattached.
    # Neither a Docker URL host nor an OVN encap IP tolerates the
    # trailing prefix length, so every caller stripped it.
    def self.address_for(node_instance)
      peer = addressed_peer_for(node_instance)
      return nil unless peer

      peer.assigned_address.to_s.split("/").first
    end

    # Any peer attached to this instance — the RuntimeConfigBuilder
    # shape, which wants the peer's network rather than its address.
    # No explicit order, preserving that call site's original query;
    # `.first` still resolves to ORDER BY id ASC (UUIDv7 ≈ oldest).
    def self.attachment_peer_for(node_instance)
      ::Sdwan::Peer.where(node_instance_id: node_instance.id).first
    end
  end
end
