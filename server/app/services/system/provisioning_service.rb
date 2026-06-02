# frozen_string_literal: true

module System
  # Provisions cloud instances via provider adapters and returns
  # System::Runtime::Result. Provider adapters below this layer keep their
  # cloud-shape hash (`success:, cloud_instance_id:, ...`) — this service
  # is the boundary that maps that into the platform-standard Result.
  class ProvisioningService
    class ProvisioningError < StandardError; end

    def self.provision_instance(node:, provider_region_id:, provider_instance_type_id:, operation_id: nil, options: {})
      new.provision_instance(
        node: node,
        provider_region_id: provider_region_id,
        provider_instance_type_id: provider_instance_type_id,
        operation_id: operation_id,
        options: options
      )
    end

    def provision_instance(node:, provider_region_id:, provider_instance_type_id:, operation_id: nil, options: {})
      validate_node!(node)

      # M1 Self-Serve Hardening — gate provisioning on the active subscription's
      # plan limits. Surfaces a structured deny reason that propagates up through
      # Runtime::Result.err and onto the caller's `requires_upgrade` payload.
      if defined?(::Billing::ProvisioningQuotaGuard)
        allow, reason = ::Billing::ProvisioningQuotaGuard.allow?(account: node.account)
        unless allow
          Rails.logger.info("[ProvisioningService] Quota guard denied provisioning: #{reason}")
          return Runtime::Result.err(error: reason, data: { requires_upgrade: true, reason: reason })
        end
      end

      region = ::System::ProviderRegion.find_by(id: provider_region_id)
      instance_type = ::System::ProviderInstanceType.find_by(id: provider_instance_type_id)

      return Runtime::Result.err(error: "Provider region not found") unless region
      return Runtime::Result.err(error: "Instance type not found") unless instance_type

      provider_adapter = begin
        Providers::Registry.for_node(node, region: region)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      Rails.logger.info("[ProvisioningService] Provisioning instance for node #{node.name} in #{region.name} using #{provider_adapter.provider_type}")

      # Idempotency — a retried call carrying the same operation_id must not
      # spin up a second instance. Reuse a prior non-terminated instance
      # tagged with this operation_id (dedups sequential client retries on
      # transient errors). A unique index on config->>'operation_id' would
      # harden this against concurrent racers; the check-then-create here
      # covers the common sequential-retry case.
      if operation_id.present?
        existing = ::System::NodeInstance
                     .where(node_id: node.id)
                     .where("config->>'operation_id' = ?", operation_id.to_s)
                     .where.not(status: "terminated")
                     .first
        if existing
          Rails.logger.info("[ProvisioningService] Reusing instance #{existing.name} for operation #{operation_id}")
          return Runtime::Result.ok(data: { instance: existing, cloud_instance_id: existing.cloud_instance_id })
        end
      end

      instance_name = generate_instance_name(node, options)

      instance = ::System::NodeInstance.create!(
        name: instance_name,
        node: node,
        variety: "cloud",
        status: "pending",
        provider_region: region,
        provider_instance_type: instance_type,
        # Stamp the operation_id into config so a retry can find-and-reuse this
        # row instead of duplicating (see the idempotency guard above).
        config: operation_id.present? ? { "operation_id" => operation_id.to_s } : {},
        # Final fallback is "pnadmin" (Powernode's standardized
        # interactive-login account, UID 1000, present in the agent's
        # etcidentity baseline). Cloud-image-derived nodes may
        # override per-template or per-instance with "ubuntu", "ec2-user",
        # "debian", etc. — those still flow through options[:admin_user]
        # + node_template.admin_user.
        admin_user: options[:admin_user] || node.node_template&.admin_user || "pnadmin"
        # account is delegated from :node; no `account=` setter exists on NodeInstance.
      )

      provider_params = build_provider_params(
        region: region,
        instance_type: instance_type,
        instance: instance,
        node: node,
        options: options
      )

      cloud_result = provider_adapter.create_instance(provider_params)

      if cloud_result[:success]
        instance.update!(
          cloud_instance_id: cloud_result[:cloud_instance_id],
          private_ip_address: cloud_result[:private_ip_address],
          public_ip_address: cloud_result[:public_ip_address],
          status: normalize_status(cloud_result[:status])
        )

        if options[:allocate_public_ip] && cloud_result[:public_ip_address].blank?
          associate_public_ip(provider_adapter, instance, cloud_result[:cloud_instance_id])
        end

        # M1 Self-Serve Hardening — emit a billing meter row for the
        # `created` lifecycle event. Best-effort: a metering failure must
        # never abort a successful provision.
        record_meter_event(instance, "created")
        emit_provision_event(
          account: node.account, kind: "system.instance_provisioned", severity: :low,
          instance: instance, node: node,
          payload: { cloud_instance_id: cloud_result[:cloud_instance_id] }
        )

        Runtime::Result.ok(data: {
          instance: instance,
          cloud_instance_id: cloud_result[:cloud_instance_id]
        })
      else
        # `:failed` was used historically but isn't a valid NodeInstance status;
        # `:error` is the platform-standard terminal-failure state.
        mark_instance_errored(instance)
        emit_provision_event(
          account: node.account, kind: "system.instance_provision_failed", severity: :high,
          instance: instance, node: node,
          payload: { error: cloud_result[:error] || "Cloud provisioning failed" }
        )

        Runtime::Result.err(error: cloud_result[:error] || "Cloud provisioning failed", data: { instance: instance })
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[ProvisioningService] Provider error: #{e.message}")
      # The instance row is created before the provider call — a provider
      # exception must never leave it orphaned in :pending. Transition it to
      # the terminal :error state so it's visible as failed (and reapable).
      mark_instance_errored(instance)
      emit_provision_event(
        account: node.account, kind: "system.instance_provision_failed", severity: :high,
        instance: instance, node: node, payload: { error: e.message }
      )
      Runtime::Result.err(error: e.message, data: { instance: instance }.compact)
    rescue ArgumentError, ProvisioningError
      raise
    rescue StandardError => e
      Rails.logger.error("[ProvisioningService] Provisioning failed: #{e.message}")
      mark_instance_errored(instance)
      emit_provision_event(
        account: node.account, kind: "system.instance_provision_failed", severity: :high,
        instance: instance, node: node, payload: { error: e.message }
      )
      Runtime::Result.err(error: e.message, data: { instance: instance }.compact)
    end

    def self.terminate_instance(instance:)
      new.terminate_instance(instance: instance)
    end

    def terminate_instance(instance:)
      validate_instance!(instance)

      return Runtime::Result.err(error: "Instance has no cloud instance ID") unless instance.cloud_instance_id.present?

      provider_adapter = begin
        Providers::Registry.for_instance(instance)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      Rails.logger.info("[ProvisioningService] Terminating instance #{instance.name}")

      result = provider_adapter.terminate_instance(instance.cloud_instance_id)

      if result[:success]
        # Move directly to :terminated via AASM. `:terminating` was used
        # historically but isn't a valid NodeInstance status — the AASM
        # transition is single-step (running/stopped/error → terminated).
        instance.terminate! if instance.may_terminate?
        # M1 Self-Serve Hardening — meter the terminate event so the rollup
        # job can close out accrued hours for this instance.
        record_meter_event(instance, "terminated")
        Runtime::Result.ok
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[ProvisioningService] Terminate error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    end

    private

    def validate_node!(node)
      raise ArgumentError, "Node required" unless node
      raise ArgumentError, "Node must be a System::Node" unless node.is_a?(::System::Node)
      raise ProvisioningError, "Node is disabled" unless node.enabled
    end

    def validate_instance!(instance)
      raise ArgumentError, "Instance required" unless instance
      raise ArgumentError, "Instance must be a System::NodeInstance" unless instance.is_a?(::System::NodeInstance)
    end

    def generate_instance_name(node, options)
      base_name = options[:name] || "#{node.name}-instance"
      timestamp = Time.current.strftime("%Y%m%d%H%M%S")
      # Random suffix guards against name collisions when two instances are
      # provisioned for the same node within the same second — the timestamp
      # alone isn't unique at sub-second cadence, and `name` is unique per
      # node_id, so a bare timestamp would raise RecordInvalid on the second.
      "#{base_name}-#{timestamp}-#{SecureRandom.hex(2)}"
    end

    # Ensure a partially-provisioned instance never lingers in :pending after a
    # failure — transition it to the terminal :error state so it surfaces as
    # failed (and is reapable) instead of orphaned. Best-effort: a transition
    # failure must not mask the original provisioning error.
    def mark_instance_errored(instance)
      return unless instance.respond_to?(:persisted?) && instance.persisted?

      instance.mark_errored! if instance.may_mark_errored?
    rescue StandardError => e
      Rails.logger.warn("[ProvisioningService] failed to mark instance #{instance&.id} errored: #{e.class}: #{e.message}")
    end

    # Emit a provision-lifecycle FleetEvent (provisioned / provision_failed) so
    # the autonomy loop + operators can observe the provisioning pipeline that
    # was previously silent. Routed through EventBroadcaster, which persists +
    # broadcasts and is itself best-effort (never raises) — observability must
    # never break a provision.
    def emit_provision_event(account:, kind:, severity:, instance: nil, node: nil, payload: {})
      ::System::Fleet::EventBroadcaster.emit!(
        account: account,
        kind: kind,
        severity: severity,
        source: "provisioning_service",
        payload: payload,
        node_id: (node || instance&.node)&.id,
        node_instance_id: instance&.id
      )
    end

    def build_provider_params(region:, instance_type:, instance:, node:, options:)
      params = {
        name: instance.name,
        # hostname becomes /etc/hostname inside the guest (cloud-init
        # `hostname:` + DHCP option 12). Falls back to the unique
        # instance name if no explicit override was requested.
        hostname: options[:hostname].presence || instance.name,
        instance: instance,        # LocalQemuProvider requires the AR record
        node: node,                # adapters that need template/platform access
        instance_type: instance_type.name,
        image_id: region.machine_image,
        key_name: options[:key_name],
        security_groups: options[:security_groups],
        subnet_id: options[:subnet_id],
        network_id: options[:network_id],
        availability_zone: options[:availability_zone],
        options: options
      }

      # NodeTemplate stores init_script under its `config` JSONB blob (no
      # dedicated column). Honor an explicit user_data override first, then
      # fall through to the template's stored init_script.
      template_init = node.node_template&.config.is_a?(Hash) ?
                      (node.node_template.config["init_script"] || node.node_template.config[:init_script]) :
                      nil
      if options[:user_data].present?
        params[:user_data] = options[:user_data]
      elsif template_init.is_a?(String) && template_init.present?
        params[:user_data] = template_init
      end

      if options[:root_volume_size]
        params[:root_volume_size] = options[:root_volume_size]
        params[:root_volume_type] = options[:root_volume_type]
      end

      if options[:ssh_key].present?
        params[:ssh_key] = options[:ssh_key]
      elsif node.ssh_key.present?
        params[:ssh_key] = node.ssh_key
      end

      params[:tags] = {
        "powernode:node_id" => node.id,
        "powernode:instance_id" => instance.id,
        "powernode:account_id" => node.account_id,
        "Name" => instance.name
      }.merge(options[:tags] || {})

      # M4 Enterprise polish — when an account or delegation has an IP
      # allowlist configured, surface the resolved security-group rules
      # to the provider adapter. An empty result means "no allowlist
      # configured" — the adapter then falls through to its default
      # security_groups behavior, preserving pre-M4 semantics.
      ip_rules = ip_allowlist_rules_for(node, options)
      params[:security_group_rules] = ip_rules if ip_rules.any?

      params.compact
    end

    # Resolves the active IP allowlist for the provisioning context.
    # `options[:delegation]` lets callers (e.g. the provisioning
    # controller wired up to a delegated session) pass through the
    # acting delegation; otherwise we operate on the account scope only.
    def ip_allowlist_rules_for(node, options)
      return [] unless defined?(::System::IpAllowlistService)
      return [] unless node&.account

      ::System::IpAllowlistService.security_group_rules_for(
        account: node.account,
        delegation: options[:delegation]
      )
    rescue StandardError => e
      # An allowlist resolution failure must never abort a happy-path
      # provision — log and fall through to default rules instead.
      Rails.logger.warn("[ProvisioningService] ip_allowlist resolution failed: #{e.class}: #{e.message}")
      []
    end

    def associate_public_ip(provider_adapter, instance, cloud_instance_id)
      Rails.logger.info("[ProvisioningService] Associating public IP for #{instance.name}")

      result = provider_adapter.associate_ip(cloud_instance_id)

      if result[:success] && result[:public_ip].present?
        instance.update!(public_ip_address: result[:public_ip])
        Rails.logger.info("[ProvisioningService] Associated IP #{result[:public_ip]} to #{instance.name}")
      end
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.warn("[ProvisioningService] Failed to associate IP: #{e.message}")
    end

    # M1 Self-Serve Hardening — emit a Billing::ProvisioningUsageRecord for
    # one lifecycle event. Wrapped to swallow errors: meter failures must
    # never break a provisioning happy-path.
    def record_meter_event(instance, event)
      return unless defined?(::Billing::ProvisioningMeterService)
      ::Billing::ProvisioningMeterService.record_event(node_instance: instance, event: event)
    rescue StandardError => e
      Rails.logger.warn("[ProvisioningService] meter #{event} failed: #{e.class}: #{e.message}")
    end

    def normalize_status(status)
      case status
      when "pending", "starting" then "starting"
      when "running" then "running"
      when "stopping" then "stopping"
      when "stopped" then "stopped"
      when "terminating" then "terminating"
      when "terminated" then "terminated"
      else "pending"
      end
    end
  end
end
