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
    Result = Struct.new(:ok?, :node_id, :node_instance_id, :provider_type,
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
          name: spawn_target[:name] || "federation-spawn",
          # hostname becomes /etc/hostname inside the VM (cloud-init
          # `hostname:` + the netplan dhcp4-overrides.hostname that
          # feeds DHCP option 12). Without an explicit hint we fall
          # back to the unique instance name (e.g. ops2-20260527001135),
          # which is verbose but at least uniquely identifies the box.
          hostname: spawn_target[:hostname] || spawn_target["hostname"],
          # boot_mode dispatches ProxmoxProvider#create_instance between
          # cloud_init (default, pre-baked cloud image + cicustom seed)
          # and direct_kernel (Powernode-as-OS: -kernel -initrd -append
          # qemu args, no host OS). Templates targeting bare metal /
          # pivot_root deployments pass "direct_kernel" here; cloud-VM
          # spawns omit it and get the existing cloud_init path.
          # Template-level default precedence: template.config["boot_mode"]
          # if set, else spawn_target hint, else fall through to provider
          # default (cloud_init).
          boot_mode: spawn_target[:boot_mode] ||
                     spawn_target["boot_mode"] ||
                     (template&.config.is_a?(Hash) ? template.config["boot_mode"] : nil),
          # ssh_authorized_keys priority: explicit spawn_target override first,
          # then Node.config["authorized_keys"] as the operator-managed default
          # (set when the Node is created). Without this fallback, the operator
          # user gets stripped from cloud-init's users: block (cloud_seed rejects
          # users with empty ssh_authorized_keys), leaving the spawned VM
          # SSH-inaccessible — only the agent can phone home.
          ssh_authorized_keys: Array(spawn_target[:ssh_authorized_keys] ||
                                     spawn_target["ssh_authorized_keys"]).presence ||
                               Array(node.config&.[]("authorized_keys"))
        }
      )

      # Runtime::Result#success? is the standard convention used by
      # ProvisioningService; data is a Hash with :instance_id etc.
      if provisioning_result.respond_to?(:success?) && provisioning_result.success?
        data = provisioning_result.respond_to?(:data) ? provisioning_result.data : {}
        # ProvisioningService returns `data[:instance]` (the AR row) rather than
        # `data[:instance_id]` — accept either. Prior code only looked at the
        # latter, so node_instance_id silently came back as nil, breaking the
        # downstream federation_spawn stamp + the AcceptController's
        # node_enrollment lookup.
        instance = data[:instance] || data["instance"]
        instance_id = data[:instance_id] || data["instance_id"] || instance&.id
        instance ||= ::System::NodeInstance.find_by(id: instance_id) if instance_id

        # Stamp federation_spawn under NodeInstance#config (the jsonb
        # column on system_node_instances; there is no `metadata`
        # column). Downstream reconciliation correlates by reading
        # `config["federation_spawn"]`.
        if instance
          instance.update!(
            config: (instance.config || {}).merge(
              "federation_spawn" => payload
            )
          )
        end

        success(
          node_id: node.id,
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

      region_hint = (spawn_target[:region] || spawn_target["region"]).to_s.presence

      # An instance-type name (e.g. "pve.vm.medium") is provider-unique, so
      # it is the AUTHORITATIVE provider selector. The orchestrator passes it
      # as :instance_size; older callers pass :preset — honor both. Without
      # this the hint was dropped on the floor and resolution fell through to
      # "first connectable provider by created_at" (commonly local-qemu),
      # silently provisioning a PVE spawn on the wrong substrate.
      preset_hint = instance_type_hint(spawn_target)
      if preset_hint.present?
        it = ::System::ProviderInstanceType.find_by(name: preset_hint)
        if it
          # Within the pinned provider, honor a region-name hint when given
          # (disambiguates same-named regions across providers), else take
          # that provider's first connectable region.
          if region_hint
            named = ::System::ProviderRegion.find_by(provider_id: it.provider_id, name: region_hint)
            return named if named
          end
          region = first_region_for_connectable_provider(it.provider)
          return region if region
          owned = ::System::ProviderRegion.where(provider_id: it.provider_id).order(:created_at).first
          return owned if owned
        end
      end

      # A bare region-name hint with no usable instance-type hint: pick the
      # connectable provider that owns a region with that name, so a name
      # present under both a dead and a live provider lands on the live one.
      if region_hint
        named = region_by_name_preferring_connectable(region_hint)
        return named if named
      end

      # Prefer a region whose provider HAS an active connection in this
      # account's scope. Earlier behavior picked the first provider by
      # created_at — for accounts with multiple providers seeded (e.g.
      # "Pro Cloud" + "proxmox"), the older provider often has zero
      # configured connections, and the spawn died downstream in
      # registry.for_node with "No provider connection available for
      # region X". Pre-filter on connectable providers so the orchestrator
      # never picks a dead-on-arrival region. Falls back to the UNFILTERED
      # "first provider, first region" below, which is a live path — not a
      # legacy remnant: explicit-target flows and existing tests reach it
      # whenever no connectable provider/region pair exists. Deleting it
      # changes behavior.
      preferred_provider = node.respond_to?(:provider) ? node.provider : nil
      region = first_region_for_connectable_provider(preferred_provider)
      return region if region

      provider = ::System::Provider.where(account_id: @account.id).order(:created_at).first
      return nil unless provider

      ::System::ProviderRegion.where(provider_id: provider.id).order(:created_at).first
    end

    # Returns the first region belonging to a provider that has at least
    # one enabled + connected ProviderConnection visible to this account.
    # When preferred_provider is set, restricts to that provider (so we
    # respect the node's pinned provider when possible). Returns nil if
    # no such provider/region pair exists — the caller falls through to the
    # unfiltered "first provider, first region" default, which is live.
    def first_region_for_connectable_provider(preferred_provider)
      scope = ::System::ProviderConnection
                .enabled
                .connected
                .where("account_id = ? OR account_id IS NULL", @account&.id)
      scope = scope.where(provider_id: preferred_provider.id) if preferred_provider
      provider_ids = scope.order(:created_at).pluck(:provider_id).uniq
      return nil if provider_ids.empty?

      ::System::ProviderRegion
        .where(provider_id: provider_ids)
        .order(:created_at)
        .first
    end

    # Instance-type name hint. The orchestrator forwards the operator's
    # `instance_size` here; older spawn callers used `preset`. Both name a
    # ProviderInstanceType (provider-unique), which is what disambiguates the
    # target substrate.
    def instance_type_hint(spawn_target)
      (spawn_target[:preset] || spawn_target["preset"] ||
       spawn_target[:instance_size] || spawn_target["instance_size"]).to_s.presence
    end

    # Resolve a region by name, restricted to providers that have an enabled +
    # connected ProviderConnection in this account's scope. Falls back to any
    # region with that name if none of the matches are connectable.
    def region_by_name_preferring_connectable(region_hint)
      scope = ::System::ProviderConnection
                .enabled
                .connected
                .where("account_id = ? OR account_id IS NULL", @account&.id)
      connectable_ids = scope.pluck(:provider_id).uniq
      if connectable_ids.any?
        named = ::System::ProviderRegion
                  .where(name: region_hint, provider_id: connectable_ids)
                  .order(:created_at)
                  .first
        return named if named
      end
      ::System::ProviderRegion.where(name: region_hint).order(:created_at).first
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

      preset_hint = instance_type_hint(spawn_target)
      if preset_hint.present?
        type = ::System::ProviderInstanceType.find_by(
          name: preset_hint,
          provider_id: region.provider_id
        )
        return type if type
      end

      ::System::ProviderInstanceType
        .where(provider_id: region.provider_id)
        .order(:created_at)
        .first
    end

    def success(node_id: nil, node_instance_id:, provider_type:, cloud_id: nil)
      Result.new(
        ok?: true,
        node_id: node_id,
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
