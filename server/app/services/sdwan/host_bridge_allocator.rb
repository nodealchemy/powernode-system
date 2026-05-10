# frozen_string_literal: true

# Sdwan::HostBridgeAllocator — atomically assigns a per-host short_id
# (and the matching kernel-visible bridge name) for a given host.
#
# Allocation rules:
#   * Range is 1..9999; the lowest unused id wins.
#   * The assignment is per-host — two different hosts can hold the
#     same short_id; only the (host, short_id) tuple needs to be unique.
#   * For Phase O1 every host runs exactly one platform-managed VM
#     bridge (the `pwnvbr0` replacement). The allocator therefore
#     returns the host's existing active/draining bridge idempotently
#     when one already exists, and only mints a new row when none does.
#   * Phase O2+ may add additional bridges per host (multi-tenant
#     isolation, dedicated K8s pod bridge, etc.) — the allocator
#     already supports that path via the `existing_kind:` argument.
#
# Concurrency model:
#   * SELECT ... FOR UPDATE on rows owned by the host inside a
#     transaction. PostgreSQL's row-level lock blocks any other
#     allocation request for the same host until we commit, so the
#     "scan + insert" sequence is atomic per-host.
#   * Cross-host allocations run in parallel — they touch disjoint
#     row sets, so the lock is never the bottleneck.
#
# Release model:
#   * #release! transitions the bridge to draining (default) or
#     removed (when force: true is passed). draining keeps the row in
#     the DB so its short_id is still considered "used" until the
#     agent reports the bridge gone, preventing premature reuse during
#     in-flight tap teardown.
#
# Phase O1 of the OVS+OVN dual-profile roadmap (lightweight track).
module Sdwan
  class HostBridgeAllocator
    SHORT_ID_MIN = ::Sdwan::HostBridge::SHORT_ID_MIN
    SHORT_ID_MAX = ::Sdwan::HostBridge::SHORT_ID_MAX

    class CapacityExhausted < StandardError; end
    class InvalidArguments < StandardError; end

    def self.allocate!(host:, kind: "linux", account: nil)
      new(host: host, kind: kind, account: account).allocate!
    end

    def self.release!(bridge, force: false)
      new(host: bridge.node_instance, kind: bridge.kind, account: bridge.account)
        .release!(bridge, force: force)
    end

    def initialize(host:, kind: "linux", account: nil)
      raise InvalidArguments, "host is required" if host.nil?
      raise InvalidArguments, "kind must be one of #{::Sdwan::HostBridge::KINDS.inspect}" \
        unless ::Sdwan::HostBridge::KINDS.include?(kind.to_s)

      @host = host
      @kind = kind.to_s
      # Bridges are scoped to the host's account by default. Callers can
      # pass an explicit account for cross-account bridge creation
      # (federation paths) — not used in Phase O1 but supported.
      @account = account || host.account
    end

    # Returns the existing or newly minted Sdwan::HostBridge for @host.
    # Always idempotent — repeated calls within the same Phase O1 single-
    # bridge-per-host model return the same row.
    def allocate!
      ::Sdwan::HostBridge.transaction do
        # Lock all of the host's rows for the duration of this txn so
        # no concurrent allocator can race us into the same short_id.
        # The per-host unique index serializes any subsequent INSERT
        # against an INSERT from another transaction holding rows for
        # this host.
        existing = ::Sdwan::HostBridge
                     .lock("FOR UPDATE")
                     .where(node_instance_id: @host.id)
                     .to_a

        # Idempotent fast path: a bridge of the requested kind already
        # exists on this host. Return it so reconcile loops don't churn.
        # We include removed rows so the caller can readopt them rather
        # than allocating a new short_id while the previous one is still
        # in-flight on the agent.
        same_kind = existing.find { |row| row.kind == @kind }
        if same_kind
          # If the row was previously released (removed) and the caller
          # wants it again, transition it back to active so the compiler
          # picks it up. Mirrors Sdwan::VrfAllocator's readopt path.
          same_kind.readopt! if same_kind.removed?
          return same_kind
        end

        # Every row that the DB still carries holds its short_id and
        # bridge_name — including removed ones. Removed rows are kept
        # for the grace window so in-flight taps using the freed bridge
        # can drain before the same id is reissued. Once a row is
        # hard-deleted by a future reaper the id rejoins the candidate
        # pool naturally on the next allocation.
        used_short_ids = existing.map(&:short_id).compact.to_set
        short_id_candidate = first_available_short_id(used_short_ids)
        raise CapacityExhausted,
              "no free short_id in #{SHORT_ID_MIN}..#{SHORT_ID_MAX} on host #{@host.id}" \
          unless short_id_candidate

        ::Sdwan::HostBridge.create!(
          account: @account,
          node_instance: @host,
          short_id: short_id_candidate,
          bridge_name: ::Sdwan::HostBridge.derive_bridge_name(short_id_candidate),
          kind: @kind
        )
      end
    rescue ActiveRecord::RecordNotUnique
      # A concurrent transaction beat us to a row for this host. Re-fetch
      # and return the winner; readopt if it was removed.
      existing = ::Sdwan::HostBridge.where(node_instance_id: @host.id, kind: @kind)
                                    .where.not(state: "removed")
                                    .first ||
                 ::Sdwan::HostBridge.where(node_instance_id: @host.id, kind: @kind)
                                    .first
      raise unless existing

      existing.readopt! if existing.removed?
      existing
    end

    # Mark the bridge as draining (the default — preserves the
    # short_id while in-flight taps finish) or removed (when
    # force: true — releases the short_id immediately for reuse).
    def release!(bridge, force: false)
      ::Sdwan::HostBridge.transaction do
        if force
          bridge.mark_removed!
        else
          bridge.start_drain!
        end
      end
      bridge
    end

    private

    # Walks the candidate range in ascending order and returns the
    # lowest unused id that is not in `used_ids`. Returns nil if the
    # entire range is exhausted (only possible if a single host runs
    # >9,999 platform-managed bridges, which is never).
    def first_available_short_id(used_ids)
      (SHORT_ID_MIN..SHORT_ID_MAX).each do |candidate|
        return candidate unless used_ids.include?(candidate)
      end
      nil
    end
  end
end
