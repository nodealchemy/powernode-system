# frozen_string_literal: true

module System
  module Identity
    # System::Identity::UserAllocator — atomically assigns a fleet-global
    # numeric UID to a Unix username in the 70000..99999 range, and
    # ensures the user has a primary System::ServiceGroup (auto-created
    # with the same name if the caller doesn't pass one explicitly).
    #
    # Pattern mirrors GroupAllocator exactly; the only twist is the
    # primary-group dependency. Callers either pass a pre-allocated
    # ServiceGroup as `primary_group:`, or omit it and let the allocator
    # auto-create a same-name group via GroupAllocator (debian's
    # USERGROUPS_ENAB=yes convention).
    #
    # The shell/home/gecos fields are *rendering hints* — the agent
    # writes them verbatim into /etc/passwd. Updating these on an
    # existing user row is intentional (the allocator's idempotent fast
    # path returns the existing user with the new hints applied) so
    # operators can adjust a daemon's home directory or shell by
    # re-importing the manifest without minting a new UID.
    class UserAllocator
      class CapacityExhausted < StandardError; end
      class InvalidArguments  < StandardError; end

      DEFAULT_SHELL = "/usr/sbin/nologin"

      def self.allocate!(username:, primary_group: nil, shell: DEFAULT_SHELL,
                         home: nil, gecos: "", supplementary_groups: [])
        new(
          username: username, primary_group: primary_group,
          shell: shell, home: home, gecos: gecos,
          supplementary_groups: supplementary_groups
        ).allocate!
      end

      def self.release!(user, force: false)
        new(username: user.username).release!(user, force: force)
      end

      def initialize(username:, primary_group: nil, shell: DEFAULT_SHELL,
                     home: nil, gecos: "", supplementary_groups: [])
        raise InvalidArguments, "username is required" if username.blank?
        unless username.match?(::System::ServiceUser::USERNAME_RX)
          raise InvalidArguments,
                "username #{username.inspect} does not match #{::System::ServiceUser::USERNAME_RX.inspect}"
        end
        @username             = username.to_s
        @primary_group        = primary_group
        @shell                = shell.presence || DEFAULT_SHELL
        @home                 = home.presence  || "/var/lib/#{@username}"
        @gecos                = gecos.to_s
        @supplementary_groups = Array(supplementary_groups)
      end

      def allocate!
        primary = resolve_primary_group!

        ::System::ServiceUser.transaction do
          rows = ::System::ServiceUser
                   .lock("FOR UPDATE")
                   .where(state: ::System::ServiceUser::STATES - %w[removed])
                   .to_a

          existing = rows.find { |r| r.username == @username }
          if existing
            existing.readopt! if existing.draining? && existing.may_readopt?
            apply_rendering_hints!(existing, primary)
            reconcile_supplementary_groups!(existing)
            return existing
          end

          used_uids = rows.map(&:uid).to_set
          uid = pick_uid(used_uids)
          raise CapacityExhausted,
                "no free UID in #{::System::ServiceUser::UID_MIN}..#{::System::ServiceUser::UID_MAX}" unless uid

          user = ::System::ServiceUser.create!(
            username:         @username,
            uid:              uid,
            primary_group:    primary,
            shell:            @shell,
            home:             @home,
            gecos:            @gecos,
            state:            "active",
            applied_at:       Time.current
          )
          reconcile_supplementary_groups!(user)
          user
        end
      rescue ActiveRecord::RecordNotUnique
        existing = ::System::ServiceUser.live.find_by!(username: @username)
        existing.readopt! if existing.draining? && existing.may_readopt?
        apply_rendering_hints!(existing, primary || existing.primary_group)
        reconcile_supplementary_groups!(existing)
        existing
      end

      def release!(user, force: false)
        ::System::ServiceUser.transaction do
          if force
            user.mark_removed!
          else
            user.start_drain!
          end
        end
        user
      end

      private

      def resolve_primary_group!
        return @primary_group if @primary_group.is_a?(::System::ServiceGroup)
        GroupAllocator.allocate!(groupname: @username)
      end

      def apply_rendering_hints!(user, primary)
        changed = {}
        changed[:shell] = @shell unless user.shell == @shell
        changed[:home]  = @home  unless user.home  == @home
        changed[:gecos] = @gecos unless user.gecos == @gecos
        changed[:primary_group_id] = primary.id if primary && user.primary_group_id != primary.id
        user.update!(changed) unless changed.empty?
      end

      def reconcile_supplementary_groups!(user)
        desired_groups = @supplementary_groups.map do |g|
          g.is_a?(::System::ServiceGroup) ? g : GroupAllocator.allocate!(groupname: g.to_s)
        end
        desired_ids = desired_groups.map(&:id).to_set
        existing_ids = user.user_group_memberships.pluck(:service_group_id).to_set

        (desired_ids - existing_ids).each do |gid|
          ::System::ServiceUserGroupMembership.create!(
            service_user_id: user.id, service_group_id: gid
          )
        end
        (existing_ids - desired_ids).each do |gid|
          user.user_group_memberships.where(service_group_id: gid).destroy_all
        end
      end

      def pick_uid(used_uids)
        reserved = ReservedIdentities.uid_for(@username)
        return reserved if reserved && !used_uids.include?(reserved)

        reserved_pool = ReservedIdentities.all_reserved_ids
        candidate = ReservedIdentities::SEQUENTIAL_FLOOR
        while candidate <= ::System::ServiceUser::UID_MAX
          if !used_uids.include?(candidate) && !reserved_pool.include?(candidate)
            return candidate
          end
          candidate += 1
        end
        nil
      end
    end
  end
end
