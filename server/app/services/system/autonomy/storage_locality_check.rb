# frozen_string_literal: true

module System
  module Autonomy
    # RCP v2 (campaign 019f9250, increment p0c) — INV-6: failure-domain
    # spread, honestly. Members must live on local storage of DISTINCT
    # nodes; shared NFS is forbidden for member root disks.
    #
    # Ground truth (operator-locked decision, 2026-07-24; re-derived here
    # from the live Provider record rather than assumed from memory —
    # confirmed via the "IPNode-PVE" Provider's config, endpoint
    # dna.ipnode.net:8006, default_node "dna", default_storage "dna-data",
    # and ops-hub's own running instance cloud_instance_id "dna/qemu/104"):
    # dna-data is dna's own ZFS pool — a dna failure already took ops-hub
    # down once (the incident this whole campaign traces to). rna's
    # local-data zpool is asserted independent by the same locked decision;
    # this module intentionally does NOT hardcode that as a fact — see
    # #network_backed_storage? below, which asks the provider directly
    # (PVE reports each storage pool's real plugin_type/shared flag) rather
    # than trusting a name-based guess, so the rna claim gets re-verified
    # the moment this runs against live Proxmox credentials instead of
    # perpetuating an unverified assumption.
    #
    # Authoritative signal: System::Providers::ProxmoxProvider#list_volume_types
    # already queries PVE's live storage.cfg and returns each pool's
    # `plugin_type` (zfspool/dir/lvmthin/nfs/cifs/...) and `shared` flag —
    # this module reuses that EXISTING method rather than inventing a new
    # PVE call or a hardcoded storage-name denylist (config-driven name
    # lists rot the moment an operator renames or adds a pool).
    #
    # Advisory-by-default / opt-in-strict, same posture as
    # BootPathInvariantCheck and for the same reason: today's "smoke-nfs-*"
    # test fixtures and general (non-member) instances may legitimately want
    # NFS-backed storage, and this increment must not retroactively block
    # provisioning flows it cannot fully audit from a static read. Strict
    # (raising) enforcement is opt-in, intended for RCP consensus-member
    # provisioning.
    module StorageLocalityCheck
      # PVE plugintype values that represent network-attached storage. Not
      # every `shared: true` pool is network storage (deliberately not used
      # as the signal) — Ceph/iSCSI are shared in the PVE sense but have
      # different failure-domain properties than INV-6's specific target;
      # INV-6's text names NFS explicitly.
      NETWORK_PLUGIN_TYPES = %w[nfs cifs].freeze

      class StorageLocalityViolation < StandardError; end

      module_function

      # Best-effort live check: true when `storage_name` resolves (via the
      # adapter's own list_volume_types, if it has one) to a network
      # plugin_type. Returns `nil` (NOT false) when it cannot be determined
      # (adapter doesn't support the query, the storage isn't found in the
      # list, or the live call itself errors) — callers must treat nil as
      # "unverified", never as "confirmed local".
      def network_backed_storage?(provider_adapter:, region_code:, storage_name:)
        return nil if storage_name.blank?
        return nil unless provider_adapter.respond_to?(:list_volume_types)

        pools = provider_adapter.list_volume_types(region_code)
        pool = Array(pools).find { |p| p[:cloud_id].to_s == storage_name.to_s || p[:name].to_s == storage_name.to_s }
        return nil unless pool

        NETWORK_PLUGIN_TYPES.include?(pool[:plugin_type].to_s)
      rescue StandardError => e
        Rails.logger.warn("[StorageLocalityCheck] list_volume_types failed for #{storage_name.inspect}: #{e.class}: #{e.message}")
        nil
      end

      # Returns a violation descriptor Hash (nil if compliant or
      # unverifiable) — the non-raising form used by the fleet-wide scan.
      # `verified:` on the returned hash distinguishes a live-confirmed
      # violation from a static/name-only inference (see
      # RcpInvariantScanner, which is the only caller that passes
      # confirmed: false today).
      def violation_for(storage_name:, network_backed:, node: nil, confirmed: true)
        return nil unless network_backed

        {
          invariant: "INV-6",
          severity: :high,
          node_id: node&.id,
          node_name: node&.name,
          storage_name: storage_name,
          verified: confirmed,
          detail: confirmed ?
            "root/member storage \"#{storage_name}\" is network-attached (NFS/CIFS per live PVE " \
            "storage.cfg) — shared NFS is forbidden for member root disks per INV-6" :
            "root/member storage \"#{storage_name}\" could not be independently verified as " \
            "local vs. network-attached (no live Proxmox query available) — flagged for manual/ " \
            "live confirmation, not asserted as a confirmed violation"
        }
      end

      # Raising counterpart. Only raises when `strict`. A live verification
      # failure (network_backed_storage? returned nil) under `strict` FAILS
      # CLOSED — an RCP member provision that explicitly asked for this
      # guarantee and can't get an answer must not silently proceed as if
      # it were compliant.
      def assert_local_storage!(provider_adapter:, region_code:, storage_name:, strict:)
        return unless strict

        network_backed = network_backed_storage?(
          provider_adapter: provider_adapter, region_code: region_code, storage_name: storage_name
        )

        if network_backed.nil?
          raise StorageLocalityViolation,
                "refusing provision: could not verify storage \"#{storage_name}\" is local " \
                "(INV-6 strict mode requires a live, confirmed answer) — check Proxmox " \
                "connectivity/credentials"
        end

        return unless network_backed

        raise StorageLocalityViolation,
              "refusing provision: storage \"#{storage_name}\" is network-attached (NFS/CIFS) " \
              "— INV-6 forbids shared NFS for member root disks"
      end
    end
  end
end
