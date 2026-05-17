# frozen_string_literal: true

# P4.6 — system_federation_service_subscriptions: the subscriber-side
# record of consumption of an operator's ServiceOffering.
#
# Each row links:
#   - a remote ServiceOffering (snapshotted by slug + advisory remote UUID)
#   - the FederationPeer this subscription is with (the operator)
#   - the FederationGrant issued by the operator for this consumption
#   - the local AcmeCertificate covering the chosen local_hostname
#     (nullable for site-local TCP forwards which need no cert)
#
# State machine: pending → active ⇄ suspended → cancelled (terminal).
# `active` requires grant valid + cert valid + Traefik route written.
#
# Plan reference: Decentralized Federation §L + P4.6 + LD #13.
class CreateSystemFederationServiceSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :system_federation_service_subscriptions, id: :uuid do |t|
      t.references :account,
        type: :uuid, null: false,
        foreign_key: { to_table: :accounts, on_delete: :cascade }

      # The operator peer this subscription is with.
      t.references :federation_peer,
        type: :uuid, null: false,
        foreign_key: { to_table: :system_federation_peers, on_delete: :cascade }

      # Slug snapshot — stable identifier the operator uses for the offering.
      # Even if the operator later renames the offering, this preserves the
      # original reference for audit + recovery.
      t.string :service_offering_slug, null: false, limit: 64

      # Advisory FK to the remote offering's UUID. The remote peer's
      # offering row is in a DIFFERENT database (their account), so
      # there's no constraint we can enforce — this is just a pointer
      # for cross-peer reference resolution.
      t.uuid :service_offering_id

      # Subscriber's chosen local subdomain (or "localhost:<port>" for
      # site-local TCP forwards). The cert + Traefik route are bound
      # to this hostname.
      t.string :local_hostname, null: false, limit: 255

      # Snapshotted from the offering at subscribe time so a later
      # change to the offering doesn't silently move the subscriber's
      # backend.
      t.string :protocol, null: false, limit: 16
      t.string :backend_vip, limit: 255
      t.integer :backend_port, null: false

      # The grant the operator issued for this consumption. Forms the
      # bearer-token auth chain on every outbound request.
      t.references :federation_grant,
        type: :uuid, null: false,
        foreign_key: { to_table: :system_federation_grants, on_delete: :restrict }

      # The cert covering local_hostname. Nullable for site-local TCP
      # forwards (`local_hostname` like "localhost:5432" — no public
      # cert needed since traffic never leaves the loopback interface).
      t.references :acme_certificate,
        type: :uuid, null: true,
        foreign_key: { to_table: :system_acme_certificates, on_delete: :nullify }

      # Lifecycle state.
      t.string :status, null: false, default: "pending", limit: 16

      t.datetime :subscribed_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :activated_at
      t.datetime :suspended_at
      t.datetime :cancelled_at

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # One subscription per (account, local_hostname) — can't subscribe
    # the same hostname to two services.
    add_index :system_federation_service_subscriptions, [ :account_id, :local_hostname ],
              unique: true,
              name: "idx_fed_service_subs_acct_hostname_unique"

    # Quick lookup of "what does peer X provide me"
    add_index :system_federation_service_subscriptions, [ :federation_peer_id, :service_offering_slug ],
              name: "idx_fed_service_subs_peer_slug"

    add_index :system_federation_service_subscriptions, :status
  end
end
