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
  end
end
