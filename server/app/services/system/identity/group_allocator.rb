# frozen_string_literal: true

module System
  module Identity
    # System::Identity::GroupAllocator — atomically assigns a fleet-global
    # numeric GID to a Unix group name in the 70000..99999 range.
    #
    # Mirrors Sdwan::VrfAllocator's row-lock pattern: SELECT ... FOR
    # UPDATE on all live rows (so concurrent allocators serialize per
    # GID-space) plus an idempotent fast path that returns the existing
    # row when the same groupname is allocated again. The lock window is
    # short (microseconds) because the row count is bounded by the
    # allocation range (30k slots).
    #
    # Allocation strategy:
    #   1. Idempotent fast path — existing row in pending/active/draining
    #      state? Return it (transitioning draining → active via readopt
    #      if needed so re-declaring a recently-removed group reuses its
    #      old GID rather than minting a new one).
    #   2. Reserved table — ReservedIdentities::GROUPS lookup gives the
    #      group's stable platform-wide GID (e.g. "postgres" → 70110).
    #      The row is created at that exact GID. If a different name
    #      somehow already owns that GID, fall through to (3).
    #   3. Sequential fallback — lowest unused GID starting at
    #      SEQUENTIAL_FLOOR (71000). Excludes reserved GIDs entirely
    #      (so the reserved table can grow without disturbing
    #      sequentially-allocated IDs).
    #
    # The CapacityExhausted raise is theoretically reachable but in
    # practice the install would need ~30k distinct daemon names before
    # exhausting the range.
    class GroupAllocator
      class CapacityExhausted < StandardError; end
      class InvalidArguments  < StandardError; end

      def self.allocate!(groupname:)
        new(groupname: groupname).allocate!
      end

      def self.release!(group, force: false)
        new(groupname: group.groupname).release!(group, force: force)
      end

      def initialize(groupname:)
        raise InvalidArguments, "groupname is required" if groupname.blank?
        unless groupname.match?(::System::ServiceGroup::GROUPNAME_RX)
          raise InvalidArguments,
                "groupname #{groupname.inspect} does not match #{::System::ServiceGroup::GROUPNAME_RX.inspect}"
        end
        @groupname = groupname.to_s
      end

      def allocate!
        ::System::ServiceGroup.transaction do
          rows = ::System::ServiceGroup
                   .lock("FOR UPDATE")
                   .where(state: ::System::ServiceGroup::STATES - %w[removed])
                   .to_a

          existing = rows.find { |r| r.groupname == @groupname }
          if existing
            existing.readopt! if existing.draining? && existing.may_readopt?
            return existing
          end

          used_gids = rows.map(&:gid).to_set
          gid = pick_gid(used_gids)
          raise CapacityExhausted,
                "no free GID in #{::System::ServiceGroup::GID_MIN}..#{::System::ServiceGroup::GID_MAX}" unless gid

          ::System::ServiceGroup.create!(
            groupname:  @groupname,
            gid:        gid,
            state:      "active",
            applied_at: Time.current
          )
        end
      rescue ActiveRecord::RecordNotUnique
        # A concurrent transaction beat us. Return the winner.
        existing = ::System::ServiceGroup.live.find_by!(groupname: @groupname)
        existing.readopt! if existing.draining? && existing.may_readopt?
        existing
      end

      def release!(group, force: false)
        ::System::ServiceGroup.transaction do
          if force
            group.mark_removed!
          else
            group.start_drain!
          end
        end
        group
      end

      private

      # Reserved → sequential fallback. The reserved entry only "wins"
      # if its GID isn't already held by a live row under a different
      # name (which would only happen if an operator manually inserted
      # a colliding row — defensive guard, not a real-world hot path).
      def pick_gid(used_gids)
        reserved = ReservedIdentities.gid_for(@groupname)
        return reserved if reserved && !used_gids.include?(reserved)

        reserved_pool = ReservedIdentities.all_reserved_ids
        candidate = ReservedIdentities::SEQUENTIAL_FLOOR
        while candidate <= ::System::ServiceGroup::GID_MAX
          if !used_gids.include?(candidate) && !reserved_pool.include?(candidate)
            return candidate
          end
          candidate += 1
        end
        nil
      end
    end
  end
end
