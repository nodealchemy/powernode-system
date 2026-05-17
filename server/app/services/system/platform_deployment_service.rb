# frozen_string_literal: true

module System
  # Provisions a PlatformDeployment row, optionally allocating a SDWAN
  # VirtualIP on a caller-supplied network. The deployment row is read
  # at service-startup by Powernode::Bootstrap.discover_peer so a worker
  # on Node B can find the API on Node A by `service_role`.
  #
  # Plan reference: Decentralized Federation §G + P2.3.
  #
  # Usage:
  #   System::PlatformDeploymentService.provision!(
  #     account: account,
  #     name: "hub-api-primary",
  #     service_role: "api",
  #     node_template: template,
  #     network: network,            # optional; nil = no VIP allocation
  #     vip_cidr: "fd00:beef::42/128",  # required when network is given
  #     vip_name: "hub-api-vip",      # optional; defaults to "<name>-vip"
  #     public_dns_hostname: "hub.example.com",
  #     target_replicas: 2
  #   )
  class PlatformDeploymentService
    Result = Struct.new(:ok?, :error, :deployment, :virtual_ip, keyword_init: true)

    class ProvisionError < StandardError; end

    class << self
      def provision!(**args)
        new.provision!(**args)
      end
    end

    def provision!(account:, name:, service_role:, node_template:,
                   network: nil, vip_cidr: nil, vip_name: nil,
                   public_dns_hostname: nil, satellite_extension_slug: nil,
                   target_replicas: 1, metadata: {})
      return failure("account required") unless account
      return failure("node_template required") unless node_template
      return failure("name required") if name.blank?
      return failure("service_role required") if service_role.blank?

      unless ::System::PlatformDeployment::SERVICE_ROLES.include?(service_role)
        return failure("service_role must be one of #{::System::PlatformDeployment::SERVICE_ROLES.inspect}")
      end

      if network && vip_cidr.blank?
        return failure("vip_cidr required when network is supplied")
      end

      vip = nil

      ::ActiveRecord::Base.transaction do
        vip = allocate_vip!(network: network, vip_cidr: vip_cidr,
                            vip_name: vip_name || "#{name}-vip") if network

        deployment = ::System::PlatformDeployment.find_or_initialize_by(
          account: account, name: name
        )
        deployment.assign_attributes(
          node_template: node_template,
          service_role: service_role,
          virtual_ip: vip,
          public_dns_hostname: public_dns_hostname,
          satellite_extension_slug: satellite_extension_slug,
          target_replicas: target_replicas,
          metadata: metadata
        )
        deployment.save!

        emit_event!(deployment, action: deployment.previously_new_record? ? "created" : "updated")
        Result.new(ok?: true, deployment: deployment, virtual_ip: vip)
      end
    rescue ProvisionError => e
      failure(e.message)
    rescue ::ActiveRecord::RecordInvalid => e
      failure("save failed: #{e.record.errors.full_messages.join('; ')}")
    end

    private

    def allocate_vip!(network:, vip_cidr:, vip_name:)
      vip = network.virtual_ips.find_or_initialize_by(name: vip_name)
      vip.account = network.account
      vip.cidr = vip_cidr
      vip.state ||= "pending"
      vip.advertised_med ||= 100
      vip.advertised_local_pref ||= 100
      vip.anycast = false if vip.anycast.nil?
      vip.holder_peer_ids ||= []
      vip.save!
      vip
    rescue ::ActiveRecord::RecordInvalid => e
      raise ProvisionError, "VIP allocation failed: #{e.record.errors.full_messages.join('; ')}"
    end

    def emit_event!(deployment, action:)
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: deployment.account,
        kind: "platform.deployment.#{action}",
        severity: "low",
        source: "platform_deployment_service",
        payload: {
          deployment_id: deployment.id,
          name: deployment.name,
          service_role: deployment.service_role,
          virtual_ip_id: deployment.virtual_ip_id,
          public_dns_hostname: deployment.public_dns_hostname,
          target_replicas: deployment.target_replicas
        }
      )
    rescue StandardError => e
      Rails.logger.warn("[PlatformDeploymentService] event broadcast failed: #{e.message}")
    end

    def failure(message)
      Result.new(ok?: false, error: message)
    end
  end
end
