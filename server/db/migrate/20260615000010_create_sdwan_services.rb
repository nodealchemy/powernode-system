# frozen_string_literal: true

# Sdwan::Service — the first-class "publishable service" core: a service's
# identity + its overlay backend (a VIP, preferred + failover-aware, or a static
# host:port) + an optional LOCAL-exposure facet (reachable at /svc/<slug> on the
# account's own host through the bundled Traefik, gated by ForwardAuth).
#
# A service can additionally be offered to federated peers via
# System::Federation::ServiceOffering (its federated facet, belongs_to :service).
# Backend addressing is VIP-backed so the offering-side Traefik dials the service
# over the overlay — no loopback hop required.
class CreateSdwanServices < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_services, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true

      t.string :slug, null: false, limit: 64
      t.string :name, null: false, limit: 255
      t.string :protocol, null: false, default: "https"

      # Overlay backend: a VIP (preferred — follows holder across failovers) or
      # a static host. One of the two must be present (check constraint below).
      t.references :backend_vip, type: :uuid, foreign_key: { to_table: :sdwan_virtual_ips }
      t.string  :backend_host
      t.integer :backend_port, null: false

      t.string :status, null: false, default: "active"

      # --- Local-exposure facet: /svc/<slug> on the account's own host ---
      t.boolean :local_enabled, null: false, default: false
      t.string  :local_auth_mode, null: false, default: "authenticated"
      t.string  :local_required_permission
      t.string  :local_required_group
      t.boolean :local_strip_prefix, null: false, default: true
      # The host cert whose CN the /svc/<slug> router mounts under
      # (default = the account's primary cert, resolved at config-write time).
      t.references :local_certificate, type: :uuid,
                   foreign_key: { to_table: :system_acme_certificates }

      t.jsonb :metadata, default: {}, null: false
      t.timestamps
    end

    # One published service per slug per account (the slug is the /svc/<slug>
    # path segment, so it must be unique within the account).
    add_index :sdwan_services, %i[account_id slug], unique: true,
              name: "idx_sdwan_services_unique_slug"

    add_check_constraint :sdwan_services,
                         "protocol IN ('https', 'http', 'tcp', 'tls')",
                         name: "sdwan_services_protocol_enum"
    add_check_constraint :sdwan_services,
                         "status IN ('active', 'disabled')",
                         name: "sdwan_services_status_enum"
    add_check_constraint :sdwan_services,
                         "local_auth_mode IN ('public', 'authenticated', 'scoped')",
                         name: "sdwan_services_local_auth_mode_enum"
    add_check_constraint :sdwan_services,
                         "backend_port BETWEEN 1 AND 65535",
                         name: "sdwan_services_backend_port_range"
    # Either a VIP or a static host must back the service.
    add_check_constraint :sdwan_services,
                         "backend_vip_id IS NOT NULL OR backend_host IS NOT NULL",
                         name: "sdwan_services_backend_present"
  end
end
