# frozen_string_literal: true

module System
  class NodeInstanceSerializer
    def initialize(instance)
      @instance = instance
    end

    def as_json
      {
        id: @instance.id,
        name: @instance.name,
        description: @instance.description,
        variety: @instance.variety,
        status: @instance.status,
        config: @instance.config,
        private_ip_address: @instance.private_ip_address,
        public_ip_address: @instance.public_ip_address,
        vpn_ip_address: @instance.vpn_ip_address,
        # Physical-device claim state (populated for variety=physical
        # instances after the operator confirms a claim via the
        # Unclaimed Devices UI). See plan wondrous-yawning-anchor.md.
        mac_address:         @instance.mac_address,
        private_netboot:     @instance.private_netboot,
        claim_code:          @instance.claim_code,
        claimed_at:          @instance.claimed_at,
        discovered_mac:      @instance.discovered_mac,
        discovered_dmi_uuid: @instance.discovered_dmi_uuid,
        discovered_hostname: @instance.discovered_hostname,
        discovered_at:       @instance.discovered_at,
        claimed:             @instance.respond_to?(:claimed?) ? @instance.claimed? : @instance.claimed_at.present?,
        node_id: @instance.node_id,
        node_name: @instance.node&.name,
        active: @instance.active?,
        created_at: @instance.created_at,
        updated_at: @instance.updated_at
      }
    end
  end
end
