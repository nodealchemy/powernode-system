# frozen_string_literal: true

module System
  # Worker-facing serializer for NodeInstance. Exposes operator-only fields
  # (cloud_instance_id, admin_user, ssh_ip_address, ssh_key presence, etc.)
  # that the public NodeInstanceSerializer deliberately omits.
  class NodeInstanceInternalSerializer
    def initialize(instance)
      @instance = instance
    end

    def as_json
      node = @instance.node
      {
        id: @instance.id,
        name: @instance.name,
        variety: @instance.variety,
        status: @instance.status,
        node_id: @instance.node_id,
        node: node ? { id: node.id, name: node.name, enabled: node.enabled } : nil,
        private_ip_address: @instance.private_ip_address,
        public_ip_address: @instance.public_ip_address,
        vpn_ip_address: @instance.vpn_ip_address,
        provider_region_id: @instance.provider_region_id,
        provider_instance_type_id: @instance.provider_instance_type_id,
        cloud_instance_id: @instance.cloud_instance_id,
        admin_user: @instance.admin_user,
        ssh_ip_address: @instance.ssh_ip_address,
        ssh_key: @instance.key.present?,
        last_synced_at: @instance.last_synced_at,
        created_at: @instance.created_at,
        updated_at: @instance.updated_at
      }
    end
  end
end
