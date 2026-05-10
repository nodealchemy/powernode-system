# frozen_string_literal: true

# Sdwan::OvnAcl — per-logical-switch firewall rule expressed in OVN's
# match-language. The compiler renders each active row to an `acl-add`
# command on the parent switch.
#
# Why ACLs (vs. SDWAN nftables firewall rules):
#   - SDWAN firewall rules (Sdwan::FirewallRule) operate at the inter-
#     peer scope (host A → host B traffic, compiled to nftables on
#     each host). ACLs operate at the intra-host / logical-network
#     scope (pod-to-pod within an OVN logical switch, compiled to OVS
#     OpenFlow rules via OVN's logical-flow translation).
#   - Different scopes, no overlap. Heavyweight hosts use ACLs for
#     intra-host filtering; lightweight hosts use kube-proxy
#     NetworkPolicy for the equivalent function.
#   - Per the Phase O5 non-goal: "Do NOT run both nftables (intra-host)
#     and OVN ACLs on the same host."
#
# Match expression syntax:
#   OVN's match language is a C-like boolean DSL with field references
#   like `ip4.src`, `ip6.dst`, `tcp.dst`, `udp.src`, plus boolean
#   operators (`&&`, `||`, `!`). The model stores the raw expression
#   as text and lets OVN's parser reject malformed values at apply
#   time — building a Ruby validator for OVN's rich grammar would
#   duplicate work that OVN already does.
#
# Lifecycle (AASM column: state):
#   pending → row created; not yet emitted to OVN
#   active  → compiler is emitting it; northd has compiled it into SB
#   removed → operator/AI deleted it; row stays for audit but is
#             excluded from compiler emissions (mirrors switches/ports)
#
# Phase O6 follow-up of the OVS+OVN dual-profile networking roadmap.
module Sdwan
  class OvnAcl < ApplicationRecord
    include AASM

    self.table_name = "sdwan_ovn_acls"

    STATES     = %w[pending active removed].freeze
    DIRECTIONS = %w[from-lport to-lport].freeze
    ACTIONS    = %w[allow drop reject allow-related].freeze

    # OVN ACL name limit. Both the model and the DB column enforce this
    # so a bad name never reaches northd through bypassed validators.
    NAME_MAX = 63
    NAME_FORMAT = /\A[\w\-.]+\z/.freeze

    # OVN's actual range. Higher values evaluated first; ties broken
    # by lexicographic match-string order (per OVN's documented
    # tiebreaker, not platform behavior).
    PRIORITY_MIN = 0
    PRIORITY_MAX = 32_767
    DEFAULT_PRIORITY = 1000

    belongs_to :account
    belongs_to :logical_switch,
               class_name: "Sdwan::OvnLogicalSwitch",
               foreign_key: :sdwan_ovn_logical_switch_id,
               inverse_of: :acls

    validates :name, presence: true,
                     length: { maximum: NAME_MAX },
                     format: { with: NAME_FORMAT,
                               message: "may only contain letters, digits, _, -, ." },
                     uniqueness: { scope: :sdwan_ovn_logical_switch_id }
    validates :direction, inclusion: { in: DIRECTIONS }
    validates :action,    inclusion: { in: ACTIONS }
    validates :state,     inclusion: { in: STATES }
    validates :priority,  numericality: {
                            only_integer: true,
                            greater_than_or_equal_to: PRIORITY_MIN,
                            less_than_or_equal_to: PRIORITY_MAX
                          }
    validates :match,     presence: true

    scope :active,      -> { where(state: "active") }
    scope :pending,     -> { where(state: "pending") }
    scope :removed,     -> { where(state: "removed") }
    # Compiler hook — only active rows are emitted.
    scope :compilable,  -> { where(state: "active") }
    scope :for_switch,  ->(s) { where(sdwan_ovn_logical_switch_id: s.id) }

    aasm column: :state, whiny_transitions: false do
      state :pending, initial: true
      state :active
      state :removed

      event :mark_active do
        transitions from: %i[pending active], to: :active
        before { self.activated_at ||= Time.current }
      end

      event :mark_removed do
        transitions from: %i[pending active removed], to: :removed
        before { self.removed_at ||= Time.current }
      end

      event :readopt do
        transitions from: :removed, to: :active
        before do
          self.removed_at = nil
          self.activated_at ||= Time.current
        end
      end
    end
  end
end
