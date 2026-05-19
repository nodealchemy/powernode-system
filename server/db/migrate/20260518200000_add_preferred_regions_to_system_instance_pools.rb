# frozen_string_literal: true

# Audit plan P2.5 — cross-AZ replenishment for InstancePool.
#
# `preferred_regions` is an ordered list of provider_region IDs the pool
# can replenish into. Empty (default) means "use the single
# provider_region_id column" (preserves prior single-region behavior).
# When populated, the replenisher round-robins across the list at
# slot-index modulo, with the existing `provider_region_id` as the
# fallback if the preferred list is exhausted.
class AddPreferredRegionsToSystemInstancePools < ActiveRecord::Migration[8.0]
  def change
    add_column :system_instance_pools, :preferred_regions, :text, array: true, default: []
  end
end
