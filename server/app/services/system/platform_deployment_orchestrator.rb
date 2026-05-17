# frozen_string_literal: true

module System
  # High-level orchestrator that turns a "deploy a new Powernode
  # platform" intent into a running NodeInstance. Composes the existing
  # primitives (NodeTemplate, ProvisioningService, SpawnPlatformService,
  # PlatformDeployment) so callers don't have to know which low-level
  # bits to wire together.
  #
  # Two modes:
  #
  #   - "standalone"  → fresh, sovereign platform. NO FederationPeer row.
  #                     The child platform comes up with its own admin
  #                     and runs unbound from this platform once boot
  #                     completes.
  #
  #   - "federated"   → spawned + federated. Delegates to
  #                     System::SpawnPlatformService.spawn! for the
  #                     existing P6 flow (managed_child / autonomous_peer
  #                     / cluster_member). The spawned child completes
  #                     a handshake on first boot.
  #
  # In both modes the orchestrator optionally creates a
  # System::PlatformDeployment row so the new platform shows up in the
  # /app/system/compute/platform Scaling panel right away.
  #
  # The orchestrator does NOT issue ACME certs itself — the spawned
  # platform's own AcmeCertificateRenewalJob handles that post-boot. It
  # does NOT allocate SDWAN VIPs either — those are template-driven
  # downstream. The orchestrator's job is to fire the provision + record
  # intent; the rest is the spawned platform's responsibility (which is
  # the point of Powernode being self-provisioning).
  class PlatformDeploymentOrchestrator
    class OrchestrationError < StandardError; end

    MODES = %w[standalone federated].freeze

    Result = Struct.new(
      :ok, :mode, :node_instance_id, :federation_peer_id, :platform_deployment_id,
      :acceptance_token, :spawn_payload, :storage_volume, :error, keyword_init: true
    ) do
      def ok?
        ok
      end
    end

    # Stateful service role policy — sizes + mount points — lives in
    # platform shared memory (key: powernode.storage_recommendations).
    # See System::Platform::StorageRecommendations for the read/write
    # surface. Operators tune via platform.write_shared_memory; the
    # orchestrator picks up new values on the next deploy with no
    # redeploy of the platform itself.

    class << self
      def deploy!(account:, mode:, params:, initiated_by_user: nil)
        new(account: account, initiated_by_user: initiated_by_user).deploy!(mode: mode, params: params)
      end
    end

    def initialize(account:, initiated_by_user: nil)
      @account = account
      @initiated_by_user = initiated_by_user
    end

    # @param mode [String] "standalone" | "federated"
    # @param params [Hash] required fields per mode:
    #   - standalone: { name, template_slug, region?, instance_size?, options? }
    #   - federated:  { name, template_slug, region?, instance_size?, parent_url,
    #                   spawn_mode (managed_child|autonomous_peer|cluster_member),
    #                   token_ttl_seconds?, options? }
    #   Both modes accept optional: { service_role, public_dns_hostname, record_deployment }
    def deploy!(mode:, params:)
      validate_mode!(mode)
      params = params.with_indifferent_access if params.is_a?(Hash) && !params.is_a?(ActiveSupport::HashWithIndifferentAccess)
      validate_common!(params)

      case mode.to_s
      when "standalone"
        deploy_standalone!(params)
      when "federated"
        deploy_federated!(params)
      end
    rescue OrchestrationError => e
      Result.new(ok: false, mode: mode.to_s, error: e.message)
    rescue StandardError => e
      Rails.logger.error("[PlatformDeploymentOrchestrator] #{e.class}: #{e.message}")
      Result.new(ok: false, mode: mode.to_s, error: "Orchestration failed: #{e.message}")
    end

    private

    def validate_mode!(mode)
      return if MODES.include?(mode.to_s)
      raise OrchestrationError, "Unknown mode #{mode.inspect}; supported: #{MODES.inspect}"
    end

    def validate_common!(params)
      raise OrchestrationError, "template_slug is required" if params[:template_slug].blank?
      raise OrchestrationError, "name is required" if params[:name].blank?
    end

    # ── Standalone path ──────────────────────────────────────────────
    #
    # Resolve template → node → region → instance_type, then call
    # ProvisioningService.provision_instance with NO federation_spawn
    # payload. The provisioned platform comes up sovereign (its first-run
    # handler creates a fresh admin account because there's no
    # parent_url in fw-cfg).
    def deploy_standalone!(params)
      template = resolve_template!(params[:template_slug])
      node = resolve_or_provision_node!(template, params)
      region = resolve_region!(node, params)
      instance_type = resolve_instance_type!(region, params)

      provision_result = ::System::ProvisioningService.provision_instance(
        node: node,
        provider_region_id: region.id,
        provider_instance_type_id: instance_type.id,
        options: {
          name: params[:name].to_s,
          deployment_mode: "standalone",
          standalone_deployment: true
        }
      )

      unless provision_result.respond_to?(:success?) && provision_result.success?
        msg = provision_result.respond_to?(:error) ? provision_result.error.to_s : "unknown error"
        raise OrchestrationError, "Provisioning failed: #{msg}"
      end

      # ProvisioningService returns data: { instance: <NodeInstance>, cloud_instance_id: ... }
      instance = provision_result.data[:instance] || provision_result.data["instance"]
      instance_id = instance&.id
      stamp_standalone_marker!(instance_id, params)

      volume_binding = attach_storage_volume!(instance, params) if instance

      deployment_id = maybe_record_deployment!(template, params, instance_id: instance_id)

      Result.new(
        ok: true,
        mode: "standalone",
        node_instance_id: instance_id,
        platform_deployment_id: deployment_id,
        storage_volume: volume_binding
      )
    end

    # ── Federated path ──────────────────────────────────────────────
    #
    # Delegates to the existing SpawnPlatformService.spawn! flow.
    # SpawnPlatformService already composes FederationPeer creation +
    # acceptance-token generation + provisioning via SpawnProvisioner.
    def deploy_federated!(params)
      spawn_mode = params[:spawn_mode].to_s
      unless ::System::SpawnPlatformService::SPAWN_MODES.include?(spawn_mode)
        raise OrchestrationError,
              "Invalid spawn_mode #{spawn_mode.inspect}; supported: #{::System::SpawnPlatformService::SPAWN_MODES.inspect}"
      end
      raise OrchestrationError, "parent_url is required for federated deployments" if params[:parent_url].blank?

      template = resolve_template!(params[:template_slug])

      provisioner = ::Federation::SpawnProvisioner.new(
        account: @account, current_user: @initiated_by_user
      )

      result = ::System::SpawnPlatformService.spawn!(
        account: @account,
        spawn_mode: spawn_mode,
        spawn_target: {
          template_id: template.name,
          region: params[:region],
          instance_size: params[:instance_size],
          name: params[:name].to_s
        }.compact,
        parent_url: params[:parent_url].to_s,
        initiated_by_user: @initiated_by_user,
        token_ttl_seconds: params[:token_ttl_seconds].presence&.to_i ||
                          ::System::SpawnPlatformService::DEFAULT_TOKEN_TTL,
        provisioner: provisioner
      )

      raise OrchestrationError, result.error unless result.ok?

      instance_id = result.spawn_payload&.dig("provisioner_response", :node_instance_id) ||
                    result.spawn_payload&.dig("provisioner_response", "node_instance_id")
      # SpawnProvisioner stamps the instance id into the federation_peer.metadata
      instance_id ||= result.federation_peer.metadata&.dig("provisioner_response", "node_instance_id") ||
                      result.federation_peer.metadata&.dig("provisioner_response", :node_instance_id)

      instance = ::System::NodeInstance.find_by(id: instance_id) if instance_id
      volume_binding = attach_storage_volume!(instance, params) if instance

      deployment_id = maybe_record_deployment!(template, params, instance_id: instance_id)

      Result.new(
        ok: true,
        mode: "federated",
        node_instance_id: instance_id,
        federation_peer_id: result.federation_peer.id,
        platform_deployment_id: deployment_id,
        acceptance_token: result.acceptance_token,
        spawn_payload: result.spawn_payload,
        storage_volume: volume_binding
      )
    end

    # ── Shared resolution ───────────────────────────────────────────

    def resolve_template!(slug_or_id)
      template = ::System::NodeTemplate
                   .where(account_id: @account.id)
                   .where("id::text = :v OR name = :v", v: slug_or_id.to_s)
                   .first
      template || raise(OrchestrationError, "template not found: #{slug_or_id}")
    end

    # Find a Node for the template. If none exists, auto-create one so
    # operators can deploy without first having to manually CRUD a Node
    # row — that's the "minimal intervention" target. Operators who
    # need a specific Node can still pass `node_id` explicitly.
    def resolve_or_provision_node!(template, params)
      if params[:node_id].present?
        node = ::System::Node.find_by(id: params[:node_id], account: @account)
        return node if node
        raise OrchestrationError, "node not found: #{params[:node_id]}"
      end

      existing = ::System::Node.where(account: @account, node_template_id: template.id).order(:created_at).first
      return existing if existing

      auto_node_name = "#{params[:name]}-node-#{Time.current.to_i.to_s(36)}"
      ::System::Node.create!(
        account: @account,
        node_template: template,
        name: auto_node_name,
        description: "Auto-created by PlatformDeploymentOrchestrator for deployment #{params[:name]}",
        enabled: true,
        lifecycle_class: "persistent",
        config: {}
      )
    rescue ActiveRecord::RecordInvalid => e
      raise OrchestrationError, "auto-create Node failed: #{e.message}"
    end

    # ProviderRegion is keyed on `provider_id` (not node_platform_id) so
    # we follow node → provider → provider_regions. Falls back to the
    # account's first Provider when the Node doesn't bind one.
    def resolve_region!(node, params)
      if params[:provider_region_id].present?
        region = ::System::ProviderRegion.find_by(id: params[:provider_region_id])
        return region if region
        raise OrchestrationError, "provider_region not found: #{params[:provider_region_id]}"
      end

      provider = node.respond_to?(:provider) ? node.provider : nil
      provider ||= ::System::Provider.where(account_id: @account.id).order(:created_at).first
      raise(OrchestrationError, "no provider available for account") unless provider

      region = ::System::ProviderRegion.where(provider_id: provider.id).order(:created_at).first
      region || raise(OrchestrationError, "no provider_region for provider #{provider.name}")
    end

    # ProviderInstanceType is keyed on `provider_id` (not region) per the
    # schema — follow region.provider_id, then pick the first type.
    def resolve_instance_type!(region, params)
      if params[:provider_instance_type_id].present?
        it = ::System::ProviderInstanceType.find_by(id: params[:provider_instance_type_id])
        return it if it
        raise OrchestrationError, "provider_instance_type not found: #{params[:provider_instance_type_id]}"
      end

      it = ::System::ProviderInstanceType
             .where(provider_id: region.provider_id)
             .order(:created_at).first
      it || raise(OrchestrationError, "no provider_instance_type for provider")
    end

    # Stamps a marker into NodeInstance#config so the new platform's
    # first-run handler knows it's standalone (no parent to call back to)
    # and skips the federation_api/accept POST.
    # Attach a ProviderVolume to the just-provisioned NodeInstance if
    # (a) the operator supplied `volume_id`, OR (b) the service role is
    # stateful and an unattached volume of matching size is available.
    # Returns a binding hash that the caller surfaces to the operator;
    # also stamps NodeInstance.config["storage_volume"] so the on-node
    # agent knows the device + mount point.
    #
    # Failure to attach is non-fatal — the instance is provisioned;
    # the operator gets a warning in the result envelope.
    def attach_storage_volume!(instance, params)
      return nil unless instance

      explicit_id = params[:volume_id].presence
      role = (params[:service_role] || "api").to_s
      role_is_stateful = ::System::Platform::StorageRecommendations.stateful_role?(
        account: @account, role: role
      )

      # Skip-attach: operator explicitly opted out of volume binding
      return nil if params[:skip_volume] || params[:volume_attach] == false

      volume =
        if explicit_id.present?
          ::System::ProviderVolume.find_by(id: explicit_id, account: @account)
        elsif role_is_stateful
          auto_select_volume_for(role)
        end

      return nil unless volume

      unless volume.can_attach?
        Rails.logger.warn("[PlatformDeploymentOrchestrator] volume #{volume.id} is not attachable (status=#{volume.status}, attached=#{volume.attached?})")
        return { error: "volume_not_attachable", volume_id: volume.id, status: volume.status }
      end

      mount_point = ::System::Platform::StorageRecommendations.mount_point_for(
        account: @account, role: role
      )

      # Branch on transport. Block volumes get a /dev/vdX device name +
      # `attach_to!(instance, device_name)` which flips status to
      # in-use, locking the volume to one instance. NFS / SMB / iSCSI
      # are *pools* — many deployments can share one export, isolated
      # by subpath. For those we skip the row-level status flip so the
      # volume remains `available` for other consumers; the per-deploy
      # binding is captured on NodeInstance.config["storage_volume"]
      # instead of on the ProviderVolume row.
      vt_kind = volume.volume_type&.volume_type.to_s
      is_network_fs = %w[nfs smb iscsi].include?(vt_kind)
      device_name = is_network_fs ? nil : next_device_name_for(instance)

      if is_network_fs
        # Pool semantics — no status flip, no exclusive node_instance_id.
        # Just record the per-consumer binding on the instance side.
        attached = true
      else
        attached = volume.attach_to!(instance, device_name)
      end
      return { error: "volume_attach_failed", volume_id: volume.id } unless attached

      binding = {
        volume_id: volume.id,
        volume_name: volume.name,
        size_gb: volume.size_gb,
        transport: is_network_fs ? vt_kind : "block",
        mount_type: is_network_fs ? vt_kind : "device",
        device_name: device_name,
        mount_point: mount_point,
        role: role,
        attached_at: Time.current.iso8601
      }

      # For network-attached storage, also stamp the per-transport
      # connection details + compute a subpath under the export root
      # so multiple deployments can share one NFS pool without
      # colliding. The on-node agent mounts <server>:<export>/<subpath>
      # rather than the bare export, giving every (deployment, role)
      # pair its own isolated directory.
      if is_network_fs && volume.config.is_a?(Hash) && volume.config[vt_kind].is_a?(Hash)
        transport_cfg = volume.config[vt_kind].dup
        subpath = ::System::Platform::StorageLayout.subpath_for(
          deployment_name: params[:name].to_s,
          role: role
        )
        transport_cfg["subpath"] = subpath
        transport_cfg["full_export_path"] = ::System::Platform::StorageLayout.full_nfs_path(
          volume: volume,
          deployment_name: params[:name].to_s,
          role: role
        )
        binding[vt_kind] = transport_cfg
        binding[:subpath] = subpath
      end

      instance.update!(
        config: (instance.config || {}).merge("storage_volume" => binding)
      )

      binding
    rescue StandardError => e
      Rails.logger.warn("[PlatformDeploymentOrchestrator] storage attach failed: #{e.message}")
      { error: e.message }
    end

    # Picks the smallest unattached volume that's at least the role's
    # recommended size. Preference: status="available" + matching region
    # if the instance has one. Returns nil if no candidate.
    def auto_select_volume_for(role)
      min_size = ::System::Platform::StorageRecommendations.recommended_size_gb(
        account: @account, role: role
      )
      scope = ::System::ProviderVolume
                .where(account: @account, status: "available", node_instance_id: nil)
                .where("size_gb >= ?", min_size)
                .order(:size_gb, :created_at)
      scope.first
    rescue StandardError
      nil
    end

    # Picks the next /dev/vd<x> letter for the instance. Cloud providers
    # commonly use vd[b-z] for additional disks (vda is the boot disk).
    def next_device_name_for(instance)
      attached_devices = ::System::ProviderVolume
                           .where(node_instance_id: instance.id)
                           .pluck(:device_name).compact
      ("b".."z").each do |letter|
        candidate = "/dev/vd#{letter}"
        return candidate unless attached_devices.include?(candidate)
      end
      "/dev/vdb" # fallback if all letters used (extremely unlikely)
    end

    def stamp_standalone_marker!(instance_id, params)
      return if instance_id.blank?
      instance = ::System::NodeInstance.find_by(id: instance_id)
      return unless instance

      marker = {
        "deployment_mode" => "standalone",
        "deployment_name" => params[:name].to_s,
        "initiated_at" => Time.current.iso8601,
        "initiated_by_user_id" => @initiated_by_user&.id
      }.compact
      instance.update!(config: (instance.config || {}).merge("standalone_deployment" => marker))
    rescue StandardError => e
      Rails.logger.warn("[PlatformDeploymentOrchestrator] could not stamp standalone marker: #{e.message}")
    end

    # Optionally creates a PlatformDeployment row so the new platform
    # shows up in the Scaling panel with target_replicas=1 + actual=1.
    # Operators can grow it from there.
    def maybe_record_deployment!(template, params, instance_id:)
      return nil unless params.fetch(:record_deployment, true)

      service_role = params[:service_role].presence || "api"
      hostname = params[:public_dns_hostname].presence
      name = uniqueify_deployment_name(params[:name].to_s)

      ::System::PlatformDeployment.create!(
        account: @account,
        node_template: template,
        name: name,
        service_role: service_role,
        target_replicas: 1,
        public_dns_hostname: hostname,
        metadata: {
          "deployed_at" => Time.current.iso8601,
          "deployed_by_user_id" => @initiated_by_user&.id,
          "initial_instance_id" => instance_id
        }.compact
      ).id
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[PlatformDeploymentOrchestrator] PlatformDeployment record skipped: #{e.message}")
      nil
    end

    # Names must be unique within account; if collision, suffix with a
    # short timestamp slug.
    def uniqueify_deployment_name(base)
      return base unless ::System::PlatformDeployment.where(account: @account)
                                                     .where("LOWER(name) = ?", base.downcase)
                                                     .exists?
      "#{base}-#{Time.current.to_i.to_s(36)}"
    end
  end
end
