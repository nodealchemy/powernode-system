# frozen_string_literal: true

module Ai
  module Tools
    # MCP surface for StorageAssignment ownership management. Operators
    # use these actions to: (a) assign or change the owner of a storage
    # mount, (b) audit who owns what across the fleet, and (c) inspect
    # / retry the chown task that follows an ownership change.
    #
    # The fleet-wide Unix-identity system gives every service a stable
    # numeric UID (see System::ServiceUser); this tool wires that into
    # the storage layer so an NFS export's anonuid maps to the actual
    # service that should own the files on disk. Ownership changes
    # trigger an on-node chown task automatically — operators don't
    # need to ssh in to update file ownership manually.
    #
    # Plan reference: ~/.claude/plans/storage-assignment-owner-refactor.md
    class SystemStorageOwnerTool < BaseTool
      REQUIRED_PERMISSION = "system.storage.read"

      ACTION_PERMISSIONS = {
        "system_assign_storage_owner"               => "system.storage.assignments.update",
        "system_list_storage_assignments_by_owner"  => "system.storage.read",
        "system_storage_chown_status"               => "system.storage.read",
        "system_storage_chown_retry"                => "system.storage.assignments.update"
      }.freeze

      def self.definition
        {
          name: "system_storage_owner",
          description: "StorageAssignment ownership management — assign, audit, inspect chown progress, retry failed chowns",
          parameters: {
            action:                  { type: "string",  required: true },
            storage_assignment_id:   { type: "string",  required: false },
            owner_kind:              { type: "string",  required: false, description: "service_user | operator | nobody | root" },
            service_user_username:   { type: "string",  required: false },
            shared_group_groupname:  { type: "string",  required: false },
            node_instance_id:        { type: "string",  required: false },
            chown_state:             { type: "string",  required: false },
            force_complete:          { type: "boolean", required: false }
          }
        }
      end

      def self.action_definitions
        {
          "system_assign_storage_owner" => {
            description: <<~DESC.squish,
              Set the owner of a StorageAssignment. For owner_kind=service_user,
              supply service_user_username — the platform looks up (or
              auto-allocates via Identity::UserAllocator) the matching
              ServiceUser. For operator/nobody/root, only owner_kind is
              required. Optional shared_group_groupname overrides the
              default anongid (the owner's primary group) for multi-service
              write-shared mounts. Triggers an automatic chown task on the
              storage provider node; the NFS export keeps using the OLD
              anonuid until the chown completes to avoid EACCES storms on
              consuming services.
            DESC
            parameters: {
              storage_assignment_id:  { type: "string", required: true },
              owner_kind:             { type: "string", required: true,
                                         description: "service_user | operator | nobody | root" },
              service_user_username:  { type: "string", required: false,
                                         description: "Required when owner_kind=service_user" },
              shared_group_groupname: { type: "string", required: false,
                                         description: "Optional override of anongid for shared-write mounts" }
            }
          },
          "system_list_storage_assignments_by_owner" => {
            description: <<~DESC.squish,
              List StorageAssignments filtered by owner_kind,
              service_user_username, chown_state, or node_instance_id. Use
              for ops audits like "which assignments still use
              owner_kind=root?" or "show me every chown that's stuck in
              failed across the fleet".
            DESC
            parameters: {
              owner_kind:            { type: "string", required: false },
              service_user_username: { type: "string", required: false },
              node_instance_id:      { type: "string", required: false },
              chown_state:           { type: "string", required: false,
                                        description: "complete | pending | running | failed | manual_required" }
            }
          },
          "system_storage_chown_status" => {
            description: "Inspect chown state of a StorageAssignment — current state, previous_uid/gid (if in flight), task id, start/complete timestamps, recorded error.",
            parameters: {
              storage_assignment_id: { type: "string", required: true }
            }
          },
          "system_storage_chown_retry" => {
            description: <<~DESC.squish,
              Re-dispatch a failed or manual_required chown. Resets
              chown_last_error and transitions back to pending — the
              after_commit dispatch hook then queues a fresh task. Pass
              force_complete: true as an escape hatch for cases where the
              operator has manually chowned the files (e.g. on an external
              NFS provider the platform can't reach) and wants to flip the
              assignment to complete without re-running.
            DESC
            parameters: {
              storage_assignment_id: { type: "string", required: true },
              force_complete:        { type: "boolean", required: false, default: false }
            }
          }
        }
      end

      protected

      def call(params)
        action = params[:action]
        return error_result("permission denied: #{required_perm_for(action)} required") unless action_permitted?(action)

        case action
        when "system_assign_storage_owner"              then assign_storage_owner(params)
        when "system_list_storage_assignments_by_owner" then list_storage_assignments_by_owner(params)
        when "system_storage_chown_status"              then storage_chown_status(params)
        when "system_storage_chown_retry"               then storage_chown_retry(params)
        else error_result("Unknown action: #{action}")
        end
      rescue ActiveRecord::RecordNotFound => e
        error_result(e.message)
      rescue ActiveRecord::RecordInvalid => e
        error_result(e.record.errors.full_messages.join("; "))
      end

      private

      def required_perm_for(action)
        ACTION_PERMISSIONS[action] || REQUIRED_PERMISSION
      end

      def action_permitted?(action)
        return true if @user.nil?
        return true unless @user.respond_to?(:has_permission?)
        @user.has_permission?(required_perm_for(action))
      end

      def assign_storage_owner(params)
        assignment = ::System::StorageAssignment.find(params[:storage_assignment_id])
        kind = params[:owner_kind].to_s

        unless ::System::StorageAssignment::OWNER_KINDS.include?(kind)
          return error_result("owner_kind must be one of #{::System::StorageAssignment::OWNER_KINDS.inspect}")
        end

        attrs = { owner_kind: kind }

        if kind == "service_user"
          username = params[:service_user_username].to_s
          return error_result("service_user_username is required when owner_kind=service_user") if username.blank?
          user = ::System::Identity::UserAllocator.allocate!(username: username)
          attrs[:service_user_id] = user.id
        else
          attrs[:service_user_id] = nil
        end

        if params[:shared_group_groupname].present?
          group = ::System::Identity::GroupAllocator.allocate!(groupname: params[:shared_group_groupname].to_s)
          attrs[:shared_group_id] = group.id
        else
          attrs[:shared_group_id] = nil
        end

        assignment.update!(attrs)

        success_result(
          storage_assignment_id:  assignment.id,
          owner_kind:             assignment.owner_kind,
          owner_username:         assignment.owner_username,
          owner_groupname:        assignment.owner_groupname,
          chown_state:            assignment.chown_state,
          chown_task_id:          assignment.chown_task_id
        )
      end

      def list_storage_assignments_by_owner(params)
        scope = ::System::StorageAssignment.where(account: current_account_scope)
        scope = scope.where(owner_kind: params[:owner_kind]) if params[:owner_kind].present?
        if params[:service_user_username].present?
          user = ::System::ServiceUser.live.find_by(username: params[:service_user_username])
          return success_result(assignments: []) unless user
          scope = scope.where(service_user_id: user.id)
        end
        scope = scope.where(node_instance_id: params[:node_instance_id]) if params[:node_instance_id].present?
        scope = scope.where(chown_state: params[:chown_state]) if params[:chown_state].present?

        success_result(
          assignments: scope.includes(:service_user, :shared_group).map { |a| serialize(a) }
        )
      end

      def storage_chown_status(params)
        a = ::System::StorageAssignment.find(params[:storage_assignment_id])
        success_result(
          storage_assignment_id: a.id,
          chown_state:           a.chown_state,
          chown_task_id:         a.chown_task_id,
          chown_previous_uid:    a.chown_previous_uid,
          chown_previous_gid:    a.chown_previous_gid,
          chown_started_at:      a.chown_started_at&.iso8601,
          chown_completed_at:    a.chown_completed_at&.iso8601,
          chown_last_error:      a.chown_last_error,
          current_anonuid:       a.anonuid,
          current_anongid:       a.anongid,
          effective_export_uid:  a.effective_export_uid,
          effective_export_gid:  a.effective_export_gid
        )
      end

      def storage_chown_retry(params)
        a = ::System::StorageAssignment.find(params[:storage_assignment_id])
        if params[:force_complete]
          a.update_columns(
            chown_state:        "complete",
            chown_completed_at: Time.current,
            chown_previous_uid: nil,
            chown_previous_gid: nil,
            chown_last_error:   "force_complete invoked by operator at #{Time.current.iso8601}"
          )
          ::System::Storage::AssignmentReconciliationService.reconcile_assignment!(a) rescue nil
          return success_result(storage_assignment_id: a.id, chown_state: a.chown_state, forced: true)
        end

        unless %w[failed manual_required].include?(a.chown_state)
          return error_result("chown is in state #{a.chown_state}; retry is only valid for failed | manual_required")
        end

        a.update_columns(chown_state: "pending", chown_last_error: nil, chown_task_id: nil)
        ::System::Storage::ChownDispatchService.dispatch!(a)
        success_result(storage_assignment_id: a.id, chown_state: a.reload.chown_state, chown_task_id: a.chown_task_id)
      end

      def serialize(a)
        {
          id:                    a.id,
          mount_path:            a.mount_path,
          node_instance_id:      a.node_instance_id,
          owner_kind:            a.owner_kind,
          owner_username:        a.owner_username,
          owner_groupname:       a.owner_groupname,
          anonuid:               a.anonuid,
          anongid:               a.anongid,
          shared_group_id:       a.shared_group_id,
          chown_state:           a.chown_state,
          chown_last_error:      a.chown_last_error
        }
      end

      # BaseTool provides @account when invoked via an operator/agent
      # context. When nil (rare — internal system call), the query
      # falls back to all accounts — chown audits are explicitly
      # cross-account-safe because identities are platform-global.
      def current_account_scope
        @account&.id
      end
    end
  end
end
