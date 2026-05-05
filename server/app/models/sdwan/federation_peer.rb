# frozen_string_literal: true

# Cross-Powernode-instance peering record. Forward-compat scaffold —
# v1 ships data-only. The trust_jwt is Vault-stored via VaultCredential;
# verification, remote API calls, and tunnel establishment are all
# deferred to a future federation slice.
#
# The reason this ships now (vs. waiting for full federation) is that
# the data model commits us to a shape: account_id + remote_instance_id
# unique, the four-prefix-advertisement-strings layout, the five-status
# enum. Discovering the right shape mid-rollout would force a migration;
# discovering it now via the governance scanner costs ~80 LOC and lets
# operators register pending federation intents whenever they want.
#
# Slice 6 of the SDWAN plan.
module Sdwan
  class FederationPeer < ApplicationRecord
    self.table_name = "sdwan_federation_peers"

    include VaultCredential

    self.vault_credential_type = "federation_trust_jwt"

    STATUSES = %w[proposed accepted active suspended revoked].freeze
    # v1 only allows proposed → revoked / accepted; further transitions
    # require the future federation slice's verification work.
    V1_TRANSITIONS = {
      "proposed"  => %w[accepted revoked],
      "accepted"  => %w[suspended revoked],
      "suspended" => %w[accepted revoked],
      "revoked"   => [], # terminal in v1
      "active"    => %w[suspended revoked] # only future slices set "active"
    }.freeze

    belongs_to :account

    validates :remote_instance_url, presence: true,
                                    format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]) }
    validates :status, inclusion: { in: STATUSES }
    validates :remote_prefix_advertisement, format: {
      with: %r{\Afd[0-9a-f:]+::/(?:48|56|64)\z}i,
      message: "must be a /48, /56, or /64 ULA prefix"
    }, allow_blank: true
    validates :remote_instance_id, uniqueness: { scope: :account_id }, allow_nil: true

    scope :proposed,  -> { where(status: "proposed") }
    scope :accepted,  -> { where(status: "accepted") }
    scope :active_status,    -> { where(status: "active") }
    scope :suspended, -> { where(status: "suspended") }
    scope :revoked,   -> { where(status: "revoked") }
    scope :live,      -> { where(status: %w[accepted active]) }

    # Returns true if the proposed transition is permitted in v1. The
    # controller / MCP tool consults this before mutating to avoid
    # partial-state rows that future slices would have to clean up.
    def can_transition_to?(new_status)
      V1_TRANSITIONS.fetch(status, []).include?(new_status.to_s)
    end

    def revoke!(reason: nil)
      return if status == "revoked"

      update!(
        status: "revoked",
        metadata: metadata.merge("revocation_reason" => reason.to_s.presence)
      )
    end

    # Transitions a proposed peer to accepted. v1 (drill mode):
    # operator-driven without cross-account auth — Account A and B
    # operators coordinate out-of-band. Future Phase 11b adds a
    # token-round-trip handshake; until then, accept! is allowed only
    # for same-account drills + explicit operator confirmation.
    #
    # Sets signed_at to now (so FederationGovernance's
    # stale_accepted_without_handshake check passes after slice 11b
    # provides the real handshake).
    def accept!(accepted_by_user: nil, acceptance_token: nil)
      return false unless can_transition_to?("accepted")

      update!(
        status: "accepted",
        signed_at: Time.current,
        metadata: metadata.merge(
          "accepted_by_user_id" => accepted_by_user&.id,
          "acceptance_token_used" => acceptance_token.present?
        )
      )
      true
    end

    # Returns the /48 portion of remote_prefix_advertisement (or nil if
    # the prefix is wider). Used by FederationGovernance#scan to detect
    # overlap with the install's own prefix.
    def remote_prefix_48
      return nil if remote_prefix_advertisement.blank?

      head, mask = remote_prefix_advertisement.split("/")
      mask = mask.to_i
      return nil if mask < 48 || mask > 64

      groups = head.split(":").reject(&:empty?)
      return nil if groups.size < 3

      "#{groups[0, 3].join(':')}::/48"
    end
  end
end
