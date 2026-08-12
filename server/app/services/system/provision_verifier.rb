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

    # The only live status that PROVES a guest is gone. Not the complement of
    # LIVE_OK_STATUSES — see #reconcile_absent_instances for why "stopped" is
    # a survivor, not a removal.
    GONE_STATUSES = %w[terminated].freeze

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

    # The mirror image, for scale-in (INC-4). Core hands the victims a
    # `remove_replicas` step reported as removed and asks the PROVIDER whether
    # they are really gone.
    #
    # Asking matters for the same reason presence does. A row marked
    # terminated over a guest the hypervisor still runs is the F2 phantom
    # inverted: nothing in the platform can see it, no sensor counts it, and
    # it bills until somebody reads a provider console. Grading a removal on
    # the executor's own report is exactly the self-certification the presence
    # half of this reconciler exists to remove.
    #
    # GONE is proved by exactly two things: the provider has no record, or it
    # reports the guest terminated. Everything else fails closed, INCLUDING
    # "stopped" — a stopped guest still exists, still holds its disks and on
    # most providers still bills, and PVE normalizes paused/suspended to
    # stopped and shutdown to stopping, so reading anything-but-running as
    # removed would certify the exact survivor this method exists to catch
    # (a `qm destroy` that failed after the guest was shut down, with the row
    # already finalized). A blank status is not evidence of anything.
    #
    # A row this account does not have is NOT proof of removal either:
    # terminate_instance transitions the row, it never destroys it, so a
    # genuinely removed victim always has one. No row means the id was
    # foreign, blank, or hand-destroyed — none of which a removal may
    # certify itself with, and the presence half refuses the same shape.
    #
    # expectations: [{ node_instance_id: }, ...]
    # Returns:      [{ node_instance_id:, ok:, detail: }, ...]
    def reconcile_absent_instances(account:, expectations:)
      Array(expectations).map do |exp|
        exp = exp.is_a?(Hash) ? exp.symbolize_keys : {}
        id = exp[:node_instance_id].to_s
        { node_instance_id: id }.merge(reconcile_one_absent(account: account, id: id))
      end
    end

    def reconcile_one_absent(account:, id:)
      instance = ::System::NodeInstance.where(account_id: account.id).find_by(id: id)
      unless instance
        return { ok: false,
                 detail: "no NodeInstance row for #{id.presence || '(blank)'} in this account — " \
                         "a removed victim keeps its row, so this proves nothing" }
      end

      unless instance.status.to_s == "terminated"
        return { ok: false,
                 detail: "reported removed but the row is not terminated: status=#{instance.status}" }
      end

      unless %w[cloud dynamic].include?(instance.variety.to_s)
        return { ok: true, detail: "physical instance, db-only check: status=#{instance.status}" }
      end

      # No provider identity to ask about: nothing was ever created there, so
      # there is nothing that can survive.
      return { ok: true, detail: "no provider identity to check — nothing to survive" } if instance.cloud_instance_id.blank?

      absence_check(instance)
    end

    def absence_check(instance)
      adapter = Providers::Registry.for_instance(instance)
      result = adapter.get_instance(instance.cloud_instance_id)

      if result[:success]
        status = result[:status].to_s
        gone = GONE_STATUSES.include?(status)
        { ok: gone,
          detail: gone ? "provider reports #{status} — gone"
                       : "provider STILL reports #{status.presence || 'unknown'} for " \
                         "#{instance.cloud_instance_id} — terminated in the platform, " \
                         "alive (and billing) at the provider" }
      elsif provider_not_found?(result)
        { ok: true, detail: "provider has no record of #{instance.cloud_instance_id} — gone" }
      else
        { ok: false, detail: "provider check failed: #{result[:error].to_s[0, 200]}" }
      end
    rescue Providers::BaseProvider::ResourceNotFoundError
      { ok: true, detail: "provider has no record of #{instance.cloud_instance_id} — gone" }
    rescue StandardError => e
      # Unreachable provider must not bless an absence any more than a presence.
      { ok: false, detail: "provider check failed: #{e.class}: #{e.message[0, 200]}" }
    end

    # Same detection ProvisioningService#not_found_result? uses. Several
    # adapters report not-found as a message with no error_code, and matching
    # only the code fails a correctly-completed removal on those providers.
    def provider_not_found?(result)
      return false unless result.is_a?(Hash)

      result[:error_code].to_s.casecmp?("NotFound") || result[:error].to_s.match?(/not found/i)
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
