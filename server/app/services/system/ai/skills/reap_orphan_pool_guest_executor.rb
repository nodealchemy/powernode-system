# frozen_string_literal: true

module System
  module Ai
    module Skills
      # IMP-64d9f2cdff63 — destroys a provider guest that is named for an
      # ephemeral pool and that no platform row knows
      # (System::Fleet::Sensors::OrphanPoolGuestSensor).
      #
      # EVERYTHING THE SIGNAL CLAIMED IS RE-CHECKED HERE. An approval can sit for
      # hours; a row may come to name the guest, the pool may change, the guest
      # may already be gone, or the provider id may be recycled onto another
      # guest. So at execution:
      #
      #   * the pool must still be in this account and still ephemeral, the guest
      #     must still be attributed to THAT pool (the most specific name match
      #     among the account's pools), and no other account may carry the pool's
      #     name;
      #   * no row, in any account, may name the guest;
      #   * the provider's inventory must still list the guest under that id AND
      #     name — an unreadable inventory refuses, an absent guest is reported
      #     already gone without any destructive call;
      #   * the terminate is NAME-VERIFIED — terminate_instance(expected_name:)
      #     refuses with GUEST_NAME_MISMATCH rather than destroy a different guest
      #     at that id, and that refusal is a failure here.
      #
      # PLANE PLACEMENT IS NOT RE-IMPLEMENTED. The inputs name the pool, the
      # environment resolver places the pool in its plane, and
      # Ai::EnvironmentPolicyOverlay escalates this destructive category in a
      # protected one — so the auto_approve policy row proceeds for a pool in an
      # unprotected plane and parks for an ops or prod pool.
      class ReapOrphanPoolGuestExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "reap_orphan_pool_guest",
          description: "Destroy a provider guest named for an ephemeral instance pool that no platform row knows — a VM left behind when its record went. Re-checked against the provider inventory and name-verified at the terminate; parks in a protected plane.",
          category: "fleet",
          inputs: {
            instance_pool_id: { type: "string", required: true,
                                description: "System::InstancePool the guest is named for (places the reap in that pool's plane)" },
            cloud_instance_id: { type: "string", required: true,
                                 description: "Provider id the guest was listed under" },
            guest_name: { type: "string", required: true,
                          description: "The guest's name at the provider; nothing is destroyed unless the id still holds this guest" },
            provider_region_id: { type: "string", required: false,
                                  description: "Region whose inventory listed the guest (one of the pool's regions); defaults to the pool's own region" }
          },
          outputs: {
            reaped: :boolean,
            already_gone: :boolean,
            instance_pool_id: :string,
            cloud_instance_id: :string,
            guest_name: :string
          },
          requires_approval: true,
          # Declared rather than derived, so the policy row, PolicyDeclarations
          # and Ai::AutonomyGate resolve the same spelling.
          action_category: "system.pool_guest_reap",
          blast_radius: :medium
        )

        binds_to "capacity_manager"

        protected

        def perform(instance_pool_id:, cloud_instance_id:, guest_name:, provider_region_id: nil)
          payload = { instance_pool_id: instance_pool_id, cloud_instance_id: cloud_instance_id, guest_name: guest_name }
          sensor = ::System::Fleet::Sensors::OrphanPoolGuestSensor

          pools = ::System::InstancePool.where(account_id: @account.id).to_a
          pool = pools.find { |p| p.id.to_s == instance_pool_id.to_s }
          return failure("Instance pool not found in account scope: #{instance_pool_id}") unless pool
          unless sensor::REAPABLE_LIFECYCLE_CLASSES.include?(pool.lifecycle_class)
            return failure("Pool #{pool.name.inspect} is #{pool.lifecycle_class}, not ephemeral; refusing to reap its guests")
          end
          unless sensor.attribute_pool(pools, guest_name)&.id == pool.id
            return failure("Guest #{guest_name.inspect} is not named for pool #{pool.name.inspect}; refusing to reap it")
          end
          if sensor.shared_pool_names(@account, [ pool.name ]).any?
            return failure("Another account also has a pool named #{pool.name.inspect}; the guest's owner is ambiguous")
          end
          if sensor.known_guest_names([ guest_name ]).include?(guest_name.to_s)
            return failure("Guest #{guest_name.inspect} is no longer an orphan: a platform row names it")
          end

          region_id = provider_region_id.presence&.to_s || pool.provider_region_id.to_s
          unless sensor.pool_region_ids(pool).include?(region_id)
            return failure("Region #{region_id.inspect} is not one of pool #{pool.name.inspect}'s regions; refusing to reap there")
          end

          adapter = provider_for(region_id)
          return failure("No usable provider connection for region #{region_id.inspect}") unless adapter

          case listed(adapter, cloud_instance_id, guest_name)
          when :unknown
            return failure("Could not read the provider inventory to confirm #{guest_name} (#{cloud_instance_id}); refusing")
          when :absent
            return success(payload.merge(reaped: false, already_gone: true))
          end

          result = begin
            adapter.terminate_instance(cloud_instance_id, expected_name: guest_name)
          rescue ::System::Providers::BaseProvider::ResourceNotFoundError
            { success: false, error_code: "NotFound" }
          end

          if result[:success]
            Rails.logger.warn(
              "[ReapOrphanPoolGuestExecutor] reaped orphan guest #{guest_name} (#{cloud_instance_id}) of pool '#{pool.name}'"
            )
            success(payload.merge(reaped: true, already_gone: false))
          elsif result[:error_code].to_s.casecmp?("NotFound")
            success(payload.merge(reaped: false, already_gone: true))
          else
            failure("Reap of orphan guest #{guest_name} (#{cloud_instance_id}) refused: #{result[:error]}")
          end
        end

        private

        def provider_for(region_id)
          region = ::System::ProviderRegion.find_by(id: region_id)
          return nil unless region

          connection = ::System::Providers::Registry.find_connection_for_region(region, @account)
          return nil unless connection

          ::System::Providers::Registry.for(connection, region: region)
        rescue ::System::Providers::Registry::UnknownProviderError
          nil
        end

        # :present when the inventory lists this id under this name, :absent when a
        # complete listing does not, :unknown when no complete listing was read.
        def listed(adapter, cloud_instance_id, guest_name)
          return :unknown unless adapter.supports?(:sync)

          listing = adapter.list_instances
          return :unknown unless listing.is_a?(Hash) && listing[:success] && listing[:truncated] != true

          found = Array(listing[:instances]).any? do |guest|
            guest = guest.to_h.with_indifferent_access
            guest[:cloud_instance_id].to_s == cloud_instance_id.to_s && guest[:name].to_s == guest_name.to_s
          end
          found ? :present : :absent
        rescue StandardError => e
          Rails.logger.warn("[ReapOrphanPoolGuestExecutor] inventory read failed: #{e.class}: #{e.message}")
          :unknown
        end
      end
    end
  end
end
