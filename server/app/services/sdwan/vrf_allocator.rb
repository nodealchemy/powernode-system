# frozen_string_literal: true

# Sdwan::VrfAllocator — atomically assigns a per-host kernel routing
# table id (and the matching VRF master device name) for a (host,
# network) pair.
#
# Allocation rules:
#   * Range is 100..65535 (kernel ints); the lowest unused id wins.
#   * Reserved tables 0/253/254/255 are skipped (kernel-managed).
#   * The assignment is per-host — two different hosts can hold the
#     same table id; only the (host, table_id) tuple needs to be unique.
#   * A pre-existing assignment for the (host, network) pair is
#     returned idempotently so reconcile loops can call this repeatedly
#     without producing churn.
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
#   * #release! transitions the assignment to draining (default) or
#     removed (when force: true is passed). draining keeps the row in
#     the DB so its table_id is still considered "used" until the agent
#     reports the VRF gone, preventing premature reuse during
#     in-flight tunnel teardown.
#   * The 24-hour grace window mentioned in the plan is not enforced
#     here — Sdwan::HostVrfAssignment#mark_removed records removed_at,
#     and a future fleet-autonomy reaper will sweep rows older than 24h.
#
# Phase N1a of the in-house encrypted mesh overlay roadmap.
module Sdwan
  class VrfAllocator
    # Reserved IDs are the kernel-managed routing tables we MUST skip:
    #   0   = unspec     (kernel rejects programs that try to install)
    #   253 = default    (post-routing default destination)
    #   254 = main       (the standard routing table the kernel uses)
    #   255 = local      (loopback / per-iface broadcast)
    RESERVED_TABLE_IDS = ::Sdwan::HostVrfAssignment::RESERVED_TABLE_IDS
    TABLE_ID_MIN       = ::Sdwan::HostVrfAssignment::TABLE_ID_MIN
    TABLE_ID_MAX       = ::Sdwan::HostVrfAssignment::TABLE_ID_MAX
    SHORT_ID_MIN       = ::Sdwan::HostVrfAssignment::SHORT_ID_MIN
    SHORT_ID_MAX       = ::Sdwan::HostVrfAssignment::SHORT_ID_MAX

    class CapacityExhausted < StandardError; end
    class InvalidArguments < StandardError; end

    def self.allocate!(host:, network:)
      new(host: host, network: network).allocate!
    end

    def self.release!(assignment, force: false)
      new(host: assignment.node_instance, network: assignment.network)
        .release!(assignment, force: force)
    end

    def initialize(host:, network:)
      raise InvalidArguments, "host is required" if host.nil?
      raise InvalidArguments, "network is required" if network.nil?

      @host = host
      @network = network
    end

    # Returns the existing or newly minted Sdwan::HostVrfAssignment for
    # (@host, @network). Always idempotent.
    def allocate!
      ::Sdwan::HostVrfAssignment.transaction do
        # Lock all of the host's rows for the duration of this txn so
        # no concurrent allocator can race us into the same table_id.
        # FOR UPDATE on a SELECT that returns zero rows still acquires
        # a predicate-style lock when it shares a unique-index path,
        # but PostgreSQL gives us the simpler guarantee that any
        # subsequent INSERT we issue cannot collide with an INSERT
        # from another transaction holding rows for this host (because
        # the per-host unique index serializes them).
        existing = ::Sdwan::HostVrfAssignment
                     .lock("FOR UPDATE")
                     .where(node_instance_id: @host.id)
                     .to_a

        # Idempotent fast path: the (host, network) row already exists.
        same_network = existing.find { |row| row.sdwan_network_id == @network.id }
        if same_network
          # If the row was previously released (draining/removed) and the
          # caller wants it again, transition it back to active so the
          # compiler picks it up. Mirrors the AASM `readopt` event.
          same_network.readopt! if same_network.removed?
          return same_network
        end

        # Every row that the DB still carries holds its table_id and
        # vrf_name — including removed ones. Removed rows are kept for
        # the grace window (24h via a future reaper) so in-flight
        # tunnels using the freed table_id can drain before the same id
        # is reissued. Once a row is hard-deleted by the reaper the id
        # rejoins the candidate pool naturally on the next allocation.
        used_table_ids = existing.map(&:table_id).to_set
        used_short_ids = existing.map(&:short_id).compact.to_set
        table_id_candidate = first_available_table_id(used_table_ids)
        raise CapacityExhausted, "no free table_id in #{TABLE_ID_MIN}..#{TABLE_ID_MAX} on host #{@host.id}" unless table_id_candidate

        short_id_candidate = first_available_short_id(used_short_ids)
        raise CapacityExhausted, "no free short_id in #{SHORT_ID_MIN}..#{SHORT_ID_MAX} on host #{@host.id}" unless short_id_candidate

        ::Sdwan::HostVrfAssignment.create!(
          account_id: @network.account_id,
          node_instance: @host,
          network: @network,
          table_id: table_id_candidate,
          short_id: short_id_candidate,
          vrf_name: "sdwan-#{short_id_candidate}"
        )
      end
    rescue ActiveRecord::RecordNotUnique
      # A concurrent transaction beat us to the same (host, network)
      # row. Return the winner.
      existing = ::Sdwan::HostVrfAssignment.find_by!(
        node_instance_id: @host.id, sdwan_network_id: @network.id
      )
      existing.readopt! if existing.removed?
      existing
    end

    # Mark the assignment as draining (the default — preserves the
    # table_id while in-flight tunnels finish) or removed (when
    # force: true — releases the table_id immediately for reuse).
    def release!(assignment, force: false)
      ::Sdwan::HostVrfAssignment.transaction do
        if force
          assignment.mark_removed!
        else
          assignment.start_drain!
        end
      end
      assignment
    end

    private

    # Walks the candidate range in ascending order and returns the
    # lowest unused id that is not in `used_ids` and not reserved.
    # Returns nil if the entire range is exhausted (only possible if a
    # single host joins >65,400 networks, which is never).
    def first_available_table_id(used_ids)
      (TABLE_ID_MIN..TABLE_ID_MAX).each do |candidate|
        next if RESERVED_TABLE_IDS.include?(candidate)
        next if used_ids.include?(candidate)

        return candidate
      end
      nil
    end

    # Per-host counter for kernel iface names. Decoupled from network
    # UUID so iface names are stable, unique, and IFNAMSIZ-safe even
    # when two networks share a UUID prefix (common with UUIDv7 time
    # packing).
    def first_available_short_id(used_ids)
      (SHORT_ID_MIN..SHORT_ID_MAX).each do |candidate|
        return candidate unless used_ids.include?(candidate)
      end
      nil
    end
  end
end
