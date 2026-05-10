# frozen_string_literal: true

# Sdwan::FlowSample — one decoded flow record from an IPFIX exporter.
# Persisted by Sdwan::IpfixIngestService when sidecars POST batched JSON
# to the platform's ingest endpoint.
#
# The 5-tuple + counters + lifetime is the standard NetFlow/IPFIX
# representation of "a conversation between two endpoints over a window
# of time". Each row is one such conversation as observed by the OVS
# bridge that exported it.
#
# Validation is lightweight at the model layer because the ingester
# service validates the batch up-front (rejecting bad rows before
# insert_all rather than per-row). The model carries the same
# constraints for defensive read-side use.
#
# Phase O6 follow-up of the OVS+OVN dual-profile networking roadmap.
module Sdwan
  class FlowSample < ApplicationRecord
    self.table_name = "sdwan_flow_samples"

    # Standard IANA protocol numbers most commonly seen in flow data.
    # Validation accepts any 0-255 value (full IANA range); these are
    # surfaced as constants so operator queries / dashboards have a
    # canonical place to look up the labels.
    PROTOCOLS = {
      icmp:    1,
      tcp:     6,
      udp:    17,
      icmpv6: 58
    }.freeze

    PORT_MIN = 0
    PORT_MAX = 65_535
    PROTOCOL_MIN = 0
    PROTOCOL_MAX = 255

    belongs_to :account
    belongs_to :ipfix_collector,
               class_name: "Sdwan::IpfixCollector",
               foreign_key: :ipfix_collector_id

    validates :src_ip, :dst_ip, presence: true
    validates :src_port, numericality: {
                          only_integer: true,
                          greater_than_or_equal_to: PORT_MIN,
                          less_than_or_equal_to: PORT_MAX
                        }, allow_nil: true
    validates :dst_port, numericality: {
                          only_integer: true,
                          greater_than_or_equal_to: PORT_MIN,
                          less_than_or_equal_to: PORT_MAX
                        }, allow_nil: true
    validates :protocol, numericality: {
                           only_integer: true,
                           greater_than_or_equal_to: PROTOCOL_MIN,
                           less_than_or_equal_to: PROTOCOL_MAX
                         }
    validates :octet_count, :packet_count, numericality: {
                                              only_integer: true,
                                              greater_than_or_equal_to: 0
                                            }
    validates :flow_start_at, :flow_end_at, :observed_at, presence: true

    scope :for_account,   ->(acct) { where(account_id: acct.id) }
    scope :for_collector, ->(c)    { where(ipfix_collector_id: c.id) }
    scope :since,         ->(t)    { where("observed_at >= ?", t) }
    scope :until_time,    ->(t)    { where("observed_at <= ?", t) }
    scope :recent,        -> { order(observed_at: :desc) }

    # Convenience for serialization — the IANA protocol number is the
    # source of truth, but operators usually think in protocol names.
    def protocol_label
      PROTOCOLS.invert[protocol]&.to_s || protocol.to_s
    end
  end
end
