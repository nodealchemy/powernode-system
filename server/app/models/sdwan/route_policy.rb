# frozen_string_literal: true

# Sdwan::RoutePolicy — declarative iBGP route policies. The compiler
# (Sdwan::Bgp::RoutePolicyCompiler) translates the model's `statements`
# JSONB into FRR's route-map syntax + auxiliary objects (prefix-lists,
# as-path-lists, community-lists).
#
# v1 statement schema:
#   {
#     "match": {
#       "prefix_in":      ["10.0.0.0/24", "fdf8::/64"],
#       "as_path_regex":  "^4200000000_",
#       "community_in":   ["64512:100", "64512:200"]
#     },
#     "action": {
#       "type":            "accept" | "reject",
#       "set_local_pref":  200,
#       "set_med":         50,
#       "prepend_as_path": 3,
#       "add_community":   "64512:300"
#     }
#   }
#
# Match keys are union-ed (route matches if ALL specified match keys
# pass, AND-style — same as a route-map clause). Action `type` is
# required; the rest are optional.
#
# Slice 9e of the SDWAN plan.
module Sdwan
  class RoutePolicy < ApplicationRecord
    self.table_name = "sdwan_route_policies"

    SCOPES     = %w[account network peer].freeze
    DIRECTIONS = %w[import export].freeze
    ACTION_TYPES = %w[accept reject].freeze
    MATCH_KEYS = %w[prefix_in as_path_regex community_in tag_in peer_in].freeze
    ACTION_KEYS = %w[type set_local_pref set_med prepend_as_path add_community].freeze

    belongs_to :account

    validates :name, presence: true, length: { maximum: 64 },
                     uniqueness: { scope: :account_id }
    validates :scope, inclusion: { in: SCOPES }
    validates :direction, inclusion: { in: DIRECTIONS }
    validates :statements, presence: true
    validate  :statements_well_formed
    validate  :scope_resource_consistency

    scope :enabled, -> { where(enabled: true) }
    scope :for_scope, ->(scope) { where(scope: scope) }
    scope :for_account_scope, -> { where(scope: "account") }
    scope :for_network, ->(network_id) { where(scope: "network", scope_resource_id: network_id) }
    scope :for_peer, ->(peer_id) { where(scope: "peer", scope_resource_id: peer_id) }

    # Returns every policy that *would* apply to a peer's compile pass:
    # account-scoped + the peer's network-scoped + the peer's own
    # peer-scoped policies, in narrowing order. The compiler emits FRR
    # route-map clauses preserving this ordering so account policies
    # apply first, then network, then peer.
    def self.applicable_to(peer:)
      where(account_id: peer.account_id, enabled: true).where(
        "(scope = 'account') OR " \
        "(scope = 'network' AND scope_resource_id = ?) OR " \
        "(scope = 'peer' AND scope_resource_id = ?)",
        peer.sdwan_network_id, peer.id
      ).order(Arel.sql("CASE scope WHEN 'account' THEN 0 WHEN 'network' THEN 1 WHEN 'peer' THEN 2 END, name"))
    end

    # FRR-safe lowercase-and-hyphens identifier derived from the
    # operator-supplied name. The compiler uses this to namespace
    # generated route-map / prefix-list names so two policies named
    # similarly don't collide in FRR's flat namespace.
    def slug
      "pn-#{id.to_s.first(8)}-#{name.parameterize.first(20)}"
    end

    private

    def statements_well_formed
      return errors.add(:statements, "must be an array") unless statements.is_a?(Array)
      return errors.add(:statements, "cannot be empty") if statements.empty?

      statements.each_with_index do |stmt, i|
        unless stmt.is_a?(Hash)
          errors.add(:statements, "statement #{i} must be a hash")
          next
        end
        match = stmt["match"] || stmt[:match] || {}
        action = stmt["action"] || stmt[:action] || {}

        unless action.is_a?(Hash) && action["type"] || action[:type]
          errors.add(:statements, "statement #{i} action.type is required (accept|reject)")
          next
        end

        action_type = (action["type"] || action[:type]).to_s
        unless ACTION_TYPES.include?(action_type)
          errors.add(:statements, "statement #{i} action.type must be one of #{ACTION_TYPES.join(', ')}")
        end

        match.each_key do |k|
          next if MATCH_KEYS.include?(k.to_s)

          errors.add(:statements, "statement #{i} unknown match key: #{k}")
        end
        action.each_key do |k|
          next if ACTION_KEYS.include?(k.to_s)

          errors.add(:statements, "statement #{i} unknown action key: #{k}")
        end
      end
    end

    def scope_resource_consistency
      case scope
      when "account"
        if scope_resource_id.present?
          errors.add(:scope_resource_id, "must be null when scope=account")
        end
      when "network", "peer"
        if scope_resource_id.blank?
          errors.add(:scope_resource_id, "must be set when scope=#{scope}")
        end
      end
    end
  end
end
