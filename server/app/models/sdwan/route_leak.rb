# frozen_string_literal: true

# Sdwan::RouteLeak — explicit cross-VRF route import. The platform
# defaults to full isolation between networks (no shared RIB, no
# implicit `import vrf`), so the only supported way for prefixes from
# network A to appear in network B's forwarding table is an active
# RouteLeak row owned by the destination network.
#
# Direction:
#   one_way        → source_network → dest_network
#   bidirectional  → also emit the reverse leak (the compiler renders
#                    both halves; one row carries the intent)
#
# State (proposed → active → revoked):
#   proposed → operator/AI filed the leak; not yet emitted
#   active   → compiled into both peers' frr.conf; routes are leaking
#   revoked  → operator/AI withdrew the leak; compiler stops emitting it
#
# Phase N1a of the in-house encrypted mesh overlay roadmap.
module Sdwan
  class RouteLeak < ApplicationRecord
    include AASM

    self.table_name = "sdwan_route_leaks"

    DIRECTIONS  = %w[one_way bidirectional].freeze
    STATES      = %w[proposed active revoked].freeze
    FILTER_ACTIONS = %w[permit deny].freeze

    attribute :prefix_filter, :json, default: -> { [] }

    belongs_to :source_network, class_name: "Sdwan::Network"
    belongs_to :dest_network,   class_name: "Sdwan::Network"
    belongs_to :account
    belongs_to :approved_by, class_name: "User", optional: true

    validates :direction, inclusion: { in: DIRECTIONS }
    validates :state, inclusion: { in: STATES }
    validate :networks_must_differ
    validate :networks_must_share_account
    validate :prefix_filter_well_formed
    validates :source_network_id,
              uniqueness: { scope: %i[dest_network_id direction] }

    scope :active,   -> { where(state: "active") }
    scope :proposed, -> { where(state: "proposed") }
    scope :revoked,  -> { where(state: "revoked") }
    scope :for_account, ->(acct) { where(account_id: acct.id) }
    # Compiler hook — leaks the FRR compiler emits clauses for.
    scope :compilable, -> { where(state: "active") }
    # Lookup hook — every leak whose source OR dest is the given
    # network. Used by the compiler when rendering a host's per-VRF
    # blocks.
    scope :touching_network, ->(net) {
      where("source_network_id = ? OR dest_network_id = ?", net.id, net.id)
    }

    aasm column: :state, whiny_transitions: false do
      state :proposed, initial: true
      state :active
      state :revoked

      event :activate do
        transitions from: %i[proposed revoked], to: :active
        before { self.activated_at ||= Time.current; self.revoked_at = nil }
      end

      event :revoke do
        transitions from: %i[proposed active revoked], to: :revoked
        before { self.revoked_at ||= Time.current }
      end
    end

    # Returns the (source, dest) pairs the compiler should emit clauses
    # for. one_way leaks return one pair; bidirectional leaks return
    # both. Each pair is a small hash so the compiler can name route
    # maps and prefix-lists deterministically.
    def directed_pairs
      pairs = [{ source: source_network, dest: dest_network }]
      if direction == "bidirectional"
        pairs << { source: dest_network, dest: source_network }
      end
      pairs
    end

    private

    def networks_must_differ
      return if source_network_id.blank? || dest_network_id.blank?
      return if source_network_id != dest_network_id

      errors.add(:dest_network_id,
                 "must differ from source_network_id (a network cannot " \
                 "leak into itself)")
    end

    def networks_must_share_account
      return if source_network.blank? || dest_network.blank?
      return if source_network.account_id == dest_network.account_id

      errors.add(:base,
                 "source and dest networks must belong to the same account")
    end

    def prefix_filter_well_formed
      entries = Array(prefix_filter)
      return if entries.empty?

      entries.each do |entry|
        unless entry.is_a?(Hash)
          errors.add(:prefix_filter, "entries must be objects")
          return
        end
        cidr   = entry["cidr"]   || entry[:cidr]
        action = entry["action"] || entry[:action]
        unless cidr.is_a?(String) && cidr.match?(%r{\A[0-9a-f.:]+/\d{1,3}\z}i)
          errors.add(:prefix_filter, "contains invalid CIDR: #{cidr.inspect}")
          return
        end
        unless FILTER_ACTIONS.include?(action.to_s)
          errors.add(:prefix_filter,
                     "action must be one of #{FILTER_ACTIONS.join(', ')} " \
                     "(got #{action.inspect})")
          return
        end
      end
    end
  end
end
