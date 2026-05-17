# frozen_string_literal: true

# Time-bounded membership credential. The MC is the platform's per-peer
# proof "this peer is currently a member of network X" — it carries the
# WG public key, overlay address, managed routes, tags, and optional
# capability list, all sealed by the constellation's Ed25519 signing key.
#
# Lifecycle (AASM, mirrors System::FederationPeer's transition table style):
#
#   pending  → active   (signed and embedded in the next config push)
#   active   → expiring (TTL window crossed; agent should refresh)
#   active   → revoked  (controller withholds further refresh)
#   expiring → active   (refresh succeeded, new MC supersedes)
#   expiring → revoked  (refresh denied or controller decision)
#
# Revocation is by withholding refresh — there is no CRL. Once the agent
# fails to renew before `not_after`, it drops the tunnel.
#
# Phase N0 of the in-house encrypted mesh overlay roadmap.
class CreateSdwanMembershipCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_membership_credentials, id: :uuid do |t|
      t.references :account,    null: false, type: :uuid, foreign_key: true
      # We carry both peer + network FKs even though peer transitively
      # has network — query patterns include "all MCs in this network"
      # (governance dashboards) and "current MC for this peer" (signer
      # idempotency check), and the explicit FK lets the planner pick
      # the smaller index in each case.
      t.references :sdwan_peer, null: false, type: :uuid, foreign_key: true
      t.references :sdwan_network, null: false, type: :uuid,
                   foreign_key: { to_table: :sdwan_networks }

      # AASM state column. Mirrors the docstring above; see model for
      # the full transition table.
      t.string :status, null: false, default: "pending"

      # Monotonic per-(peer, network) counter. The signer increments
      # this on every issue so the agent can detect rollback attempts
      # — a freshly issued MC must always have rev > the cached one.
      t.bigint :revision, null: false, default: 0

      # Time window. nbf and not_before are equivalent; we use
      # not_before for symmetry with the existing NodeCertificate
      # column naming (Phase M0).
      t.datetime :issued_at, null: false
      t.datetime :not_before, null: false
      t.datetime :not_after, null: false
      # Refresh-before-expiry deadline. The agent's MC verifier loop
      # treats `refresh_after` as "start trying to renew now" — typically
      # set to issued_at + (TTL/2).
      t.datetime :refresh_after, null: false

      # The signed envelope (JSON, base64 of body + base64 of signature).
      # Carries the canonical wire form the agent verifies. We persist
      # the rendered envelope rather than re-rendering on every fetch
      # so that the bytes the agent verifies are exactly the bytes the
      # signer signed.
      t.text :envelope_json, null: false
      t.text :signature_b64, null: false

      # Constellation handle that signed this MC. Stored as a string
      # rather than an FK because constellations land in N2 — when the
      # model exists we can backfill an FK, but the wire format only
      # cares about the handle. For N0 the handle is derived from the
      # account ("constellation:<account_handle>"); N2 replaces this.
      t.string :constellation_handle, null: false

      # Vault path of the constellation signing key used for this MC.
      # Audit trail: lets us prove which key version produced which sig.
      t.string :signed_with_vault_path

      # Revocation metadata. Set only when status transitions to
      # revoked; nil otherwise.
      t.datetime :revoked_at
      t.string :revocation_reason

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    # One active MC per (peer, network). Partial index — when the
    # signer issues a fresh MC it bumps the previous one to "expiring"
    # in the same transaction so the constraint never trips on a
    # legitimate refresh.
    add_index :sdwan_membership_credentials,
              %i[sdwan_peer_id sdwan_network_id],
              unique: true,
              where: "status = 'active'",
              name: "idx_sdwan_mc_one_active_per_peer_network"

    # Ordering / lookup support for the signer + agent verifier.
    add_index :sdwan_membership_credentials,
              %i[sdwan_peer_id sdwan_network_id revision],
              name: "idx_sdwan_mc_revision_chain"

    # Sweeper queries: "find all MCs whose not_after is in the next
    # 15 minutes" (SdwanCredentialExpirySensor) and "find all expired
    # but unrevoked rows" (autonomy janitor).
    add_index :sdwan_membership_credentials, :not_after
    add_index :sdwan_membership_credentials, :status

    # Revision must be strictly positive once issued (default 0 on
    # the `pending` row gets incremented in the AASM `issue` event).
    add_check_constraint :sdwan_membership_credentials,
                         "revision >= 0",
                         name: "sdwan_mc_revision_nonneg"

    # not_after must be after not_before. Cheap insurance against
    # malformed input from a future programmatic caller.
    add_check_constraint :sdwan_membership_credentials,
                         "not_after > not_before",
                         name: "sdwan_mc_window_ordered"
  end
end
