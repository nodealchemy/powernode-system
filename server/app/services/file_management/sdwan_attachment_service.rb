# frozen_string_literal: true

module FileManagement
  # Binds a FileManagement::Storage to a Sdwan::Network by ensuring a
  # service VIP + a firewall rule that admits the storage's service port
  # from peers in the network.
  #
  # Lives in the system extension (not core platform) because it depends
  # on ::Sdwan::* models. Namespaced under FileManagement so feature-hub
  # navigation surfaces it next to the storage it describes.
  class SdwanAttachmentService
    PROVIDER_PORTS = {
      "nfs" => 2049,
      "smb" => 445
    }.freeze

    def self.attach!(storage:, network:, port: nil, protocol: "tcp")
      new(storage: storage, network: network, port: port, protocol: protocol).attach!
    end

    def self.detach!(storage:, network:)
      new(storage: storage, network: network).detach!
    end

    def initialize(storage:, network:, port: nil, protocol: "tcp")
      @storage = storage
      @network = network
      @port = port || PROVIDER_PORTS[@storage.provider_type]
      @protocol = protocol
    end

    def attach!
      raise ArgumentError, "No service port for provider #{@storage.provider_type}" unless @port

      backend_id = backend_node_instance_id
      raise ArgumentError, "Storage #{@storage.id} has no backend node instance" unless backend_id

      backend_peer = ::Sdwan::Peer.find_by(
        node_instance_id: backend_id,
        sdwan_network_id: @network.id
      )
      raise "Backend node #{backend_id} not yet enrolled as Sdwan::Peer for network #{@network.id}" unless backend_peer

      virtual_ip = find_or_create_virtual_ip!(backend_peer)
      firewall_rule = find_or_create_firewall_rule!(backend_peer)

      ::Sdwan::TopologyCompiler.compile_for_network(@network) if defined?(::Sdwan::TopologyCompiler)

      {
        virtual_ip: virtual_ip,
        firewall_rule: firewall_rule,
        port: @port,
        protocol: @protocol
      }
    end

    def detach!
      ::Sdwan::FirewallRule
        .where(sdwan_network_id: @network.id, name: firewall_rule_name)
        .destroy_all
      ::Sdwan::VirtualIp
        .where(sdwan_network_id: @network.id, name: virtual_ip_name)
        .destroy_all
      ::Sdwan::TopologyCompiler.compile_for_network(@network) if defined?(::Sdwan::TopologyCompiler)
      true
    end

    private

    def backend_node_instance_id
      if @storage.gateway_proxy?
        @storage.configuration["gateway_node_instance_id"]
      else
        @storage.configuration["export_host_node_instance_id"]
      end
    end

    def virtual_ip_name
      "storage-#{@storage.id}"
    end

    def firewall_rule_name
      "storage-#{@storage.id}-#{@protocol}-#{@port}"
    end

    def find_or_create_virtual_ip!(backend_peer)
      ::Sdwan::VirtualIp.find_or_create_by!(
        account: @network.account,
        sdwan_network_id: @network.id,
        name: virtual_ip_name
      ) do |vip|
        vip.anycast = false if vip.respond_to?(:anycast=)
        vip.holder_peer_ids = [backend_peer.id] if vip.respond_to?(:holder_peer_ids=)
        vip.metadata = { storage_id: @storage.id, provider_type: @storage.provider_type } if vip.respond_to?(:metadata=)
        # Derive a unique /128 inside the network's prefix using the same
        # deterministic allocator peers use; storage VIPs and peer addresses
        # don't collide because the storage UUID has a different seed.
        vip.cidr = ::Sdwan::PrefixAllocator.allocate_peer_address!(network: @network, peer_id: @storage.id)
      end
    end

    def find_or_create_firewall_rule!(backend_peer)
      ::Sdwan::FirewallRule.find_or_create_by!(
        account: @network.account,
        sdwan_network_id: @network.id,
        name: firewall_rule_name
      ) do |rule|
        rule.direction = "ingress" if rule.respond_to?(:direction=)
        rule.dst_selector = { peer_id: backend_peer.id } if rule.respond_to?(:dst_selector=)
        rule.src_selector = { all: true } if rule.respond_to?(:src_selector=)
        rule.protocol = @protocol if rule.respond_to?(:protocol=)
        rule.port_from = @port if rule.respond_to?(:port_from=)
        rule.port_to = @port if rule.respond_to?(:port_to=)
        rule.firewall_action = "accept" if rule.respond_to?(:firewall_action=)
      end
    end
  end
end
