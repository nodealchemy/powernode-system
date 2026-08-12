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

    # Live statuses that PROVE a guest is still there. Deliberately NOT the
    # complement of "gone": the normalized vocabulary is lossy in both
    # directions and the three buckets below are what it can actually support.
    SURVIVOR_STATUSES = %w[running stopped pending starting].freeze

    # A terminate the provider is still working through. Common and correct —
    # EC2 sits in shutting-down (normalized "stopping") for tens of seconds
    # after a SUCCESSFUL terminate, and verification runs once, immediately.
    IN_FLIGHT_STATUSES = %w[stopping terminating].freeze

    # Reported gone. AMBIGUOUS on GCE, where TERMINATED is the state of a
    # STOPPED instance (a deleted one 404s) — see #gone_status?.
    GONE_STATUSES = %w[terminated].freeze

    # Providers whose normalized "terminated" means stopped, not deleted.
    TERMINATED_MEANS_STOPPED = %w[gcp].freeze

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
        if gone_status?(status, adapter)
          { ok: true, detail: "provider reports #{status} — gone" }
        elsif IN_FLIGHT_STATUSES.include?(status)
          { ok: true,
            detail: "provider reports #{status} — terminate in flight, not confirmed gone" }
        else
          { ok: false,
            detail: "provider STILL reports #{status.presence || 'unknown'} for " \
                    "#{instance.cloud_instance_id} — terminated in the platform, " \
                    "alive (and billing) at the provider" }
        end
      elsif result[:error_code].to_s.casecmp?("NotFound")
        { ok: true, detail: "provider has no record of #{instance.cloud_instance_id} — gone" }
      else
        { ok: false, detail: "provider check failed: #{result[:error].to_s[0, 200]}" }
      end
    rescue Providers::BaseProvider::ResourceNotFoundError
      # KNOWN WEAKER EVIDENCE, on PVE specifically: a node-scoped id reports
      # "this vmid was deleted" and "this vmid is not on THIS node"
      # identically, which is why ProxmoxProvider#terminate_instance runs a
      # cluster-wide lookup before believing it. That lookup is adapter
      # internals; from here a guest live-migrated off its recorded node reads
      # as gone. Closing it needs an adapter-level absence capability rather
      # than another guess in this file.
      { ok: true, detail: "provider has no record of #{instance.cloud_instance_id} — gone" }
    rescue StandardError => e
      # Unreachable provider must not bless an absence any more than a presence.
      { ok: false, detail: "provider check failed: #{e.class}: #{e.message[0, 200]}" }
    end

    # `terminated` means DELETED on most adapters and STOPPED on GCE, where a
    # deleted instance 404s instead. The normalization map cannot express the
    # difference (GCP_STATUS_MAP["TERMINATED"] => "terminated"), so the one
    # caller that needs it resolves it from the adapter.
    #
    # ProvisioningService#not_found_result? also matches /not found/i on the
    # error MESSAGE, and that is right where it is used (an idempotent
    # terminate: guessing "already gone" is safe). Here it inverts the risk —
    # ProxmoxProvider#get_instance raises ResourceNotFoundError for a real
    # not-found and funnels every OTHER client error into a message with no
    # error_code, so "storage 'fast' not found" would certify a running guest
    # as deleted. Absence is proved, never inferred from error prose.
    def gone_status?(status, adapter)
      return false unless GONE_STATUSES.include?(status)

      provider = adapter.respond_to?(:provider_type) ? adapter.provider_type.to_s : ""
      !TERMINATED_MEANS_STOPPED.include?(provider)
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
