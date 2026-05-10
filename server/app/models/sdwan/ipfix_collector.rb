# frozen_string_literal: true

# Sdwan::IpfixCollector — operator-configured IPFIX exporter target.
# When an active collector exists for an account, the topology compiler
# stamps an `ipfix:` block on every ovs-kind HostBridge entry in that
# account's per-host payload, and the agent's OvsBridgeApplier wires
# OVS's native IPFIX exporter to point at this collector.
#
# Lightweight (Linux-bridge) hosts are not affected — Linux bridges
# don't support IPFIX without an external sniffer. The OvnBridgeApplier
# is the sole consumer of the Ipfix field on DesiredBridge.
#
# Phase O5 of the OVS+OVN dual-profile networking roadmap.
module Sdwan
  class IpfixCollector < ApplicationRecord
    include AASM

    self.table_name = "sdwan_ipfix_collectors"

    STATES = %w[active disabled].freeze

    belongs_to :account

    validates :name, presence: true,
                     uniqueness: { scope: :account_id }
    validates :host, presence: true
    validates :port, presence: true,
                     numericality: {
                       only_integer: true,
                       greater_than_or_equal_to: 1,
                       less_than_or_equal_to: 65_535
                     }
    validates :sampling_rate, presence: true,
                              numericality: {
                                only_integer: true,
                                greater_than_or_equal_to: 1
                              }
    validates :state, inclusion: { in: STATES }

    scope :active,   -> { where(state: "active") }
    scope :disabled, -> { where(state: "disabled") }
    scope :for_account, ->(acct) { where(account_id: acct.id) }

    aasm column: :state, whiny_transitions: false do
      state :active, initial: true
      state :disabled

      event :disable do
        transitions from: %i[active disabled], to: :disabled
      end

      event :enable do
        transitions from: %i[active disabled], to: :active
      end
    end

    # Returns the wire-format target string the agent passes to
    # ovs-vsctl. IPv6 addresses are bracketed per OVS convention so
    # the colon in the address doesn't collide with the port separator.
    def target_endpoint
      bracketed = host.include?(":") ? "[#{host}]" : host
      "#{bracketed}:#{port}"
    end
  end
end
