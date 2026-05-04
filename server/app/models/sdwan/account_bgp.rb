# frozen_string_literal: true

# Sdwan::AccountBgp — one row per account using iBGP. Owns the private
# AS number (RFC 6996 4-byte private range) and the router-id derivation
# strategy that every Sdwan::Peer in the account inherits. Multiple
# Sdwan::Networks within the account share the same AS — they form
# distinct iBGP fabrics over the same number, isolated by their
# WireGuard tunnels (the BGP TCP sessions ride the overlay).
#
# Slice 9c of the SDWAN plan.
module Sdwan
  class AccountBgp < ApplicationRecord
    self.table_name = "sdwan_account_bgps"

    # RFC 6996 4-byte private AS range. 94 million ASes — practically
    # inexhaustible for a single Powernode install.
    PRIVATE_AS_MIN = 4_200_000_000
    PRIVATE_AS_MAX = 4_294_967_294

    ROUTER_ID_STRATEGIES = %w[peer_overlay_ipv6_hash explicit].freeze

    belongs_to :account
    belongs_to :default_route_policy, class_name: "Sdwan::RoutePolicy",
               optional: true # slice 9e adds the model

    validates :as_number, presence: true, uniqueness: true, numericality: {
      only_integer: true,
      greater_than_or_equal_to: PRIVATE_AS_MIN,
      less_than_or_equal_to: PRIVATE_AS_MAX
    }
    validates :router_id_strategy, inclusion: { in: ROUTER_ID_STRATEGIES }
    validates :default_local_pref, numericality: { only_integer: true,
                                                    greater_than_or_equal_to: 0 }

    scope :enabled, -> { where(enabled: true) }

    # Returns or lazily creates the AccountBgp for an account. The
    # allocator finds an unused AS number from the private range.
    def self.for_account!(account)
      existing = find_by(account_id: account.id)
      return existing if existing

      ::Sdwan::Bgp::AsNumberAllocator.allocate!(account: account)
    end
  end
end
