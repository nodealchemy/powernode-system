# frozen_string_literal: true

# Sdwan::Bgp::AsNumberAllocator — picks an unused 4-byte private AS
# number (RFC 6996, range 4200000000-4294967294) for an account.
# Mirrors Sdwan::PrefixAllocator's rejection-sampling pattern.
#
# Strategy: deterministic-from-account-id with rejection sampling on
# collision. The deterministic seed means the same account always lands
# on the same AS unless that one's already taken (extremely unlikely
# given the 94M-number range), keeping configurations stable across
# disaster recovery / database rebuilds.
#
# Slice 9c of the SDWAN plan.
module Sdwan
  module Bgp
    class AsNumberAllocator
      MAX_ATTEMPTS = 64

      class CapacityExhausted < StandardError; end

      def self.allocate!(account:, **kwargs)
        new(account: account, **kwargs).allocate!
      end

      def initialize(account:, router_id_strategy: "peer_overlay_ipv6_hash")
        @account = account
        @router_id_strategy = router_id_strategy
      end

      def allocate!
        used = ::Sdwan::AccountBgp.pluck(:as_number).to_set

        MAX_ATTEMPTS.times do |attempt|
          candidate = candidate_as(attempt)
          next if used.include?(candidate)

          row = ::Sdwan::AccountBgp.create!(
            account_id: @account.id,
            as_number: candidate,
            router_id_strategy: @router_id_strategy,
            enabled: true
          )
          return row
        rescue ActiveRecord::RecordNotUnique
          next # another process took it; try again
        end

        raise CapacityExhausted,
              "could not find a free AS for account #{@account.id} after #{MAX_ATTEMPTS} attempts"
      end

      private

      # Hash the account ID + attempt counter into the private AS range.
      # Attempt 0 is deterministic; subsequent attempts perturb the seed
      # so we don't infinite-loop on a colliding deterministic pick.
      def candidate_as(attempt)
        seed = "#{@account.id}:#{attempt}"
        digest = Digest::SHA256.hexdigest(seed).first(16).to_i(16)
        range = ::Sdwan::AccountBgp::PRIVATE_AS_MAX - ::Sdwan::AccountBgp::PRIVATE_AS_MIN + 1
        ::Sdwan::AccountBgp::PRIVATE_AS_MIN + (digest % range)
      end
    end
  end
end
