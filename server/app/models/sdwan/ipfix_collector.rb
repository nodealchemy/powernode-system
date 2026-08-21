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

    self.table_name = "system_sdwan_ipfix_collectors"

    STATES = %w[active disabled].freeze

    belongs_to :account

    # Phase O6 follow-up — ingested flow samples cascade-delete with
    # the collector. The DB FK has on_delete: :cascade as a backstop;
    # this `dependent: :destroy` makes Rails issue the explicit
    # destroys (running model callbacks if any future flow_sample
    # callbacks land) and is the canonical Rails-side declaration.
    has_many :flow_samples,
             class_name: "Sdwan::FlowSample",
             foreign_key: :ipfix_collector_id,
             dependent: :destroy,
             inverse_of: :ipfix_collector

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
    #
    # `host` is validated for presence ONLY — no format check — and both
    # write paths (the system_sdwan_create_ipfix_collector MCP action and
    # SdwanIpfixCollectorComposeExecutor) store the operator's string
    # verbatim, so an already-bracketed "[fd00::1]" is storable. That is
    # why this goes through the shared Sdwan::HostPort rather than a local
    # bracket: the hand-rolled copy this replaced re-bracketed such a host
    # into "[[fd00::1]]:4739", which ovs-vsctl will not parse
    # (IMP-9537a74e50fa).
    def target_endpoint
      ::Sdwan::HostPort.join(host, port)
    end
  end
end
