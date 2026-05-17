# frozen_string_literal: true

# P2.1 — system_platform_deployments: sparse lookup table mapping a
# platform component (api, worker, frontend, etc.) to its NodeTemplate +
# allocated SDWAN VirtualIP. Read once at service startup by each replica
# so the Sidekiq worker on Node B knows what VIP to call for the API
# on Node A. Invalidated on `platform.deployment.*` FleetEvents.
#
# Plan reference: Decentralized Federation §G, P2.1.
class CreateSystemPlatformDeployments < ActiveRecord::Migration[8.0]
  def change
    create_table :system_platform_deployments, id: :uuid do |t|
      t.references :account,
        type: :uuid, null: false,
        foreign_key: { to_table: :accounts, on_delete: :cascade },
        index: false  # superseded by compound below
      t.references :node_template,
        type: :uuid, null: false,
        foreign_key: { to_table: :system_node_templates, on_delete: :restrict }

      # VIP is optional: hub-frontend on a single host can serve directly
      # without VIP allocation; multi-host deployments allocate one.
      t.references :virtual_ip,
        type: :uuid, null: true,
        foreign_key: { to_table: :sdwan_virtual_ips, on_delete: :nullify }

      t.string :name, null: false, limit: 100
      t.string :service_role, null: false, limit: 32

      # Optional public DNS hostname for first-boot bootstrap (before
      # SDWAN mesh is up). Set to a public-resolvable name like
      # `hub.example.com` and federation peers can dial it before they
      # join the overlay.
      t.string :public_dns_hostname, limit: 256

      # Set when this deployment hosts an on-prem satellite for a specific
      # extension (per-extension satellite model per D2). nil for the
      # mainline hub deployments.
      t.string :satellite_extension_slug, limit: 64

      t.integer :target_replicas, null: false, default: 1
      t.jsonb   :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :system_platform_deployments, %i[account_id name],
      unique: true, name: "idx_platform_deployments_account_name_unique"
    add_index :system_platform_deployments, %i[account_id service_role],
      name: "idx_platform_deployments_account_role"
    add_index :system_platform_deployments, :satellite_extension_slug,
      where: "satellite_extension_slug IS NOT NULL"

    add_check_constraint :system_platform_deployments,
      "target_replicas >= 0",
      name: "platform_deployments_target_replicas_non_negative"
  end
end
