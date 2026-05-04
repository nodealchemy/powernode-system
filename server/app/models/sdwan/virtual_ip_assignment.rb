# frozen_string_literal: true

# Sdwan::VirtualIpAssignment — append-only history of VIP holder
# transitions. The current holder(s) are rows where released_at IS NULL.
# Slice 9b creates rows on initial assignment + manual failover; slice 9f
# creates rows on sensor-driven failover.
#
# Slice 9b of the SDWAN plan.
module Sdwan
  class VirtualIpAssignment < ApplicationRecord
    self.table_name = "sdwan_virtual_ip_assignments"

    REASONS = %w[initial manual_failover sensor_failover holder_changed revoked].freeze

    belongs_to :virtual_ip, class_name: "Sdwan::VirtualIp",
               foreign_key: :sdwan_virtual_ip_id
    belongs_to :peer,       class_name: "Sdwan::Peer",
               foreign_key: :sdwan_peer_id
    belongs_to :triggered_by_user, class_name: "::User", optional: true,
               foreign_key: :triggered_by_user_id

    validates :assumed_at, presence: true
    validates :reason, inclusion: { in: REASONS }

    scope :active,   -> { where(released_at: nil) }
    scope :released, -> { where.not(released_at: nil) }

    def active?
      released_at.nil?
    end
  end
end
