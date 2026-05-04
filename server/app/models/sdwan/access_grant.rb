# frozen_string_literal: true

# A user's entitlement to attach VPN clients to one SDWAN network. Lives
# at the granular layer below dot-string permissions (which gate what
# operators can DO; this row gates what one specific user can REACH).
#
# Slice 4 of the SDWAN plan.
module Sdwan
  class AccessGrant < ApplicationRecord
    self.table_name = "sdwan_access_grants"

    STATUSES = %w[active suspended revoked].freeze

    belongs_to :network,      class_name: "Sdwan::Network", foreign_key: :sdwan_network_id
    belongs_to :user
    belongs_to :account
    belongs_to :granted_by,   class_name: "User", optional: true
    has_many   :user_devices, class_name: "Sdwan::UserDevice",
               foreign_key: :sdwan_access_grant_id, dependent: :destroy

    validates :status, inclusion: { in: STATUSES }
    validates :sdwan_network_id, uniqueness: { scope: :user_id }

    before_validation :inherit_account_from_network

    scope :active,    -> { where(status: "active") }
    scope :revocable, -> { where(status: %w[active suspended]) }

    def active?
      status == "active"
    end

    def revoked?
      status == "revoked"
    end

    def revoke!(reason: nil, by_user: nil)
      return if revoked?

      transaction do
        update!(
          status: "revoked",
          revoked_at: Time.current,
          revocation_reason: reason.to_s.presence
        )
        # Soft-revoke every device — the compiler immediately drops them
        # from the hub view. Vault entries persist for 90-day audit
        # retention; a slice-5 reaper can hard-delete after that window.
        user_devices.where(revoked_at: nil).find_each do |dev|
          dev.update!(revoked_at: Time.current, revocation_reason: "grant_revoked")
        end
      end
    end

    private

    def inherit_account_from_network
      return if account_id.present?
      return if sdwan_network_id.blank?

      self.account_id = network&.account_id
    end
  end
end
