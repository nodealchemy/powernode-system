# frozen_string_literal: true

module System
  module Storage
    # Backend-side per-instance Samba user provisioner.
    #
    # Shape 1: writes the user via samba-tool on the storage backend node.
    # Shape 2: writes on the gateway node (which runs Samba + re-shares the
    # locally-mounted upstream).
    #
    # The task payload NEVER carries the plaintext password: System::Task#options
    # is a plaintext jsonb column (not Vault-sealed), so embedding the password
    # there would land it in the DB, backups, and any dump of the row. Instead
    # the payload carries a CredentialRef the agent resolves at apply time
    # through the SAME node_api/storage_assignments/:id/credential Vault
    # round-trip the CIFS mount path already uses
    # (agent/internal/storage/credentials.go#fetchCredential). The ref names
    # the EXACT credential id it wants (?credential_id=) — see
    # StorageAssignmentsController#resolve_credential (node_api), which serves
    # that specific id to the SMB backend/gateway node ONLY while a live
    # (pending/running) storage.smb_user.apply task naming it exists for that
    # exact requesting instance; "the active one" is never served to a
    # non-owning requester.
    class SmbUserManager
      def initialize(assignment: nil, storage: nil)
        @assignment = assignment
        @storage = storage || assignment&.file_storage
      end

      def provision_user!(credential:)
        return unless @storage&.smb?

        payload = build_payload(credential: credential, action: "create")
        dispatch_task("storage.smb_user.apply", payload)
      end

      def deprovision_user!(credential:)
        return unless @storage&.smb?

        payload = build_payload(credential: credential, action: "delete")
        dispatch_task("storage.smb_user.apply", payload)
      end

      # new_credential is the ALREADY-ISSUED replacement System::StorageCredential
      # (its password sealed in Vault under its own row) — never a raw string.
      def rotate_user!(credential:, new_credential:)
        return unless @storage&.smb?

        payload = build_payload(credential: credential, action: "set_password", new_credential: new_credential)
        dispatch_task("storage.smb_user.apply", payload)
      end

      private

      def build_payload(credential:, action:, new_credential: nil)
        {
          storage_id: @storage.id,
          account_id: @storage.account_id,
          action: action,
          username: credential.vault_credentials["username"],
          credential: credential_ref(credential),
          new_credential: new_credential ? credential_ref(new_credential) : nil,
          deployment_shape: @storage.deployment_shape,
          re_share_name: @storage.configuration["re_share_name"]
        }.compact
      end

      def credential_ref(credential)
        raise "SmbUserManager requires an assignment to build a credential ref" unless @assignment

        {
          id: credential.id,
          kind: credential.kind,
          url: "/api/v1/system/node_api/storage_assignments/#{@assignment.id}/credential?credential_id=#{credential.id}"
        }
      end

      def backend_node_instance_id
        if @storage.gateway_proxy?
          @storage.configuration["gateway_node_instance_id"]
        else
          @storage.configuration["export_host_node_instance_id"]
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
