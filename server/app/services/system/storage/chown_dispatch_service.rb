# frozen_string_literal: true

module System
  module Storage
    # System::Storage::ChownDispatchService — routes a pending chown for
    # a StorageAssignment to the right node's agent. The agent runs
    # `find -uid OLD -exec chown NEW {} +` on the actual files and POSTs
    # completion to /api/v1/system/worker_api/storage/chown_complete.
    #
    # Storage-type routing:
    #   - nfs / smb      → provider node (where the share lives)
    #   - ebs / local block / fscrypt → consumer node (the assignment's
    #                                                  node_instance)
    #   - s3 / gcs / azure → no-op (object ACLs are metadata, not file
    #                               ownership); marks chown_state =
    #                               "complete" immediately
    #   - external NFS (not platform-managed) → manual_required
    #
    # Idempotent: re-dispatch while chown_state == "running" is a no-op.
    # Called from StorageAssignment#dispatch_chown_if_pending after an
    # owner change commits.
    class ChownDispatchService
      class DispatchError < StandardError; end

      OBJECT_STORE_PROVIDERS = %w[s3 gcs azure].freeze
      LOCAL_BLOCK_PROVIDERS  = %w[ebs custom local].freeze

      def self.dispatch!(assignment)
        new(assignment).dispatch!
      end

      def initialize(assignment)
        @assignment = assignment
        @storage    = assignment.file_storage
      end

      def dispatch!
        return :noop if @assignment.chown_state == "running"
        return mark_complete_inline! if object_store?
        return mark_manual_required!("storage has no file_storage record")  if @storage.nil?
        return mark_manual_required!("external/unmanaged provider: #{provider_type}") if external_provider?

        target_instance = provider_node_instance
        unless target_instance
          return mark_manual_required!("no platform-managed provider instance for storage #{@storage.id}")
        end

        task = ::System::Task.create!(
          account:  @assignment.account,
          operable: target_instance,
          command:  "storage.chown",
          options:  payload,
          status:   "pending"
        )

        @assignment.update_columns(
          chown_state:      "running",
          chown_task_id:    task.id,
          chown_started_at: Time.current,
          chown_last_error: nil
        )

        task
      rescue StandardError => e
        @assignment.update_columns(
          chown_state:      "failed",
          chown_last_error: "dispatch failed: #{e.class}: #{e.message}"
        )
        raise DispatchError, e.message
      end

      private

      def payload
        {
          storage_assignment_id: @assignment.id,
          mount_path:            @assignment.mount_path,
          old_uid:               @assignment.chown_previous_uid,
          old_gid:               @assignment.chown_previous_gid,
          new_uid:               @assignment.anonuid,
          new_gid:               @assignment.anongid,
          callback_path:         "/api/v1/system/worker_api/storage/chown_complete",
          preserve_symlinks:     true
        }
      end

      def provider_type
        @storage&.provider_type
      end

      def object_store?
        OBJECT_STORE_PROVIDERS.include?(provider_type)
      end

      # For NFS/SMB: the chown happens on the node hosting the export
      # (gateway or backend, depending on deployment_shape). Local block
      # / fscrypt: the chown runs on the same node that has the volume
      # mounted (the assignment's node_instance).
      def provider_node_instance
        case provider_type
        when "nfs", "smb"
          backend_id = nfs_or_smb_provider_node_id
          backend_id.present? ? ::System::NodeInstance.find_by(id: backend_id) : nil
        when *LOCAL_BLOCK_PROVIDERS
          @assignment.node_instance
        when "fscrypt"
          @assignment.node_instance
        else
          @assignment.node_instance
        end
      end

      def nfs_or_smb_provider_node_id
        cfg = @storage.configuration || {}
        if @storage.respond_to?(:gateway_proxy?) && @storage.gateway_proxy?
          cfg["gateway_node_instance_id"]
        else
          cfg["export_host_node_instance_id"]
        end
      end

      # External provider = NFS/SMB whose actual server isn't a
      # Powernode-managed node (e.g. NetApp, AWS EFS). The platform
      # can't push a chown command into a system it doesn't operate.
      def external_provider?
        return false unless %w[nfs smb].include?(provider_type)
        nfs_or_smb_provider_node_id.blank?
      end

      def mark_complete_inline!
        @assignment.update_columns(
          chown_state:        "complete",
          chown_completed_at: Time.current,
          chown_previous_uid: nil,
          chown_previous_gid: nil,
          chown_last_error:   nil
        )
        :noop
      end

      def mark_manual_required!(reason)
        @assignment.update_columns(
          chown_state:      "manual_required",
          chown_last_error: reason
        )
        :manual_required
      end
    end
  end
end
