# frozen_string_literal: true

module System
  # Audit F2-04 — revocation channel for A2A capability tokens. Tokens are
  # verified OFFLINE by the on-node agent, so a revoked grant / disabled peer
  # must be pushed to verifiers explicitly: rows here are advertised alongside
  # capability_keys (node_api/a2a/capability_keys) and the agent's verifier
  # rejects tokens whose `sub` (or `jti`) is listed.
  #
  # Rows expire MAX_TTL_SECONDS after publication — by then every token the
  # revocation could cover has itself expired, so the set stays small.
  class PeerCapabilityRevocation < BaseRecord
    include System::Base

    belongs_to :account

    validates :expires_at, presence: true
    validates :sub, presence: true, unless: -> { jti.present? }

    scope :active, -> { where("expires_at > ?", Time.current) }

    # Revoke all outstanding tokens minted for a peer's instance (sub-wide).
    # Idempotent per call; repeated publications just extend coverage.
    def self.publish_for_peer!(peer, reason:)
      create!(
        account_id: peer.account_id,
        sub: peer.node_instance_id,
        reason: reason,
        expires_at: Time.current + ::System::PeerCapabilityTokenSigner::MAX_TTL_SECONDS.seconds
      )
    end

    # Active revocations for advertisement to agents:
    # { "subs" => [...], "jtis" => [...] }
    def self.advertised_for(account)
      rows = active.where(account_id: account.id).pluck(:sub, :jti)
      {
        "subs" => rows.map(&:first).compact.uniq,
        "jtis" => rows.map(&:last).compact.uniq
      }
    end
  end
end
