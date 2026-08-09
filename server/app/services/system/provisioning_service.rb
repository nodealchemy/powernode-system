# frozen_string_literal: true

module System
  # Provisions cloud instances via provider adapters and returns
  # System::Runtime::Result. Provider adapters below this layer keep their
  # cloud-shape hash (`success:, cloud_instance_id:, ...`) — this service
  # is the boundary that maps that into the platform-standard Result.
  class ProvisioningService
    # RCP v2 (campaign 019f9250, increment p0c) — INV-1: no self-management.
    # Nil-safe / inert until an operator configures self_hosting_node_id
    # (not performed by this increment — see
    # System::Autonomy::SelfManagementFence's doc comment for why this is a
    # distinct concern from the existing ControlPlaneFence).
    include ::System::Autonomy::SelfManagementFence
    include ::System::DevCellDeployKeyRevocation

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
      # INV-1 — refuse to provision an instance onto this deployment's own
      # hosting node (no-op / fully inert while self_hosting_node_id is
      # unconfigured, which is every plane today).
      assert_not_self_managed!(node, action: "provision an instance onto")

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

      # Capability gate (F4-06) — refuse before creating the instance row.
      unless provider_adapter.supports?(:instances)
        return Runtime::Result.err(error: "Provider #{provider_adapter.provider_type} does not support instance provisioning")
      end

      # RCP v2 (campaign 019f9250, increment p0c) — INV-2 (no boot-time
      # network dependency) + INV-6 (member storage = local disk, no shared
      # NFS root). Opt-in via options[:rcp_member_provisioning]: true —
      # NOT a blanket check on every provision. Today's default Proxmox
      # connection has no cidata_transport: "iso" opt-in, and existing
      # federation spawns intentionally ride the NFS cicustom channel even
      # in uefi_disk boot_mode (see BootPathInvariantCheck's doc comment) —
      # blanket-rejecting could break that live, working path. Callers that
      # ARE provisioning an actual RCP consensus member (P1-a/P1-d) opt in
      # explicitly to get the hard guarantee; everyone else is unaffected
      # (zero behavior change on the existing default path).
      if options[:rcp_member_provisioning]
        violation = rcp_member_boot_path_violation(node: node, provider_adapter: provider_adapter, region: region, options: options) ||
                    rcp_member_storage_violation(node: node, provider_adapter: provider_adapter, region: region, options: options)
        return Runtime::Result.err(error: violation[:detail], data: violation) if violation
      end

      Rails.logger.info("[ProvisioningService] Provisioning instance for node #{node.name} in #{region.name} using #{provider_adapter.provider_type}")

      # Idempotency — a retried call carrying the same operation_id must not
      # spin up a second instance. Reuse a prior instance tagged with this
      # operation_id unless it ended in a terminal state (terminated/error) —
      # a retry after a hard failure must provision fresh, not return the
      # dead row. A unique index on config->>'operation_id' would
      # harden this against concurrent racers; the check-then-create here
      # covers the common sequential-retry case.
      if operation_id.present?
        existing = ::System::NodeInstance
                     .where(node_id: node.id)
                     .where("config->>'operation_id' = ?", operation_id.to_s)
                     .where.not(status: %w[terminated error])
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

      # F1 (IMP 019fe4c4-b373): success without a provider identity is not
      # success. A row that reaches a live status with no cloud_instance_id is
      # a phantom nothing can sync, reap, or terminate — and whose enrollment
      # seed may be live on shared storage for some OTHER VM to boot with.
      if cloud_result[:success] && cloud_result[:cloud_instance_id].blank?
        Rails.logger.error(
          "[ProvisioningService] provider #{provider_adapter.provider_type} reported success " \
            "WITHOUT a cloud_instance_id for #{instance.name} — treating as failed"
        )
        cloud_result = { success: false,
                         error: "provider returned success without a cloud_instance_id" }
      end

      if cloud_result[:success]
        # Capture the just-created cloud instance id BEFORE the persisting
        # update! (or any later step) that could raise. If one does, the row is
        # marked :error WITHOUT this id ever reaching the DB, so the reaper can't
        # reclaim the now-orphaned, billable cloud VM. Holding it in a local lets
        # the rescue paths terminate it (compensating rollback).
        created_cloud_instance_id = cloud_result[:cloud_instance_id]

        instance.update!(
          cloud_instance_id: cloud_result[:cloud_instance_id],
          private_ip_address: cloud_result[:private_ip_address],
          public_ip_address: cloud_result[:public_ip_address],
          status: normalize_status(cloud_result[:status])
        )

        apply_node_template(node)

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
        # Increment 13 — provision-time SDWAN auto-enrollment. Best-effort:
        # an overlay-join failure must never fail an otherwise-successful
        # provision, same posture as the metering/event calls above.
        auto_enroll_sdwan_peer!(instance, node)

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
      terminate_orphaned_cloud_instance(provider_adapter, created_cloud_instance_id)
      emit_provision_event(
        account: node.account, kind: "system.instance_provision_failed", severity: :high,
        instance: instance, node: node, payload: { error: e.message }
      )
      Runtime::Result.err(error: e.message, data: { instance: instance }.compact)
    rescue ArgumentError, ProvisioningError, ::System::Autonomy::SelfManagementFence::SelfManagementViolation
      raise
    rescue StandardError => e
      Rails.logger.error("[ProvisioningService] Provisioning failed: #{e.message}")
      mark_instance_errored(instance)
      terminate_orphaned_cloud_instance(provider_adapter, created_cloud_instance_id)
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
      # INV-1 — refuse to terminate this deployment's own hosting node's
      # instance (no-op / fully inert while self_hosting_node_id is
      # unconfigured).
      assert_not_self_managed!(instance, action: "terminate")

      return Runtime::Result.err(error: "Instance has no cloud instance ID") unless instance.cloud_instance_id.present?

      provider_adapter = begin
        Providers::Registry.for_instance(instance)
      rescue Providers::Registry::UnknownProviderError => e
        return Runtime::Result.err(error: e.message)
      end

      Rails.logger.info("[ProvisioningService] Terminating instance #{instance.name}")

      result = provider_adapter.terminate_instance(instance.cloud_instance_id)

      # Idempotent terminate (F4-02): a provider-side NotFound means the
      # resource is already gone (e.g. a prior terminate destroyed it while
      # the row stayed non-terminal) — finalize the row instead of erroring.
      # Mirrors BaseProvider#sync_status's NotFound→terminated mapping.
      if not_found_result?(result)
        Rails.logger.warn("[ProvisioningService] Terminate: provider resource #{instance.cloud_instance_id} already gone — finalizing #{instance.name}")
        finalize_termination!(instance)
        return Runtime::Result.ok
      end

      if result[:success]
        finalize_termination!(instance)
        Runtime::Result.ok
      else
        Runtime::Result.err(error: result[:error])
      end
    rescue Providers::BaseProvider::ResourceNotFoundError => e
      Rails.logger.warn("[ProvisioningService] Terminate: resource already gone (#{e.message}) — finalizing #{instance.name}")
      finalize_termination!(instance)
      Runtime::Result.ok
    rescue Providers::BaseProvider::ProviderError => e
      Rails.logger.error("[ProvisioningService] Terminate error: #{e.message}")
      Runtime::Result.err(error: e.message)
    rescue ArgumentError
      raise
    end

    private

    # The terminate AASM event covers every non-terminal status, so a false
    # may_terminate? only means the row is already terminated — warn (don't
    # silently pretend a transition happened) and skip re-metering so an
    # idempotent retry can't double-close the instance's accrued hours.
    def finalize_termination!(instance)
      # Increment 13 — detach unconditionally, ahead of the may_terminate?
      # guard: every call into finalize_termination! (fresh terminate, the
      # idempotent NotFound/ResourceNotFoundError paths, and a redundant
      # retry against an already-terminated row) means the underlying
      # instance is gone or going — a leaked SDWAN peer must not survive
      # any of those, and Sdwan::PeerDetacher is itself a no-op once the
      # peer is already gone.
      auto_detach_sdwan_peer!(instance)

      # Increment 21 — a recycled/terminated dev-cell must not leave a live
      # read-write deploy key on the source repo (or its private key in Vault).
      # Best-effort + guarded like the peer detach above: a revoke failure must
      # never block the terminate transition.
      revoke_dev_cell_deploy_key!(instance)

      unless instance.may_terminate?
        Rails.logger.warn("[ProvisioningService] Instance #{instance.name} already #{instance.status} — skipping terminate transition and meter event")
        return
      end

      instance.terminate!
      # M1 Self-Serve Hardening — meter the terminate event so the rollup
      # job can close out accrued hours for this instance.
      record_meter_event(instance, "terminated")
    end

    # Same NotFound detection as BaseProvider#sync_status: an error hash with
    # error_code "NotFound" (aws/gcp) or a "not found" message.
    def not_found_result?(result)
      return false unless result.is_a?(Hash) && !result[:success]

      result[:error_code].to_s.casecmp?("NotFound") || result[:error].to_s.match?(/not found/i)
    end

    def validate_node!(node)
      raise ArgumentError, "Node required" unless node
      raise ArgumentError, "Node must be a System::Node" unless node.is_a?(::System::Node)
      raise ProvisioningError, "Node is disabled" unless node.enabled
    end

    # RCP v2 INV-2 — non-raising violation check (see the options[:rcp_
    # member_provisioning] gate above). Mirrors ProxmoxProvider's own
    # boot_mode + payload resolution precedence closely enough for the
    # common case (an explicit options[:boot_mode]/[:user_data] override
    # takes precedence, else the node's template).
    #
    # provider_config is read from provider_adapter.connection — NOT
    # region.provider — because ProxmoxProvider#cidata_iso_transport? reads
    # ONLY the resolved ProviderConnection's own config, with no fallback to
    # the parent Provider (unlike default_storage below, which DOES fall
    # back — see #rcp_member_storage_violation and ProxmoxProvider#pve_
    # credential). Reading region.provider&.config here would silently miss
    # a connection-level cidata_transport override.
    def rcp_member_boot_path_violation(node:, provider_adapter:, region:, options:)
      tmpl_config = node.node_template&.config.is_a?(Hash) ? node.node_template.config : {}
      boot_mode = (options[:boot_mode].presence || tmpl_config["boot_mode"] || tmpl_config[:boot_mode]).to_s
      boot_mode = "cloud_init" if boot_mode.blank?
      payload_present = options[:user_data].present? || options[:spawn_payload].present?

      ::System::Autonomy::BootPathInvariantCheck.violation_for(
        provider_type: provider_adapter.provider_type,
        boot_mode: boot_mode,
        provider_config: provider_adapter.respond_to?(:connection) ? provider_adapter.connection&.config : nil,
        payload_present: payload_present,
        node: node
      )
    end

    # RCP v2 INV-6 — non-raising violation check. An undetermined live
    # answer (network_backed_storage? => nil) FAILS CLOSED here: the caller
    # explicitly opted into options[:rcp_member_provisioning], so "couldn't
    # verify" must not silently pass as "must be fine".
    #
    # storage_name resolution mirrors ProxmoxProvider#pve_credential's own
    # precedence for default_storage: an explicit per-call override, else
    # the resolved ProviderConnection's config, else its parent Provider's
    # config (that key DOES fall back, unlike cidata_transport above).
    def rcp_member_storage_violation(node:, provider_adapter:, region:, options:)
      connection = provider_adapter.respond_to?(:connection) ? provider_adapter.connection : nil
      connection_storage = connection&.config.is_a?(Hash) ? connection.config["default_storage"] : nil
      provider_storage = connection&.provider&.config.is_a?(Hash) ? connection.provider.config["default_storage"] : nil
      storage_name = options[:storage].presence || connection_storage.presence || provider_storage
      return nil if storage_name.blank?

      network_backed = ::System::Autonomy::StorageLocalityCheck.network_backed_storage?(
        provider_adapter: provider_adapter, region_code: region.name, storage_name: storage_name
      )

      if network_backed.nil?
        return {
          invariant: "INV-6", severity: :high, node_id: node.id, storage_name: storage_name, verified: false,
          detail: "could not verify storage #{storage_name.inspect} is local (INV-6 strict mode " \
                  "requires a live, confirmed answer) — refusing under strict RCP member provisioning"
        }
      end

      ::System::Autonomy::StorageLocalityCheck.violation_for(
        storage_name: storage_name, network_backed: network_backed, node: node
      )
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

    # Compensating rollback for a post-create failure: the cloud VM was already
    # created (so it's running and billable), but a later step (e.g. update!)
    # raised before its id reached the DB — leaving the reaper unable to reclaim
    # it. Best-effort terminate it by the id captured at create time. Guarded by
    # its own rescue so a terminate failure never masks the original error.
    def terminate_orphaned_cloud_instance(provider_adapter, cloud_instance_id)
      return if cloud_instance_id.blank?
      return unless provider_adapter.respond_to?(:terminate_instance)

      Rails.logger.warn("[ProvisioningService] Post-create failure — terminating orphaned cloud instance #{cloud_instance_id} to avoid a billable leak")
      provider_adapter.terminate_instance(cloud_instance_id)
    rescue StandardError => e
      Rails.logger.error("[ProvisioningService] Failed to terminate orphaned cloud instance #{cloud_instance_id}: #{e.class}: #{e.message}")
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

      # NodeTemplate stores boot_mode under its `config` JSONB blob too
      # (no dedicated column) — same pattern as init_script above. Honor
      # an explicit options override first (e.g. SpawnProvisioner already
      # threads template.config["boot_mode"] through as an option), then
      # fall through to the template's stored boot_mode directly so
      # callers that never set options at all (e.g. pool replenishment,
      # instance_pool_service.rb) still get the template's boot_mode
      # instead of silently defaulting to the provider's cloud_init path.
      # Templates without a boot_mode in config are unaffected — params
      # simply omits the key and each provider adapter falls back to its
      # own default (cloud_init for ProxmoxProvider, direct_kernel for
      # LocalQemuProvider).
      template_boot_mode = node.node_template&.config.is_a?(Hash) ?
                          (node.node_template.config["boot_mode"] || node.node_template.config[:boot_mode]) :
                          nil
      if options[:boot_mode].present?
        params[:boot_mode] = options[:boot_mode]
      elsif template_boot_mode.is_a?(String) && template_boot_mode.present?
        params[:boot_mode] = template_boot_mode
      end

      if options[:root_volume_size]
        params[:root_volume_size] = options[:root_volume_size]
        params[:root_volume_type] = options[:root_volume_type]
      end

      # Explicit placement pins. Proxmox's create_instance already reads
      # top-level params[:vmid]/[:storage]/[:cidata_iso_storage] (see
      # ProxmoxProvider#create_vm_instance / #create_uefi_disk_vm_instance /
      # #stage_cidata_iso) but until now nothing threaded the caller's
      # options hash into them — every provision silently auto-selected
      # (cluster/nextid; first *shared* storage with the right content
      # type), which could never land on a node-local, non-shared pool
      # (e.g. a consensus-group member that must sit on one node's
      # independent local storage, not a cluster-shared NFS export).
      # Additive only: unused by every other provider adapter (aws/gcp/
      # azure/openstack/local_qemu/mock/pro_cloud), and a no-op for any
      # existing caller that doesn't pass these options.
      params[:vmid] = options[:vmid] if options[:vmid].present?
      params[:storage] = options[:storage] if options[:storage].present?
      params[:cidata_iso_storage] = options[:cidata_iso_storage] if options[:cidata_iso_storage].present?
      # Optional override for where a uefi_disk boot image is STAGED, which is a
      # different question from where the disks live: `import` is a content type
      # block-backed storages cannot carry at all. Omit it and the provider picks
      # an import-capable storage itself (ProxmoxProvider#resolve_import_storage!);
      # set it when the auto-pick would choose a storage you don't want written to.
      params[:import_storage] = options[:import_storage] if options[:import_storage].present?

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

    # Layer-1 fix (campaign 019f3458): TemplateApplyService previously had no
    # caller anywhere in the real provisioning path, so a node's assignments
    # never reflected its template's full closure. Called unconditionally —
    # TemplateApplyService#apply! already no-ops gracefully (ok: false) when
    # a node has no template, so no guard is needed here. Best-effort:
    # a template-apply failure must never turn a successful provision into
    # a failed one.
    def apply_node_template(node)
      result = ::System::TemplateApplyService.new(node).apply!
      unless result.ok?
        Rails.logger.warn("[ProvisioningService] template apply reported failure for node #{node.name}: #{result.errors.join(', ')}")
      end
    rescue StandardError => e
      Rails.logger.warn("[ProvisioningService] template apply raised for node #{node.name}: #{e.class}: #{e.message}")
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

    # Increment 13 — resolves the opt-in SDWAN overlay for a just-provisioned
    # node. Precedence: instance-pool metadata (System::InstancePool#metadata
    # ["sdwan_network_id"]) overrides the NodeTemplate default, so a single
    # shared template can seed pools bound to different overlays. Neither
    # NodeTemplate nor InstancePool need a migration — both already carry a
    # JSONB config/metadata blob (mirrors the existing node_template.config
    # ["init_script"] / pool.metadata["ready_ttl_seconds"] idiom used
    # elsewhere in this file and in InstancePoolService).
    #
    # Returns nil when no opt-in is configured, or when the configured id
    # doesn't resolve to an Sdwan::Network in this node's account (a
    # cross-account id can never come from this account's own UI/API, but a
    # dangling id after a network was deleted must not raise here).
    def sdwan_network_for(node)
      pool_config = node.config.is_a?(Hash) ? node.config : {}
      pool_id = pool_config["instance_pool_id"] || pool_config[:instance_pool_id]

      if pool_id.present?
        pool = ::System::InstancePool.find_by(id: pool_id)
        pool_metadata = pool&.metadata.is_a?(Hash) ? pool.metadata : {}
        pool_network_id = pool_metadata["sdwan_network_id"] || pool_metadata[:sdwan_network_id]
        return ::Sdwan::Network.find_by(id: pool_network_id, account_id: node.account_id) if pool_network_id.present?
      end

      template_config = node.node_template&.config.is_a?(Hash) ? node.node_template.config : {}
      template_network_id = template_config["sdwan_network_id"] || template_config[:sdwan_network_id]
      return nil if template_network_id.blank?

      ::Sdwan::Network.find_by(id: template_network_id, account_id: node.account_id)
    end

    # Best-effort — an overlay-join failure (or the Sdwan extension being
    # absent from a given deployment) must never fail an otherwise-successful
    # provision. Mirrors the `defined?(::Billing::ProvisioningQuotaGuard)`
    # extension-boundary guard used earlier in this file.
    def auto_enroll_sdwan_peer!(instance, node)
      return unless defined?(::Sdwan::PeerEnroller)

      network = sdwan_network_for(node)
      return unless network

      # Idempotent — a redundant call (e.g. a retried finalize) must not
      # double-enroll the same instance into the same overlay.
      return if ::Sdwan::Peer.exists?(sdwan_network_id: network.id, node_instance_id: instance.id)

      ::Sdwan::PeerEnroller.call(network: network, node_instance: instance)
    rescue StandardError => e
      Rails.logger.error("[ProvisioningService] SDWAN auto-enroll failed for instance #{instance.id}: #{e.class}: #{e.message}")
    end

    # Best-effort inverse of auto_enroll_sdwan_peer! — called from
    # finalize_termination! for every terminate path (pool drain, pool
    # recycle, direct operator/MCP terminate). Sdwan::PeerDetacher is itself
    # a no-op when the instance has no SDWAN membership, so the exists?
    # guard here is purely to skip the (cheap) call in the common case.
    def auto_detach_sdwan_peer!(instance)
      return unless defined?(::Sdwan::PeerDetacher)
      return unless ::Sdwan::Peer.exists?(node_instance_id: instance.id)

      ::Sdwan::PeerDetacher.call(node_instance: instance)
    rescue StandardError => e
      Rails.logger.error("[ProvisioningService] SDWAN auto-detach failed for instance #{instance.id}: #{e.class}: #{e.message}")
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
