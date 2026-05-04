# frozen_string_literal: true

# Declarative firewall policy attached to an Sdwan::Network. Rules compile
# (via Sdwan::FirewallCompiler) into an `nft` script that the agent applies
# inside `table inet powernode_sdwan` / chain `sdwan_<8-char-net-id>`.
#
# Selector grammar (v1, four primitive kinds, evaluated by SelectorResolver):
#   { "peer_id": "<uuid>" }   — exact peer's /128
#   { "tag": "<label>" }      — peer-group tag (slice 5: nft sets)
#   { "cidr": "fd...::/64" }  — explicit CIDR (use this for "the whole net")
#   { "all": true }           — wildcard (no selector clause emitted)
#
# `dst_port_range` uses Postgres int4range. Rails serializes ranges as
# "[1,65535]" by default, which is awkward for JSON consumers; the
# port_range_hash accessor exposes the friendlier {from:, to:} shape both
# in serialization and in update flows.
#
# Slice 2 of the SDWAN plan.
module Sdwan
  class FirewallRule < ApplicationRecord
    self.table_name = "sdwan_firewall_rules"

    ACTIONS    = %w[accept drop reject].freeze
    DIRECTIONS = %w[ingress egress both].freeze
    PROTOCOLS  = %w[any tcp udp icmp6].freeze
    SELECTOR_KINDS = %w[peer_id tag cidr all].freeze

    belongs_to :network, class_name: "Sdwan::Network", foreign_key: :sdwan_network_id
    belongs_to :account

    validates :name, presence: true, length: { maximum: 64 },
                     uniqueness: { scope: :sdwan_network_id }
    validates :priority, numericality: { only_integer: true,
                                         greater_than_or_equal_to: 0,
                                         less_than: 1_000_000 }
    validates :action,    inclusion: { in: ACTIONS }
    validates :direction, inclusion: { in: DIRECTIONS }
    validates :protocol,  inclusion: { in: PROTOCOLS }
    validate  :selectors_must_use_known_kinds
    validate  :port_range_only_when_tcp_or_udp

    before_validation :inherit_account_from_network

    scope :enabled,   -> { where(enabled: true) }
    scope :disabled,  -> { where(enabled: false) }
    scope :ordered,   -> { order(:priority, :name) }
    scope :ingress,   -> { where(direction: %w[ingress both]) }
    scope :egress,    -> { where(direction: %w[egress both]) }

    # ---------- JSON-friendly port_range accessors ----------
    #
    # Rails round-trips int4range columns as Range objects. Operators and
    # MCP callers find the canonical "[1,65535]" string surprising; we expose
    # an explicit { from:, to: } shape both ways. Either accessor works on
    # the model — pick whichever fits the call site.

    # Returns nil when the column is empty; otherwise { from: Int, to: Int }.
    # Postgres exclusive upper bounds (e.g., "[1,1024)") get normalized to
    # an inclusive upper for the JSON shape so consumers don't have to know
    # nft's port-range mathematics.
    def port_range_hash
      return nil if dst_port_range.nil?

      from = dst_port_range.first
      to   = dst_port_range.exclude_end? ? dst_port_range.last - 1 : dst_port_range.last
      { from: from, to: to }
    end

    def port_range_hash=(value)
      if value.nil? || value == {} || value == ""
        self.dst_port_range = nil
        return
      end
      raise ArgumentError, "port_range_hash must be a Hash" unless value.is_a?(Hash)

      from = (value[:from] || value["from"])&.to_i
      to   = (value[:to]   || value["to"])&.to_i
      raise ArgumentError, "port_range_hash requires :from and :to" if from.nil? || to.nil?

      self.dst_port_range = (from..to)
    end

    private

    def inherit_account_from_network
      return if account_id.present?
      return if sdwan_network_id.blank?

      self.account_id = network&.account_id
    end

    # Each selector's hash must contain exactly one supported key (or be
    # blank). Empty-hash and nil are both treated as "no selector"
    # (matches everything) to keep the JSON shape clean.
    def selectors_must_use_known_kinds
      %i[src_selector dst_selector].each do |attr|
        sel = read_attribute(attr)
        next if sel.blank?
        unless sel.is_a?(Hash)
          errors.add(attr, "must be a JSON object")
          next
        end

        kinds = sel.keys.map(&:to_s) & SELECTOR_KINDS
        errors.add(attr, "must contain at least one of: #{SELECTOR_KINDS.join(', ')}") if kinds.empty?
        errors.add(attr, "must contain at most one selector kind, got #{kinds.size}") if kinds.size > 1
      end
    end

    def port_range_only_when_tcp_or_udp
      return if dst_port_range.nil?
      return if %w[tcp udp].include?(protocol)

      errors.add(:dst_port_range, "is only valid when protocol is tcp or udp")
    end
  end
end
