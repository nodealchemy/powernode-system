# frozen_string_literal: true

module System
  module Storage
    # Issues + rotates + revokes per-instance storage credentials.
    #
    # Flow:
    #   1. Resolve (or auto-enroll) Sdwan::Peer for (instance, network)
    #   2. Assemble plain-hash context for the provider
    #   3. Call provider.issue_node_credential — pure data return
    #   4. Persist System::StorageCredential, seal payload in Vault
    #   5. Side-effects: NfsExportManager#grant! or SmbUserManager#provision_user!
    #      depending on provider_type
    #
    # Avoids the @vault_credentials cache reload bug
    # (feedback_vault_credential_reload_bug.md) by re-fetching the credential
    # via Model.find(id) after store_in_vault rather than calling reload.
    class CredentialIssuer
      class IssuanceError < StandardError; end

      def initialize(assignment:)
        @assignment = assignment
        @storage = assignment.file_storage
      end

      def issue!
        raise IssuanceError, "Storage #{@assignment.file_storage_id} not found" unless @storage

        peer = ensure_peer!
        context = build_context(peer)

        provider_result = @storage.storage_provider.issue_node_credential(context: context)
        raise IssuanceError, "Provider returned nil credential" unless provider_result

        credential = ::System::StorageCredential.create!(
          storage_assignment: @assignment,
          node_instance_id: @assignment.node_instance_id,
          kind: provider_result[:kind],
          status: "issued",
          expires_at: provider_result[:ttl] ? provider_result[:ttl].from_now : nil,
          last_rotated_at: Time.current,
          metadata: (provider_result[:metadata] || {}).merge(peer_ip: peer&.assigned_address)
        )
        credential.store_in_vault(provider_result[:payload] || {})

        # Re-fetch (NOT reload) to bypass the @vault_credentials cache reload bug
        credential = ::System::StorageCredential.find(credential.id)
        materialize_backend_side!(credential)
        credential.activate!
        credential
      end

      def rotate!(credential)
        credential.mark_rotating!
        new_cred = issue!
        revoke!(credential)
        new_cred
      end

      def revoke!(credential)
        case @storage.provider_type
        when "nfs"
          NfsExportManager.new(assignment: @assignment).revoke!(credential: credential)
        when "smb"
          SmbUserManager.new(assignment: @assignment).deprovision_user!(credential: credential)
        end

        handle = credential.metadata["export_handle"] || credential.metadata["smb_user_handle"] || credential.metadata["sts_handle"]
        @storage.storage_provider.revoke_node_credential(handle) if handle

        credential.revoke!
      end

      private

      def ensure_peer!
        return nil unless @assignment.sdwan_network_id

        peer = ::Sdwan::Peer.find_by(
          node_instance_id: @assignment.node_instance_id,
          sdwan_network_id: @assignment.sdwan_network_id
        )
        return peer if peer

        ::Sdwan::PeerEnroller.call(
          network: @assignment.sdwan_network,
          node_instance: @assignment.node_instance
        )
      end

      def build_context(peer)
        {
          instance_id: @assignment.node_instance_id,
          instance_hostname: @assignment.node_instance&.name,
          peer_ip: peer&.assigned_address,
          uid: @assignment.derived_uid,
          gid: @assignment.derived_uid,
          account_id: @assignment.account_id,
          sdwan_network_id: @assignment.sdwan_network_id,
          virtual_ip_address: @assignment.sdwan_virtual_ip&.cidr&.split("/")&.first,
          deployment_shape: @storage.deployment_shape,
          storage_configuration: @storage.configuration
        }
      end

      def materialize_backend_side!(credential)
        case @storage.provider_type
        when "nfs"
          NfsExportManager.new(assignment: @assignment).grant!(credential: credential)
        when "smb"
          SmbUserManager.new(assignment: @assignment).provision_user!(credential: credential)
        end
      end
    end
  end
end
