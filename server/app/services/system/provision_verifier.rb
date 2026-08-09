# frozen_string_literal: true

module System
  # Live-provider reconciliation for provisioning verification (F2,
  # IMP 019fe4c4-c7c4). Registered as the core
  # `Powernode::ExtensionRegistry.provider(:provision_verifier)` so core's
  # Ai::Provisioning::VerificationService can ask "do these instances really
  # exist, where the plan said, according to the PROVIDER?" without naming
  # System::.
  #
  # Fail-closed throughout: a missing row, a missing provider identity (the
  # dryrun-20260809a phantom shape), a provider NotFound, a non-running live
  # state, a region mismatch, or an unreachable provider all answer ok: false
  # with a specific detail. Silence and health are different things — the DB
  # said "running" about an instance PVE had never seen, and the old verify
  # stub blessed it.
  module ProvisionVerifier
    module_function

    LIVE_OK_STATUSES = %w[running].freeze

    # expectations: [{ node_instance_id:, provider_region_id: }, ...]
    # Returns:      [{ node_instance_id:, ok:, detail: }, ...]
    def reconcile_instances(account:, expectations:)
      Array(expectations).map do |exp|
        exp = exp.is_a?(Hash) ? exp.symbolize_keys : {}
        id = exp[:node_instance_id].to_s
        { node_instance_id: id }.merge(reconcile_one(account: account, id: id,
                                                     region_id: exp[:provider_region_id]))
      end
    end

    def reconcile_one(account:, id:, region_id:)
      instance = ::System::NodeInstance.where(account_id: account.id).find_by(id: id)
      return { ok: false, detail: "no NodeInstance row for #{id}" } unless instance

      if region_id.present? && instance.provider_region_id.to_s != region_id.to_s
        return { ok: false,
                 detail: "region mismatch: plan declared #{region_id}, instance carries " \
                         "#{instance.provider_region_id} — placement the operator never approved" }
      end

      unless %w[cloud dynamic].include?(instance.variety.to_s)
        # No provider to ask; the row is all there is. Say so.
        ok = instance.status.to_s == "running"
        return { ok: ok, detail: "physical instance, db-only check: status=#{instance.status}" }
      end

      if instance.cloud_instance_id.blank?
        return { ok: false,
                 detail: "no provider identity (cloud_instance_id blank) — the phantom shape; " \
                         "provisioning never completed" }
      end

      live_check(instance)
    end

    def live_check(instance)
      adapter = Providers::Registry.for_instance(instance)
      result = adapter.get_instance(instance.cloud_instance_id)

      if result[:success]
        status = result[:status].to_s
        ok = LIVE_OK_STATUSES.include?(status)
        { ok: ok, detail: "provider reports #{status.presence || 'unknown'}" }
      elsif result[:error_code].to_s == "NotFound"
        { ok: false, detail: "provider has no record of #{instance.cloud_instance_id} " \
                             "(deleted out-of-band, or never created)" }
      else
        { ok: false, detail: "provider check failed: #{result[:error].to_s[0, 200]}" }
      end
    rescue Providers::BaseProvider::ResourceNotFoundError => e
      { ok: false, detail: "provider has no record of #{instance.cloud_instance_id}: #{e.message[0, 120]}" }
    rescue StandardError => e
      # Unreachable provider must not bless — fail closed with the reason.
      { ok: false, detail: "provider check failed: #{e.class}: #{e.message[0, 200]}" }
    end
  end
end
