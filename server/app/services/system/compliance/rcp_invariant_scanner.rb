# frozen_string_literal: true

module System
  module Compliance
    # RCP v2 (campaign 019f9250, increment p0c) — fleet-wide scan reporting
    # CURRENT violations of INV-1 (no self-management), INV-2 (no boot-time
    # network dependency), and INV-6 (member storage = local disk of a
    # distinct node; shared NFS forbidden for member root disks).
    #
    # Read-only. Never mutates fleet state. Reuses the SAME predicate logic
    # the provisioning-time gates use (System::Autonomy::SelfManagementFence
    # / BootPathInvariantCheck / StorageLocalityCheck) so "what blocks a new
    # provision" and "what the scan reports as already-live" can never drift
    # apart into two competing definitions of each invariant.
    #
    # Config resolution note: ProxmoxProvider's cidata_iso_transport? reads
    # ONLY the resolved System::ProviderConnection's own config (no fallback
    # to the parent System::Provider) — whereas default_storage/default_node
    # DO fall back Connection -> Provider (see ProxmoxProvider#pve_credential).
    # This scanner mirrors that exact precedence by resolving the adapter
    # (Providers::Registry.for_instance — pure object construction + a DB
    # read, no network call) and reading provider_adapter.connection.config
    # (falling back to provider_adapter.connection.provider.config for
    # default_storage only), rather than reading System::Provider#config
    # directly, which would silently miss a connection-level override.
    #
    # Two modes:
    #   live: false (default) — no network call. Constructing the adapter
    #     via Registry.for_instance is a pure DB read (BaseProvider#initialize
    #     does no I/O); only INV-6's optional live path below actually calls
    #     out to Proxmox. Safe from any context, including this worktree.
    #     INV-6 findings from this mode are NOT independently verified
    #     against live Proxmox storage.cfg (see StorageLocalityCheck) — they
    #     are flagged for confirmation, not asserted as certain.
    #   live: true — additionally calls the adapter's list_volume_types
    #     (a real PVE API call) via StorageLocalityCheck, upgrading INV-6
    #     findings to `verified: true` where PVE answers. Requires real
    #     provider credentials to be reachable (i.e., run from a live
    #     deployment, not this worktree).
    #
    # Reused by System::Compliance::ComplianceSnapshotService as the
    # `rcp_invariants` snapshot section (Reuse First — one scan, exposed
    # through the existing account-wide compliance-snapshot seam rather than
    # inventing a parallel report format).
    class RcpInvariantScanner
      include ::System::Autonomy::SelfManagementFence

      Result = Struct.new(:inv1, :inv2, :inv6, :scanned_at, :live, keyword_init: true) do
        def violations
          Array(inv1) + Array(inv2) + Array(inv6)
        end

        def clean?
          violations.empty?
        end
      end

      def self.scan(account:, live: false)
        new.scan(account: account, live: live)
      end

      def scan(account:, live: false)
        raise ArgumentError, "account required" unless account

        Result.new(
          inv1: scan_inv1(account),
          inv2: scan_inv2(account),
          inv6: scan_inv6(account, live: live),
          scanned_at: Time.current,
          live: live
        )
      end

      private

      # INV-1 — surfaces which CURRENTLY-RUNNING instances sit on this
      # deployment's own hosting node, per the configured
      # self_hosting_node_id SiteSetting. Fully inert (always empty) when
      # that SiteSetting is unset — which is the case for every plane today
      # (setting it is an operator/onboarding action, analogous to and
      # likely alongside #14's control_plane_id stamping, deliberately NOT
      # performed by this increment).
      def scan_inv1(account)
        return [] if self_hosting_node_id.nil?

        ::System::NodeInstance
          .joins(:node)
          .where(system_nodes: { account_id: account.id })
          .where(status: %w[running starting])
          .select { |instance| self_managed_target?(instance) }
          .map do |instance|
          {
            invariant: "INV-1",
            severity: :critical,
            node_id: instance.node_id,
            instance_id: instance.id,
            detail: "instance #{instance.id} runs on node #{instance.node_id}, this deployment's " \
                    "configured self_hosting_node_id — any fleet-autonomy reap/actuate action on " \
                    "it would be self-management (blocked at the actuator by SelfManagementFence, " \
                    "surfaced here for visibility)"
          }
        end
      end

      # INV-2 — for every cloud instance provisioned via Proxmox in a pivot
      # boot_mode (uefi_disk/direct_kernel — the modes that exist
      # specifically to satisfy INV-2), check whether the resolving
      # ProviderConnection has opted into the ISO cidata transport.
      def scan_inv2(account)
        instances_with_adapter(account).filter_map do |instance, adapter|
          next unless adapter

          boot_mode = boot_mode_for(instance.node)
          # A pivot-boot instance always needs SOME identity/enrollment
          # payload to come up at all (see ProxmoxProvider#apply_default_
          # federation_user_data) — conservatively treat payload as present
          # for every pivot-boot instance rather than trying to statically
          # reconstruct the exact provision-time params.
          ::System::Autonomy::BootPathInvariantCheck.violation_for(
            provider_type: adapter.provider_type,
            boot_mode: boot_mode,
            provider_config: adapter.respond_to?(:connection) ? adapter.connection&.config : nil,
            payload_present: true,
            node: instance.node
          )&.merge(instance_id: instance.id)
        end.uniq { |v| v[:node_id] }
      end

      # INV-6 — the storage-name signal available WITHOUT a live PVE call is
      # the resolved connection's `default_storage` (falling back to its
      # parent Provider's config, mirroring pve_credential's own precedence
      # — see the class doc comment). An explicit per-provision
      # `options[:storage]` override, if any, is not visible from persisted
      # platform data alone — documented gap, see the audit doc. When
      # live: true and the adapter supports it, upgrades to a verified
      # answer via StorageLocalityCheck's real list_volume_types query.
      def scan_inv6(account, live:)
        instances_with_adapter(account).filter_map do |instance, adapter|
          next unless adapter

          storage_name = resolved_default_storage(adapter)
          next if storage_name.blank?

          # Tri-state: true = confirmed network-backed, false = confirmed
          # local, nil = undetermined. Undetermined is reported as an
          # unverified flag (never silently treated as "compliant") EXCEPT
          # the one name this audit independently corroborated elsewhere
          # (this deployment's own Provider record + ops-hub's own
          # cloud_instance_id both resolve to dna/dna-data) as dna's own
          # local ZFS — re-flagging "dna-data" as unverified on every static
          # scan would just be noise.
          network_backed =
            if live
              ::System::Autonomy::StorageLocalityCheck.network_backed_storage?(
                provider_adapter: adapter, region_code: instance.provider_region&.name, storage_name: storage_name
              )
            elsif storage_name == "dna-data"
              false
            end

          confirmed = !network_backed.nil?
          next if confirmed && !network_backed # confirmed-local: nothing to report

          ::System::Autonomy::StorageLocalityCheck.violation_for(
            storage_name: storage_name, network_backed: true, node: instance.node, confirmed: confirmed
          )&.merge(instance_id: instance.id)
        end.uniq { |v| [ v[:node_id], v[:storage_name] ] }
      end

      # Resolves each instance's live provider adapter — pure object
      # construction + a DB read (see the class doc comment), NOT a network
      # call. Best-effort: an instance whose connection can no longer be
      # resolved (e.g. a deleted ProviderConnection) is skipped rather than
      # raising and aborting the whole scan.
      def instances_with_adapter(account)
        ::System::NodeInstance
          .joins(:node)
          .includes(:provider_region, node: :node_template)
          .where(system_nodes: { account_id: account.id })
          .where(status: %w[running starting pending])
          .where.not(provider_region_id: nil)
          .map { |instance| [ instance, resolve_adapter(instance) ] }
      end

      def resolve_adapter(instance)
        ::System::Providers::Registry.for_instance(instance)
      rescue StandardError => e
        Rails.logger.warn("[RcpInvariantScanner] could not resolve provider adapter for instance #{instance.id}: #{e.class}: #{e.message}")
        nil
      end

      # Mirrors ProxmoxProvider#pve_credential's precedence for this one key
      # (connection config, then the parent Provider's config) without
      # reaching into that private method.
      def resolved_default_storage(adapter)
        connection = adapter.respond_to?(:connection) ? adapter.connection : nil
        return nil unless connection

        cfg = connection.config
        direct = cfg.is_a?(Hash) ? (cfg["default_storage"] || cfg[:default_storage]) : nil
        return direct if direct.present?

        provider_cfg = connection.provider&.config
        provider_cfg.is_a?(Hash) ? (provider_cfg["default_storage"] || provider_cfg[:default_storage]) : nil
      end

      def boot_mode_for(node)
        cfg = node&.node_template&.config
        boot_mode = cfg.is_a?(Hash) ? (cfg["boot_mode"] || cfg[:boot_mode]) : nil
        boot_mode.presence || "cloud_init"
      end
    end
  end
end
