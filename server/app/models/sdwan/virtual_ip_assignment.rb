# frozen_string_literal: true

# Sdwan::VirtualIpAssignment — append-only history of VIP holder
# transitions. The current holder(s) are rows where released_at IS NULL.
# Slice 9b creates rows on initial assignment + manual failover; slice 9f
# creates rows on sensor-driven failover.
#
# Slice 9b of the SDWAN plan.
module Sdwan
  class VirtualIpAssignment < ApplicationRecord
    self.table_name = "system_sdwan_virtual_ip_assignments"

    # IMP-43cf1e6b5541 — "phantom_backfill" tags a row created by
    # Sdwan::VirtualIpPhantomHolderBackfillService (rake sdwan:backfill_phantom_vip_holders):
    # a stray holder id already present in a VIP's holder_peer_ids before
    # this task's on-change validation existed, discovered without a real
    # holder-transition event to attribute it to. Distinct from
    # "holder_changed" so the audit trail doesn't misrepresent a
    # reconciliation as a live operator/sensor-driven change.
    REASONS = %w[initial manual_failover sensor_failover holder_changed revoked phantom_backfill].freeze

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
