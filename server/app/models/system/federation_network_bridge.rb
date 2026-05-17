# frozen_string_literal: true

module System
  # Records the SDWAN network bridge between this platform and a
  # federated peer. Created at handshake time (when peer A invites peer
  # B with `sdwan_network_id: X`, both sides create a matching bridge
  # row in `proposed` state). Transitions to `active` on handshake
  # acceptance.
  #
  # The bridge is consulted by the federation_api auth chain:
  # `FederationGrant#applies_to_network?` verifies that the SDWAN
  # network the request arrived over corresponds to an `active`
  # bridge for the calling peer.
  #
  # Plan reference: Decentralized Federation §K + P4.5.3.
  class FederationNetworkBridge < BaseRecord
    include System::Base

    STATES = %w[proposed active suspended revoked].freeze

    TRANSITIONS = {
      "proposed"  => %w[active revoked],
      "active"    => %w[suspended revoked],
      "suspended" => %w[active revoked],
      "revoked"   => []
    }.freeze

    self.table_name = "system_federation_network_bridges"

    belongs_to :federation_peer, class_name: "System::FederationPeer"
    belongs_to :sdwan_network,   class_name: "Sdwan::Network",
                                  foreign_key: :sdwan_network_id

    attribute :metadata, :jsonb, default: -> { {} }

    validates :state, inclusion: { in: STATES }
    validates :federation_peer_id, uniqueness: { scope: :sdwan_network_id }

    before_validation :stamp_proposed_at, on: :create

    scope :proposed,  -> { where(state: "proposed") }
    scope :active,    -> { where(state: "active") }
    scope :suspended, -> { where(state: "suspended") }
    scope :revoked,   -> { where(state: "revoked") }
    scope :live,      -> { where(state: %w[proposed active]) }

    def can_transition_to?(target)
      TRANSITIONS.fetch(state, []).include?(target.to_s)
    end

    def activate!
      return false unless can_transition_to?("active")
      update!(state: "active", activated_at: Time.current)
    end

    def suspend!(reason: nil)
      return false unless can_transition_to?("suspended")
      update!(
        state: "suspended",
        suspended_at: Time.current,
        metadata: metadata.merge("suspension_reason" => reason.to_s.presence)
      )
    end

    def revoke!(reason: nil)
      return false unless can_transition_to?("revoked")
      update!(
        state: "revoked",
        revoked_at: Time.current,
        revocation_reason: reason.to_s.presence
      )
    end

    def active?
      state == "active"
    end

    private

    def stamp_proposed_at
      self.proposed_at ||= Time.current
    end
  end
end
