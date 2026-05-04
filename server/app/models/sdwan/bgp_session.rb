# frozen_string_literal: true

# Sdwan::BgpSession — observed live state of an iBGP session. Written
# only by the agent reporter loop (frr_observer.go parses `vtysh -c
# "show bgp summary json"` and POSTs the result to /node_api/status/bgp).
# Read by operators in the routing dashboard and by sensors detecting
# session flap.
#
# Slice 9c of the SDWAN plan.
module Sdwan
  class BgpSession < ApplicationRecord
    self.table_name = "sdwan_bgp_sessions"

    STATES = %w[idle connect active opensent openconfirm established].freeze

    belongs_to :peer, class_name: "Sdwan::Peer", foreign_key: :sdwan_peer_id
    belongs_to :network, class_name: "Sdwan::Network", foreign_key: :sdwan_network_id
    belongs_to :neighbor_peer, class_name: "Sdwan::Peer",
               foreign_key: :neighbor_peer_id, optional: true

    validates :neighbor_address, presence: true
    validates :state, inclusion: { in: STATES }
    validates :last_observed_at, presence: true

    scope :established, -> { where(state: "established") }
    scope :unhealthy,   -> { where.not(state: "established") }

    def established?
      state == "established"
    end

    # The session's age in seconds since last observation — useful for
    # the BgpSessionHealthSensor (slice 9f) to detect stale rows.
    def stale?(threshold_seconds: 120)
      last_observed_at < threshold_seconds.seconds.ago
    end
  end
end
