# frozen_string_literal: true

module System
  module Storage
    # Backend-side per-instance Samba user provisioner.
    #
    # Shape 1: writes the user via samba-tool on the storage backend node.
    # Shape 2: writes on the gateway node (which runs Samba + re-shares the
    # locally-mounted upstream).
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

      def rotate_user!(credential:, new_password:)
        return unless @storage&.smb?

        payload = build_payload(credential: credential, action: "set_password", new_password: new_password)
        dispatch_task("storage.smb_user.apply", payload)
      end

      private

      def build_payload(credential:, action:, **extra)
        creds = credential.vault_credentials
        {
          storage_id: @storage.id,
          account_id: @storage.account_id,
          action: action,
          username: creds["username"],
          password: creds["password"],
          deployment_shape: @storage.deployment_shape,
          re_share_name: @storage.configuration["re_share_name"]
        }.merge(extra)
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
