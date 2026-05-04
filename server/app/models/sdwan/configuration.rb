# frozen_string_literal: true

# Per-account anchor for the deterministic IPv6 ULA derivation used by
# Sdwan::PrefixAllocator. There's exactly one row per account, created
# lazily on first network/peer allocation and never rewritten for the
# account's lifetime — the address space stability contract depends on it.
#
# instance_prefix_40 is shared across every Sdwan::Configuration row in this
# install (it's a per-install constant). It's stored on every row so that
# (a) a single read gives the allocator everything it needs, and (b) a
# future operator-driven prefix migration can be authored as a row-level
# update rather than a global constant change.
#
# Slice 1 of the SDWAN plan.
module Sdwan
  class Configuration < ApplicationRecord
    self.table_name = "sdwan_configurations"

    belongs_to :account

    validates :account_id, uniqueness: true
    validates :instance_prefix_40, presence: true, format: {
      with: /\Afd[0-9a-f]{2}:[0-9a-f]{1,4}:[0-9a-f]{1,4}::\/40\z/i,
      message: "must be a /40 ULA prefix in fdXX:XXXX:XXXX::/40 form"
    }
    validates :account_prefix_48, presence: true, format: {
      with: /\Afd[0-9a-f]{2}:[0-9a-f]{1,4}:[0-9a-f]{1,4}::\/48\z/i,
      message: "must be a /48 ULA prefix in fdXX:XXXX:XXXX::/48 form"
    }
  end
end
