# frozen_string_literal: true

# Per-peer WireGuard keypair record. Public key is column-stored (it isn't
# secret); private key lives Vault-first via the VaultCredential concern at
# vault_credential_type "wireguard_node_key", with encrypted DB fallback.
#
# Rotation creates a new row whose rotated_from_id chains back to the
# previous one. The `idx_sdwan_peer_keys_one_active_per_peer` partial unique
# index ensures only one un-revoked key exists per peer at any time.
#
# Slice 1 of the SDWAN plan.
module Sdwan
  class PeerKey < ApplicationRecord
    self.table_name = "system_sdwan_peer_keys"

    include VaultCredential

    self.vault_credential_type = "wireguard_node_key"

    # `touch: true` IS LOAD-BEARING (IMP-8ce5262ee9ec). A publicly-reachable
    # peer's ACTIVE PUBLIC KEY is rendered into every user device's config —
    # Sdwan::WgConfigRenderer emits one [Peer] section per reachable hub
    # carrying that hub's current key. A node peer re-pulls its view every
    # tick and converges; a USER DEVICE is rendered exactly once, at download
    # time, after which UserDevice#mark_downloaded! makes the bootstrap URL
    # 410 Gone. So a rotation leaves every previously-issued client holding a
    # key the hub no longer has, and its tunnel stops handshaking OUTRIGHT —
    # strictly worse than the narrowed-AllowedIPs drift the staleness sensor
    # was built for. Rotation runs on an autonomous lane with no approval
    # gate: SdwanDriftSensor's system.sdwan_peer_drift routes to
    # SdwanPeerRemediateExecutor under action_category
    # "system.sdwan_peer_remediate", seeded notify_and_proceed. (The
    # auto_approve "system.sdwan_key_rotate" category is seeded but has NO
    # producer since IMP-df40782d3f4d — it is kept for a future key-TTL lane,
    # which is exactly the caller this touch has to be correct for in advance.)
    #
    # Sdwan::KeyDistributor.rotate! writes ONLY PeerKey rows (a revoke on the
    # old, an insert of the new); without this the peer row never moves, and
    # SdwanUserDeviceConfigStalenessSensor's peer arm
    # (contributing_peers.maximum(:updated_at)) — the one consumer of this
    # stamp — cannot see a re-key at all. That blindness was verified by
    # execution before this was added, driving KeyDistributor.rotate!
    # DIRECTLY rather than through SdwanPeerRemediateExecutor, which also
    # does `peer.update_columns(..., updated_at: Time.current)` for its own
    # reconcile reasons and would mask the gap.
    #
    # That executor is today's only live rotate! caller, so the gap is
    # currently LATENT rather than firing — but it is masked by COINCIDENCE,
    # not by design: that update_columns exists to force the agent's next
    # reconcile, says so, and would be a correct thing to drop. Any other
    # caller — the seeded key-TTL lane, an operator/MCP rotation, a backfill —
    # reopens it. The stamp belongs on the producer, which is here.
    #
    # WHY THIS IS NOT A NEW FALSE-STALENESS SOURCE. The touch fires on every
    # PeerKey write, not just rotation, but neither other writer moves the
    # stamp anywhere it was not already moving:
    #   * ensure_key_for! at enrollment (Sdwan::PeerEnroller) writes a key on
    #     a peer row that was itself just inserted, so updated_at is already
    #     ~now; and a newly-enrolled CONTRIBUTING peer (a hub, or a spoke with
    #     lan_subnets) genuinely does change what the renderer emits.
    #   * SdwanPeerRemediateExecutor already stamps updated_at unconditionally
    #     for hubs AND spokes, so the spoke-re-key case it could overfire on
    #     is one that lane already produces today.
    # The residual imprecision — a spoke re-key reached by some future
    # non-executor caller would stale a network whose rendered surface did not
    # move, because contributing_peers admits spokes for their lan_subnets —
    # is filed, not fixed here: removing it wants the sensor's own recommended
    # fourth arm over PeerKey#created_at scoped to publicly_reachable peers,
    # which is a change to the sensor rather than to this association.
    belongs_to :peer, class_name: "Sdwan::Peer", foreign_key: :sdwan_peer_id, touch: true
    belongs_to :rotated_from, class_name: "Sdwan::PeerKey", optional: true

    delegate :account_id, to: :peer

    validates :public_key, presence: true, uniqueness: true,
                           length: { is: 44 },
                           format: { with: /\A[A-Za-z0-9+\/]{43}=\z/, message: "must be a base64-encoded 32-byte key" }

    scope :active,  -> { where(revoked_at: nil) }
    scope :revoked, -> { where.not(revoked_at: nil) }

    def revoked?
      revoked_at.present?
    end

    def revoke!(reason: nil)
      return if revoked?

      update!(revoked_at: Time.current, revocation_reason: reason.to_s.presence)
    end

    # Convenience accessor — VaultCredential#vault_credentials returns the
    # full hash {public_key:, private_key:}; callers usually want just the
    # private half. Returns nil when the row is revoked or Vault has no
    # entry for it.
    def private_key
      return nil if revoked?

      data = vault_credentials
      data.is_a?(Hash) ? (data[:private_key] || data["private_key"]) : nil
    end
  end
end
