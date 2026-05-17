# frozen_string_literal: true

# P1.1 — system_module_services: first-class service-definition rows attached
# to NodeModule. Modules ship `manifest_yaml` in their OCI artifact as the
# authoring source; Module::OciIngestService parses `manifest_yaml#services`
# into rows on ingest (P1.6). The Go agent on-node continues to read
# manifest_yaml directly; the platform queries the structured rows for the
# Platform Infrastructure dashboard, scaling composer, and service discovery.
class CreateSystemModuleServices < ActiveRecord::Migration[8.0]
  def change
    create_table :system_module_services, id: :uuid do |t|
      t.references :account,
        type: :uuid, null: false,
        foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :node_module,
        type: :uuid, null: false,
        foreign_key: { to_table: :system_node_modules, on_delete: :cascade },
        index: false  # superseded by compound unique below

      # Service identity (unique within module)
      t.string :name, null: false, limit: 100

      # Process lifecycle
      t.text   :start_command,    null: false
      t.text   :stop_command
      t.string :restart_policy,   null: false, default: "always", limit: 32
      t.string :run_as_user,      limit: 64
      t.string :working_directory, limit: 512

      # Environment & runtime
      t.jsonb :env,           null: false, default: {}
      t.jsonb :exposed_ports, null: false, default: []
      t.jsonb :capabilities,  null: false, default: []
      t.jsonb :metadata,      null: false, default: {}

      # Health check
      t.string  :health_endpoint, limit: 256
      t.string  :health_method,   null: false, default: "GET", limit: 8
      t.integer :health_interval_seconds,      null: false, default: 30
      t.integer :health_timeout_seconds,       null: false, default: 5
      t.integer :health_initial_delay_seconds, null: false, default: 10

      t.timestamps
    end

    add_index :system_module_services, %i[node_module_id name], unique: true
    add_index :system_module_services, :restart_policy
  end
end
