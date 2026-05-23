# frozen_string_literal: true

module System
  module Identity
    # System::Identity::ReaperService — sweeps draining ServiceUser /
    # ServiceGroup rows that have outlived their 24h grace window AND
    # have no remaining ModuleUserDeclaration referencing them. Mirrors
    # the deferred-reaper pattern from Sdwan::VrfAllocator's release
    # lifecycle.
    #
    # Why 24 hours: long enough that an in-flight live-migration or
    # NFS-mount handoff doesn't race the GID/UID release; short enough
    # that recycled IDs don't sit stale forever. Matches the comment
    # in Sdwan::HostVrfAssignment.
    #
    # Safety guards on `reap_groups`: a group is preserved if any live
    # user still has it as primary OR is a supplementary member, even
    # if no module declares it. This protects against the case where a
    # group's last *declaring* module is uninstalled but a user (whose
    # own declarer is still installed) still references it.
    class ReaperService
      GRACE_WINDOW = 24.hours

      Result = Struct.new(:ok?, :reaped_users, :reaped_groups, :ran_at,
                          keyword_init: true)

      def self.run!
        new.run!
      end

      def run!
        Result.new(
          ok?: true,
          reaped_users:  reap_users,
          reaped_groups: reap_groups,
          ran_at:        Time.current
        )
      end

      private

      def reap_users
        candidates = ::System::ServiceUser.draining
                       .where("draining_at < ?", GRACE_WINDOW.ago)
        count = 0
        candidates.find_each do |user|
          next if ::System::ModuleUserDeclaration.where(service_user_id: user.id).exists?
          # StorageAssignment FK keeps the user alive: an NFS volume's
          # anonuid references this UID, so removing the user (freeing
          # the UID for reuse) would silently break file ownership on
          # disk. Operator must explicitly reassign the storage's owner
          # via system_assign_storage_owner before this user can be reaped.
          next if ::System::StorageAssignment.where(service_user_id: user.id).exists?
          user.mark_removed!
          count += 1
        end
        count
      end

      def reap_groups
        candidates = ::System::ServiceGroup.draining
                       .where("draining_at < ?", GRACE_WINDOW.ago)
        count = 0
        candidates.find_each do |group|
          next if ::System::ModuleUserDeclaration.where(service_group_id: group.id).exists?
          next if ::System::ServiceUser.live.exists?(primary_group_id: group.id)
          next if ::System::ServiceUserGroupMembership
                     .where(service_group_id: group.id)
                     .joins(:service_user)
                     .where(system_service_users: { state: %w[pending active draining] })
                     .exists?
          # StorageAssignment.shared_group_id reference keeps the group
          # alive for the same reason — NFS export's anongid is this
          # group's GID. Reaping would orphan group ownership on disk.
          next if ::System::StorageAssignment.where(shared_group_id: group.id).exists?
          group.mark_removed!
          count += 1
        end
        count
      end
    end
  end
end
