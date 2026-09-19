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

      # IMP-ba7956c5b38d — used to build a SINGLE-entry storage.exports.apply
      # payload for just this credential's peer (TaskPayloadBuilder#build_exports_apply_payload).
      # The agent's ApplyExports (agent/internal/storage/exports.go) OVERWRITES
      # the whole exports file with whatever entries a task carries — a grant
      # for one client wiped out every OTHER client already exported on this
      # storage, the same class of bug IMP-e88b38770d13 already fixed for
      # teardown by rebuilding from live DB state instead of dispatching a
      # single entry. `credential:` is kept only for interface compatibility
      # with existing callers (CredentialIssuer) — the full rebuild reads
      # live StorageAssignment/#active_credential rows itself and does not
      # need this specific row. The new credential must already be
      # "issued" or "active" (StorageAssignment#active_credential's own
      # filter) by the time this runs, or the rebuild will exclude it —
      # true today: CredentialIssuer calls this AFTER creating the row
      # (status "issued") and before #activate!.
      def grant!(credential:)
        return unless @storage&.nfs?

        reconcile!
      end

      # IMP-ba7956c5b38d — same fix as #grant!, and the same ORDERING
      # requirement it implies: the credential being revoked must already
      # be excluded from StorageAssignment#active_credential (status not
      # "issued"/"active") by the time this runs, or the rebuild will
      # still include the peer this call exists to remove. CredentialIssuer#revoke!
      # updates the row's status to "revoked" before calling this (see that
      # method's own comment) — both statements share ONE DB transaction/
      # connection, so Postgres's read-your-own-writes guarantee makes this
      # correct without needing an actual COMMIT boundary.
      def revoke!(credential:)
        return unless @storage&.nfs?

        reconcile!
      end

      # Full rewrite of the exports file from current StorageAssignment rows
      # pointing at this storage. Now the ONLY path #grant!/#revoke! use too
      # (IMP-ba7956c5b38d), not just the drift-recovery/teardown path.
      def self.reconcile!(storage:)
        new(storage: storage).reconcile!
      end

      def reconcile!
        with_lock do
          included_credential_ids = []

          entries = ::System::StorageAssignment
            .where(file_storage_id: @storage.id, enabled: true)
            .includes(:storage_credentials, :sdwan_virtual_ip)
            .filter_map do |a|
              cred = a.active_credential
              next unless cred

              peer_ip = cred.vault_credentials.dig("peer_ip") || cred.metadata["peer_ip"]
              # Review round — a single partially-provisioned row (peer
              # enrollment failed after the credential row was created, or
              # any other path that leaves peer_ip blank) must not fail the
              # WHOLE storage's rebuild: the agent's ApplyExports validation
              # rejects a nil/non-address peer_ip outright (agent/internal/
              # storage/validate.go), so one bad row would have cut off
              # every OTHER client on this storage too. Skip it and log
              # just the ids — never log credential material.
              if peer_ip.blank?
                Rails.logger.warn("[NfsExportManager] skipping assignment #{a.id} / credential #{cred.id}: no peer_ip")
                next
              end

              included_credential_ids << cred.id

              {
                peer_ip: peer_ip,
                # effective_export_uid/gid preserves OLD ownership
                # during an in-flight chown so consumers don't see
                # EACCES storms; otherwise the assignment's current
                # anonuid/anongid take effect (see StorageAssignment).
                uid: a.effective_export_uid,
                gid: a.effective_export_gid,
                options: %w[rw sync no_subtree_check all_squash sec=sys]
              }
            end

          payload = {
            storage_id: @storage.id,
            account_id: @storage.account_id,
            export_path: export_path_for_shape,
            deployment_shape: @storage.deployment_shape,
            # IMP-ba7956c5b38d — the agent's ApplyExports only removes the
            # exports file (rather than writing an empty one) when
            # action == "revoke" AND entries is empty (agent/internal/
            # storage/exports.go). This full rebuild uses "revoke"
            # unconditionally, not "reconcile": with a NON-empty entries
            # list the agent treats every action value identically (just
            # writes the rendered file), so this changes nothing for the
            # common case, but it means revoking the LAST client on a
            # storage correctly deletes the file instead of leaving a
            # stale, comment-only one behind.
            action: "revoke",
            entries: entries,
            # IMP-9ffb9b2407da — credential ids only (never peers/secrets)
            # that actually made it into `entries` above (a peerless row,
            # see the WARN-and-skip just above, is NOT listed here either).
            # AssignmentReconciliationService's stalled-rebuild redispatch
            # uses this as a MEMBERSHIP watermark — "was THIS credential
            # actually included in the last completed rebuild" — instead of
            # a timestamp comparison. A timing check alone gives a false
            # "safe": disable an assignment, let a rebuild correctly
            # exclude it and complete (AFTER the credential row's
            # created_at, same as any other rebuild), then re-enable it
            # with the SAME credential — a timing-only check would call
            # that rebuild "safe" even though it deliberately left the peer
            # out, and the peer would never get re-exported.
            included_credential_ids: included_credential_ids
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
