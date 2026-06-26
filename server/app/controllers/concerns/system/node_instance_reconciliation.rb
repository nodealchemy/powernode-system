# frozen_string_literal: true

module System
  # Lazy provider-status reconciliation for the NodeInstances index read path.
  # Extracted from NodeInstancesController so the state-machine nuances of
  # reconciling in-flight/transitional/ip-only rows against their provider live
  # in one cohesive place.
  #
  # Behavior-preserving relocation: the reconcile rules, suppression of sideways
  # transitional flips, and per-instance error swallowing are identical to the
  # inline original.
  module NodeInstanceReconciliation
    extend ActiveSupport::Concern

    # Transitional states are AASM-driven assertions of operator intent
    # ("user clicked Start"). Reconciling against the provider while one
    # of these is the live status produces races where a fast poll
    # overwrites the intent before the actual provider operation has run.
    # Reconcile only when the instance is in a stable, terminal-ish state.
    TRANSITIONAL_STATUSES = %w[starting stopping rebooting].freeze
    IN_FLIGHT_STATUSES    = %w[pending provisioning].freeze
    # The set we consider safe to commit FROM a transitional state. A poll
    # in the middle of `starting` should only update the model if the
    # provider has resolved to one of these terminal-ish states; a sideways
    # flip from `starting` back to `starting` (or to a non-terminal value)
    # is suppressed.
    TERMINAL_STATUSES = %w[running stopped terminated error].freeze

    private

    # Lazily reconcile in-flight instances against their provider. Mutates
    # the array elements in place so the subsequent serialize sees fresh
    # rows. Failures are swallowed per-instance — a stale read is better
    # than failing the whole index call.
    #
    # Three reconcile modes:
    #   - in_flight: status was pending/provisioning → accept any new status
    #   - transitional: status was starting/stopping/rebooting → accept new
    #     status only when it resolves to a terminal state (running/stopped/etc),
    #     never sideways from one transitional to another
    #   - ip_only: status is already running but private_ip_address is blank
    #     → re-poll the provider for IPs without touching status. This catches
    #     local_qemu instances whose DHCP lease lives in dnsmasq rather than
    #     being captured at provision time.
    def reconcile_in_flight_statuses!(instances)
      instances.each do |instance|
        in_flight     = IN_FLIGHT_STATUSES.include?(instance.status)
        transitional  = TRANSITIONAL_STATUSES.include?(instance.status)
        ip_only       = instance.status == "running" && instance.private_ip_address.blank?
        next unless in_flight || transitional || ip_only
        cloud_id = instance.config["cloud_instance_id"]
        next if cloud_id.blank?
        adapter = ::System::Providers::Registry.for_instance(instance)
        next unless adapter.respond_to?(:sync_status)
        result = adapter.sync_status(cloud_id)
        next unless result[:success]

        updates = {}
        new_status = result[:status]
        if new_status.present? && new_status != instance.status
          # From in-flight, accept any provider-reported status (the
          # platform-side row is just catching up to provider truth).
          # From transitional, only commit when the provider has resolved
          # to a terminal state — otherwise a fast poll mid-`starting`
          # could push us back to an earlier state and produce the
          # opposite UX bug from the one this guard is meant to prevent.
          # ip_only mode never changes status.
          if in_flight || (transitional && TERMINAL_STATUSES.include?(new_status))
            updates[:status] = new_status
          end
        end
        updates[:private_ip_address] = result[:private_ip_address] if result[:private_ip_address].present? && result[:private_ip_address] != instance.private_ip_address
        updates[:public_ip_address]  = result[:public_ip_address]  if result[:public_ip_address].present?  && result[:public_ip_address]  != instance.public_ip_address
        instance.update!(updates) if updates.any?
      rescue StandardError => e
        Rails.logger.warn("[NodeInstancesController] sync_status failed for #{instance.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
