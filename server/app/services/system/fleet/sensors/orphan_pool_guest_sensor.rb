# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # IMP-64d9f2cdff63 — provider guests named for an EPHEMERAL pool that no
      # platform row knows.
      #
      # WHY THIS HAS TO READ THE PROVIDER
      #
      # On 2026-09-08 the hypervisor held five ci-native-builders VMs, three of
      # them running for up to 22 days, that no System::NodeInstance row named:
      # their records had been pruned while the VMs survived. Once the record is
      # gone, every platform view of the fleet is built from rows, so nothing
      # lists that guest again. The provider's own inventory is the only evidence
      # left. InstancePoolService#prune_dead_records! now confirms a guest gone
      # before its record goes; this sensor answers for guests that were already
      # left behind, and for any a future path leaks the same way.
      #
      # WHY BY NAME, NEVER BY PROVIDER ID
      #
      # Proxmox recycles vmids (allocate_next_vmid! draws the lowest free one),
      # and the same incident's dead rows carried ids already handed to other
      # guests. A pool names every guest it creates "<pool name>-pool-…"
      # (InstancePoolService#provision_warming_member!), and ProvisioningService
      # records that as provider_guest_name. A guest is attributed to the pool
      # whose name it carries — the MOST SPECIFIC one among ALL the account's
      # pools, so a guest of a longer-named non-ephemeral pool is never claimed by
      # a shorter ephemeral one — and it is an orphan when no row in ANY account
      # (a hypervisor can serve several) names it, by provider_guest_name or, for
      # rows older than that capture, by name.
      #
      # WHAT IT DECLINES
      #
      #   * A failed, raising or truncated listing, a region without a usable
      #     connection, and a provider that cannot list its inventory emit
      #     NOTHING. None of them proves a guest exists, let alone that it is
      #     unrecorded.
      #   * A pool name another account also uses: the same name on a shared
      #     hypervisor cannot say whose guest it is, or which plane to place the
      #     reap in.
      #   * Non-ephemeral pools — the operator direction is "ci / ephemeral". A
      #     spot member's guest can be a provider reclaim in flight, the reason
      #     InstanceUnrecoverableSensor excludes spot from its reap arm too; the
      #     list is shared rather than restated.
      #
      # COVERAGE LIMITS, stated so absence of a signal is not read as absence of
      # an orphan: only providers that can list their inventory (`:sync`) are
      # read, and a guest whose name lost the "-pool-" marker to hostname
      # budgeting (System::HostnameBudget, very long pool names) cannot be
      # attributed. Regions read are each ephemeral pool's provider_region plus
      # its preferred_regions, the set provision_warming_member! places members in.
      #
      # The sensor only DETECTS: the signal routes to system.pool_guest_reap,
      # whose policy row proceeds and whose plane placement (the pool's
      # environment) parks it in a protected plane.
      class OrphanPoolGuestSensor < BaseSensor
        SIGNAL_KIND = "system.pool_guest_orphaned"

        # The separator provision_warming_member! puts between a pool's name and
        # the rest of its members' names.
        POOL_GUEST_NAME_SEPARATOR = "-pool-"

        REAPABLE_LIFECYCLE_CLASSES = InstanceUnrecoverableSensor::REAPABLE_LIFECYCLE_CLASSES

        # Fallback; overridable per account as "max_per_tick". Each signal can
        # become a provider destroy in the same tick, so a mass leak is worked
        # off a slice at a time.
        MAX_PER_TICK = 10

        def self.default_thresholds
          { "max_per_tick" => MAX_PER_TICK }
        end

        # True when guest_name is a member name of the pool called pool_name.
        def self.pool_guest_name?(pool_name, guest_name)
          pool_name.present? && guest_name.to_s.start_with?("#{pool_name}#{POOL_GUEST_NAME_SEPARATOR}")
        end

        # The pool among `pools` whose member name this is — the most specific
        # (longest-named) match — or nil.
        def self.attribute_pool(pools, guest_name)
          pools.select { |pool| pool_guest_name?(pool.name, guest_name) }.max_by { |pool| pool.name.length }
        end

        # The names in `names` that a pool in ANOTHER account also carries.
        def self.shared_pool_names(account, names)
          names = Array(names).map(&:to_s).reject(&:blank?).uniq
          return Set.new if names.empty?

          ::System::InstancePool.where(name: names).where.not(account_id: account.id).distinct.pluck(:name).to_set
        end

        # The subset of names some platform row, in any account, still knows.
        def self.known_guest_names(names)
          names = Array(names).map(&:to_s).reject(&:blank?).uniq
          return Set.new if names.empty?

          by_recorded = ::System::NodeInstance.where("config->>'provider_guest_name' IN (?)", names)
                                              .pluck(Arel.sql("config->>'provider_guest_name'"))
          by_name = ::System::NodeInstance.where(name: names).pluck(:name)
          (by_recorded + by_name).to_set
        end

        # Every region a pool places members in.
        def self.pool_region_ids(pool)
          ([ pool.provider_region_id ] + Array(pool.preferred_regions)).compact_blank.map(&:to_s).uniq
        end

        def sense
          pools = ::System::InstancePool.where(account_id: account.id).to_a
          reapable = pools.select { |pool| REAPABLE_LIFECYCLE_CLASSES.include?(pool.lifecycle_class) }
          return [] if reapable.empty?

          shared = self.class.shared_pool_names(account, reapable.map(&:name))
          regions = ::System::ProviderRegion.where(id: reapable.flat_map { |pool| self.class.pool_region_ids(pool) }.uniq)

          # A cluster-wide listing (Proxmox) returns the same guest from every
          # region on that cluster, so the signals are deduplicated.
          regions.flat_map { |region| orphans_in(region, pools, shared) }
                 .uniq(&:fingerprint)
                 .first(threshold("max_per_tick"))
        end

        private

        def orphans_in(region, pools, shared)
          guests = listed_guests(region)
          return [] if guests.blank?

          attributed = guests.filter_map do |guest|
            guest = guest.to_h.with_indifferent_access
            name = guest[:name].to_s
            next if name.empty? || guest[:cloud_instance_id].blank?

            pool = self.class.attribute_pool(pools, name)
            next unless pool && REAPABLE_LIFECYCLE_CLASSES.include?(pool.lifecycle_class)
            next if shared.include?(pool.name)

            [ pool, guest, name ]
          end
          return [] if attributed.empty?

          known = self.class.known_guest_names(attributed.map(&:last))
          attributed.reject { |_pool, _guest, name| known.include?(name) }
                    .map { |pool, guest, name| signal_for(pool, region, guest, name) }
        end

        def listed_guests(region)
          connection = ::System::Providers::Registry.find_connection_for_region(region, account)
          return nil unless connection

          adapter = ::System::Providers::Registry.for(connection, region: region)
          return nil unless adapter.supports?(:sync)

          listing = adapter.list_instances
          return nil unless listing.is_a?(Hash) && listing[:success] && listing[:truncated] != true

          Array(listing[:instances])
        rescue StandardError => e
          Rails.logger.warn(
            "[OrphanPoolGuestSensor] inventory read failed for region=#{region&.id}: #{e.class}: #{e.message}"
          )
          nil
        end

        def signal_for(pool, region, guest, name)
          cloud_instance_id = guest[:cloud_instance_id].to_s
          signal(
            kind: SIGNAL_KIND,
            severity: :high,
            payload: {
              instance_pool_id: pool.id,
              pool_name: pool.name,
              environment_id: pool.environment_id,
              provider_region_id: region.id,
              cloud_instance_id: cloud_instance_id,
              guest_name: name,
              guest_status: guest[:status].to_s
            },
            fingerprint: "#{SIGNAL_KIND.delete_prefix('system.')}:#{cloud_instance_id}:#{name}"
          )
        end
      end
    end
  end
end
