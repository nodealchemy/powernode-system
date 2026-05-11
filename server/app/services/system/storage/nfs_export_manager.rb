# frozen_string_literal: true

module System
  module Storage
    # Backend-side NFS export orchestrator.
    #
    # For Shape 1 (self_hosted) the backend peer is the powernode hosting the
    # NFS export directly. For Shape 2 (gateway_proxy) the backend peer is the
    # gateway node that already has the upstream NFS mounted at re_export_path
    # and re-exports it on the SDWAN interface (the gateway-provision task
    # ensures that re-export is in place — see GatewayProvisioningService).
    #
    # Per-assignment writes are serialized via a per-storage advisory lock so
    # two concurrent CredentialIssuer runs can't race the exports.d file.
    class NfsExportManager
      def initialize(assignment: nil, storage: nil)
        @assignment = assignment
        @storage = storage || assignment&.file_storage
      end

      def grant!(credential:)
        return unless @storage&.nfs?

        with_lock do
          payload = TaskPayloadBuilder.build_exports_apply_payload(
            assignment: @assignment, credential: credential
          )
          dispatch_task("storage.exports.apply", payload)
        end
      end

      def revoke!(credential:)
        return unless @storage&.nfs?

        with_lock do
          payload = TaskPayloadBuilder.build_exports_apply_payload(
            assignment: @assignment, credential: credential
          ).merge(action: "revoke")
          dispatch_task("storage.exports.apply", payload)
        end
      end

      # Full rewrite of the exports file from current StorageAssignment rows
      # pointing at this storage. Drift-recovery path; rarely invoked.
      def self.reconcile!(storage:)
        new(storage: storage).reconcile!
      end

      def reconcile!
        with_lock do
          entries = ::System::StorageAssignment
            .where(file_storage_id: @storage.id, enabled: true)
            .includes(:storage_credentials, :sdwan_virtual_ip)
            .filter_map do |a|
              cred = a.active_credential
              next unless cred

              {
                peer_ip: cred.vault_credentials.dig("peer_ip") || cred.metadata["peer_ip"],
                uid: a.derived_uid,
                gid: a.derived_uid,
                options: %w[rw sync no_subtree_check all_squash sec=sys]
              }
            end

          payload = {
            storage_id: @storage.id,
            account_id: @storage.account_id,
            export_path: export_path_for_shape,
            deployment_shape: @storage.deployment_shape,
            action: "reconcile",
            entries: entries
          }
          dispatch_task("storage.exports.apply", payload)
        end
      end

      private

      def backend_node_instance_id
        if @storage.gateway_proxy?
          @storage.configuration["gateway_node_instance_id"]
        else
          @storage.configuration["export_host_node_instance_id"]
        end
      end

      def export_path_for_shape
        if @storage.gateway_proxy?
          @storage.configuration["re_export_path"]
        else
          @storage.configuration["export_path"]
        end
      end

      # Postgres advisory lock keyed on the storage UUID's first 4 bytes.
      # Prevents concurrent exports.d writes from racing the file. Released
      # automatically at transaction end. Use execute() (not exec_query) so
      # PG doesn't try to deserialize the void return type.
      def with_lock(&block)
        lock_key = @storage.id.to_s.delete("-").first(8).to_i(16)
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key})")
          yield
        end
      end

      def dispatch_task(command, payload)
        backend_id = backend_node_instance_id
        raise "No backend node instance configured for storage #{@storage.id}" unless backend_id

        backend_instance = ::System::NodeInstance.find(backend_id)

        ::System::Task.create!(
          account: @storage.account,
          operable: backend_instance,
          command: command,
          options: payload,
          status: "pending"
        )
      end
    end
  end
end
