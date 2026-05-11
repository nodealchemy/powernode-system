# frozen_string_literal: true

module System
  module Storage
    # Shape 2 (gateway_proxy) only.
    #
    # Configures a gateway powernode to mount an external NFS/SMB server and
    # re-export it on its SDWAN interface. Clients in the SDWAN mount the
    # gateway, not the upstream — the gateway is the trust boundary.
    #
    # V1 ships with plaintext gateway↔upstream traffic (operator's
    # responsibility to put the gateway on a trusted subnet). V2 will add
    # stunnel/tlshd wrapping.
    class GatewayProvisioningService
      def self.provision!(storage:)
        new(storage: storage).provision!
      end

      def self.deprovision!(storage:)
        new(storage: storage).deprovision!
      end

      def initialize(storage:)
        @storage = storage
      end

      def provision!
        validate_shape!
        gateway = ::System::NodeInstance.find(@storage.configuration["gateway_node_instance_id"])

        payload = TaskPayloadBuilder.build_gateway_provision_payload(storage: @storage)

        ::System::Task.create!(
          account: @storage.account,
          operable: gateway,
          command: "storage.gateway.provision",
          options: payload,
          status: "pending"
        )
      end

      def deprovision!
        validate_shape!
        gateway = ::System::NodeInstance.find(@storage.configuration["gateway_node_instance_id"])

        payload = TaskPayloadBuilder.build_gateway_deprovision_payload(storage: @storage)

        ::System::Task.create!(
          account: @storage.account,
          operable: gateway,
          command: "storage.gateway.deprovision",
          options: payload,
          status: "pending"
        )
      end

      private

      def validate_shape!
        return if @storage&.gateway_proxy?

        raise ArgumentError, "GatewayProvisioningService only applies to gateway_proxy storage (got #{@storage&.deployment_shape.inspect})"
      end
    end
  end
end
