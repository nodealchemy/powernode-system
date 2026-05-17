# frozen_string_literal: true

# P4.6 — system_federation_service_offerings: the operator-side
# catalog of services that subscriber peers can consume.
#
# Each row represents one service the operator offers (e.g. "managed
# Gitea", "Postgres-as-a-service"). Subscribers browse the catalog
# via federation_api/service_catalog and create a subscription via
# federation_api/subscriptions; that flow issues a FederationGrant
# scoped to the offering and returns the backend connection details.
#
# State machine: draft → active ⇄ deprecated → retired (terminal).
# `deprecated` rejects new subscriptions but continues to serve
# existing ones; `retired` triggers Social Contract #4 notification
# with a 30-day grace period before backend access is revoked.
#
# Plan reference: Decentralized Federation §L + P4.6 + LD #13.
class CreateSystemFederationServiceOfferings < ActiveRecord::Migration[8.0]
  def change
    create_table :system_federation_service_offerings, id: :uuid do |t|
      t.references :account,
        type: :uuid, null: false,
        foreign_key: { to_table: :accounts, on_delete: :cascade }

      # Operator-chosen slug, unique within the account. Subscribers
      # reference offerings by slug, not UUID (slugs are stable +
      # human-readable; offering UUIDs are an implementation detail).
      t.string :slug, null: false, limit: 64

      # Operator-visible display label + long-form description.
      t.string :name, null: false, limit: 255
      t.text :description_markdown

      # Protocol determines how the subscriber's local Traefik routes
      # traffic. https/http → HTTPRouter; tcp/tls → TCPRouter.
      t.string :protocol, null: false, limit: 16

      # Backend address: VIP-by-FK (preferred, allows VIP failover)
      # OR host string (fallback for static endpoints).
      t.references :backend_vip,
        type: :uuid, null: true,
        foreign_key: { to_table: :sdwan_virtual_ips, on_delete: :nullify }
      t.string :backend_host, limit: 255
      t.integer :backend_port, null: false

      # Operator-supplied prose shown to subscribers at subscribe time.
      t.text :subscription_terms_markdown

      # Capacity model: max_subscribers (hard cap), max_concurrent_connections,
      # region_support array, etc. Schema is loose to allow operator
      # experimentation without migrations.
      t.jsonb :capacity_metadata, null: false, default: {}

      # Latency expectations: { p50_ms, p95_ms, region: "us-west" }, etc.
      # Subscribers self-select based on declared latency.
      t.jsonb :latency_metadata, null: false, default: {}

      # Default grant lifetime issued when a subscription is created.
      # Operator can override per-subscription; this is the catalog
      # default. Floor of 7 days per Architectural Fix 2.
      t.integer :default_grant_ttl_days, null: false, default: 30

      # Permission scopes baked into the issued grant. Subscribers
      # inherit these (can't elevate). Typical: ["read", "write"].
      t.jsonb :default_grant_scopes, null: false, default: [ "read" ]

      # Lifecycle state. Only `active` accepts new subscriptions.
      t.string :status, null: false, default: "draft", limit: 16
      t.datetime :deprecated_at
      t.datetime :retired_at

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # One offering per (account, slug). Slugs are how subscribers
    # discover and reference offerings.
    add_index :system_federation_service_offerings, [ :account_id, :slug ],
              unique: true,
              name: "idx_fed_service_offerings_acct_slug_unique"

    add_index :system_federation_service_offerings, :status
    add_index :system_federation_service_offerings, :protocol
  end
end
