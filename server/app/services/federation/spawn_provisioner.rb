# frozen_string_literal: true

module Federation
  # Adapter that bridges System::SpawnPlatformService to the existing
  # System::ProvisioningService + provider layer. Conforms to
  # SpawnPlatformService's provisioner interface
  # (`provision!(payload:, spawn_target:)`).
  #
  # Resolution order for spawn_target hints (each falls back to the
  # account's first matching record when absent):
  #
  #   - node_id         → falls back to first Node matching the template_id
  #   - provider_region_id → falls back to the node's first available region
  #   - provider_instance_type_id → falls back to the region's first instance type
  #
  # The spawn payload (parent_url + acceptance_token + spawn_mode etc.) is:
  #   1. Stashed on the NodeInstance via metadata["federation_spawn"]
  #   2. Forwarded into the provider via options[:spawn_payload]
  #
  # LocalQemu::CloudSeed picks it up from either path and renders the
  # fw-cfg entries the agent's first-run handler reads.
  #
  # Plan reference: Decentralized Federation §H + P6.7.
  class SpawnProvisioner
    Result = Struct.new(:ok?, :node_instance_id, :provider_type,
                        :cloud_id, :error, keyword_init: true)

    def initialize(account:, current_user: nil)
      @account = account
      @current_user = current_user
    end

    # Conforms to SpawnPlatformService's provisioner contract — but
    # rather than returning a plain Hash, returns a normalized Result.
    # SpawnPlatformService stashes whatever provisioner.provision! returns
    # under `peer.metadata.provisioner_response`, so we keep both shapes
    # by converting to_h at the boundary.
    def provision!(payload:, spawn_target:)
      template_id = spawn_target[:template_id] || spawn_target["template_id"]
      return failure("template_id required").to_h unless template_id.present?

      template = resolve_template(template_id)
      return failure("template not found: #{template_id}").to_h unless template

      node = resolve_node(spawn_target, template)
      return failure("no host Node available for template #{template.name}").to_h unless node

      region = resolve_region(spawn_target, node)
      return failure("no provider_region available for node #{node.name}").to_h unless region

      instance_type = resolve_instance_type(spawn_target, region)
      return failure("no provider_instance_type available for region #{region.name}").to_h unless instance_type

      # Stash spawn payload + run the existing pipeline. Options are
      # forwarded into the provider's create_instance via
      # ProvisioningService#build_provider_params.
      provisioning_result = ::System::ProvisioningService.provision_instance(
        node: node,
        provider_region_id: region.id,
        provider_instance_type_id: instance_type.id,
        options: {
          spawn_payload: payload,
          name: spawn_target[:name] || "federation-spawn"
        }
      )

      # Runtime::Result#success? is the standard convention used by
      # ProvisioningService; data is a Hash with :instance_id etc.
      if provisioning_result.respond_to?(:success?) && provisioning_result.success?
        data = provisioning_result.respond_to?(:data) ? provisioning_result.data : {}
        instance_id = data[:instance_id] || data["instance_id"]

        # Stamp federation_spawn under NodeInstance#config (the jsonb
        # column on system_node_instances; there is no `metadata`
        # column). Downstream reconciliation correlates by reading
        # `config["federation_spawn"]`.
        if instance_id
          instance = ::System::NodeInstance.find_by(id: instance_id)
          if instance
            instance.update!(
              config: (instance.config || {}).merge(
                "federation_spawn" => payload
              )
            )
          end
        end

        success(
          node_instance_id: instance_id,
          provider_type: resolve_provider_type(node, region),
          cloud_id: data[:cloud_instance_id] || data["cloud_instance_id"]
        ).to_h
      else
        error_msg = if provisioning_result.respond_to?(:error) && provisioning_result.error.present?
                      provisioning_result.error.to_s
        else
                      "unknown provisioning error"
        end
        failure("provisioning failed: #{error_msg}").to_h
      end
    rescue StandardError => e
      ::Rails.logger.error("[Federation::SpawnProvisioner] #{e.class}: #{e.message}")
      failure("provisioning raised: #{e.message}").to_h
    end

    private

    # NodeTemplate is keyed on (account_id, name) by the platform seeds
    # (no `slug` column). The frontend's spawn modal passes the name as
    # template_id (e.g. "powernode-hub"); we accept either the literal
    # UUID id OR the name for operator convenience.
    def resolve_template(template_id_or_name)
      ::System::NodeTemplate
        .where(account_id: @account.id)
        .where("id::text = :v OR name = :v", v: template_id_or_name.to_s)
        .first
    end

    def resolve_node(spawn_target, template)
      explicit_id = spawn_target[:node_id] || spawn_target["node_id"]
      if explicit_id.present?
        node = ::System::Node.find_by(id: explicit_id, account_id: @account.id)
        return node if node
      end

      # Fall back to the first Node bound to this template.
      ::System::Node
        .where(account_id: @account.id, node_template_id: template.id)
        .order(:created_at)
        .first
    end

    def resolve_region(spawn_target, node)
      explicit_id = spawn_target[:provider_region_id] || spawn_target["provider_region_id"]
      if explicit_id.present?
        region = ::System::ProviderRegion.find_by(id: explicit_id)
        return region if region
      end

      # Default to the first region of the node's provider.
      provider = node.respond_to?(:provider) ? node.provider : nil
      provider ||= ::System::Provider.where(account_id: @account.id).order(:created_at).first
      return nil unless provider

      ::System::ProviderRegion.where(provider_id: provider.id).order(:created_at).first
    end

    def resolve_provider_type(node, region)
      return node.provider_type if node.respond_to?(:provider_type) && node.provider_type.present?
      provider = region&.provider
      provider&.provider_type || "unknown"
    end

    # ProviderInstanceType is scoped by `provider_id` (not region) per the
    # current schema. We follow the region → provider link, then pick the
    # first available type for that provider.
    def resolve_instance_type(spawn_target, region)
      explicit_id = spawn_target[:provider_instance_type_id] ||
                    spawn_target["provider_instance_type_id"]
      if explicit_id.present?
        type = ::System::ProviderInstanceType.find_by(id: explicit_id)
        return type if type
      end

      ::System::ProviderInstanceType
        .where(provider_id: region.provider_id)
        .order(:created_at)
        .first
    end

    def success(node_instance_id:, provider_type:, cloud_id: nil)
      Result.new(
        ok?: true,
        node_instance_id: node_instance_id,
        provider_type: provider_type,
        cloud_id: cloud_id
      )
    end

    def failure(message)
      Result.new(ok?: false, error: message)
    end
  end
end
