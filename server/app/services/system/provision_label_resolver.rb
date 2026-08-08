# frozen_string_literal: true

module System
  # Resolves human-readable labels for provision-plan step inputs that reference System
  # (fleet-substrate) records. Registered as the core
  # `Powernode::ExtensionRegistry.provider(:provision_label_resolver)` so core's
  # Ai::Provisioning::PlanSnapshotService renders these labels WITHOUT naming System::.
  # Account-scoped; every method returns nil when the id is absent or unresolvable so a partial
  # plan still renders.
  module ProvisionLabelResolver
    module_function

    def instance_label(account:, inputs:)
      id = inputs["provider_instance_type_id"] || inputs[:provider_instance_type_id]
      return nil if id.blank?

      ::System::ProviderInstanceType.where(account_id: account.id).find_by(id: id)&.name
    rescue StandardError
      nil
    end

    def region_label(account:, inputs:)
      id = inputs["provider_region_id"] || inputs[:provider_region_id]
      return nil if id.blank?

      region = ::System::ProviderRegion.where(account_id: account.id).find_by(id: id)
      return nil unless region

      provider_type = region.provider&.provider_type.to_s
      # Local hypervisor regions have arbitrary names — show the provider type instead of the
      # meaningless region code (e.g. "default-region").
      return "local hypervisor" if provider_type == "local_qemu"

      # NOTE: the column is region_code (System::ProviderRegion has no #code). The prior core
      # implementation called region.code, which raised NoMethodError and was swallowed by the
      # rescue — so non-local_qemu regions always rendered as nil. Fixed here while relocating.
      region.region_code.presence || region.name.presence
    rescue StandardError
      nil
    end

    # The template a provision step will actually use, WITH its boot_mode
    # (IMP 019fe1e0-0b8a).
    #
    # boot_mode is not decoration — it decides whether the provisioned box is a
    # Powernode node at all. `uefi_disk` boots the UKI pivot image, which
    # carries the agent, so the node can take module assignments and complete
    # the runtime handshake. Anything else (including a BLANK boot_mode, which
    # ProvisioningService defaults to `cloud_init`) boots a plain cloud image
    # with no agent, making module assignment and the DockerHost handshake
    # unreachable by construction.
    #
    # The approval row previously showed count, instance type and region but
    # never the template, so a plan that had silently resolved to the wrong
    # template read as entirely normal at the gate. Surfacing the resolved
    # boot_mode is what lets an approver see that.
    def template_label(account:, inputs:)
      id = inputs["template_id"] || inputs[:template_id]
      return nil if id.blank?

      template = ::System::NodeTemplate.where(account_id: account.id).find_by(id: id)
      return nil unless template

      cfg = template.config.is_a?(Hash) ? template.config : {}
      boot_mode = (cfg["boot_mode"] || cfg[:boot_mode]).to_s.strip
      # Blank means cloud_init downstream — say so rather than omitting it,
      # since the omitted case is exactly the dangerous one.
      boot_mode = "cloud_init" if boot_mode.empty?

      "#{template.name} [#{boot_mode}]"
    rescue StandardError
      nil
    end
  end
end
