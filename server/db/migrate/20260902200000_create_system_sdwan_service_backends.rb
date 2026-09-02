# frozen_string_literal: true

# IMP-8340af6aede5 (APO-3c) — a load-balanced backend SET for a published service.
#
# Sdwan::Service carried exactly one backend (backend_vip_id OR backend_host,
# plus backend_port) and Sdwan::ServiceExposureWriter emitted exactly one
# Traefik `loadBalancer.servers` entry from it. Scaling a project out
# (System::Ai::Skills::ScaleProjectExecutor add_replicas) therefore produced
# replicas that received no traffic at all: the exposed service still pointed
# at the one original address.
#
# This table is the fan-out. It is PURELY ADDITIVE and opt-in:
#
#   * every existing service keeps zero rows here and keeps rendering from the
#     legacy columns, byte-identically (Sdwan::Service#load_balanced_backends
#     falls back to them whenever the active set is empty);
#   * the legacy columns stay authoritative for the model's own
#     backend_present check constraint and for the IPFIX health correlation
#     (System::Fleet::Sensors::SdwanServiceHealthSensor), so nothing that
#     reads them has to learn about the set in this increment.
#
# Reversible: drop_table via `change`.
class CreateSystemSdwanServiceBackends < ActiveRecord::Migration[8.0]
  def change
    create_table :system_sdwan_service_backends, id: :uuid, default: -> { "uuidv7()" } do |t|
      # Denormalised from the parent service so an account-scoped sweep never
      # has to join; Sdwan::ServiceBackend validates the two agree.
      t.uuid :account_id, null: false
      t.uuid :sdwan_service_id, null: false

      # Same XOR-ish backend shape as system_sdwan_services: a VIP reference
      # (overlay-addressed, preferred) or a literal host, plus a port. Kept
      # per-row rather than inherited from the service because a scaled set can
      # legitimately mix ports (a replica behind a different host port).
      t.uuid :backend_vip_id
      t.string :backend_host
      t.integer :backend_port, null: false

      # Weighted round robin across the servers load balancer. Uniform weights
      # are plain round robin and the writer omits the key entirely then, so a
      # deployment that never tunes weights emits config no older Traefik could
      # choke on.
      t.integer :weight, null: false, default: 1

      # active | draining. "draining" keeps the row (and its history) while
      # taking it out of the emitted server list — scale-in and rolling
      # replacement need to stop new traffic before the instance goes away.
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :system_sdwan_service_backends, :account_id
    add_index :system_sdwan_service_backends, :backend_vip_id
    # The writer's hot path: every active backend of one service, in emission
    # order (created_at, id — see Sdwan::Service#load_balanced_backends).
    add_index :system_sdwan_service_backends, %i[sdwan_service_id status created_at],
              name: "idx_sdwan_service_backends_on_service_status_created"
    # Two members dialling the same address:port are one backend counted twice,
    # which silently doubles its share of a round-robin set. A plain unique
    # index over (sdwan_service_id, backend_port, backend_vip_id, backend_host)
    # would NOT catch it — Postgres treats NULLs in a unique index as distinct,
    # and exactly one of the two address columns is always NULL. COALESCEing
    # them into the single address the model actually dials makes the key total.
    # Sdwan::ServiceBackend#backend_unique_within_service still runs, for the
    # cross-form case this index cannot see (a VIP whose resolved host equals
    # another row's literal backend_host) and to turn a same-form clash into a
    # validation error rather than a RecordNotUnique.
    add_index :system_sdwan_service_backends,
              "sdwan_service_id, backend_port, COALESCE(backend_vip_id::text, backend_host)",
              unique: true,
              name: "idx_sdwan_service_backends_unique_address"

    add_check_constraint :system_sdwan_service_backends,
                         "backend_port >= 1 AND backend_port <= 65535",
                         name: "sdwan_service_backends_port_range"
    add_check_constraint :system_sdwan_service_backends,
                         "backend_vip_id IS NOT NULL OR backend_host IS NOT NULL",
                         name: "sdwan_service_backends_backend_present"
    add_check_constraint :system_sdwan_service_backends,
                         "weight >= 1 AND weight <= 1000",
                         name: "sdwan_service_backends_weight_range"
    add_check_constraint :system_sdwan_service_backends,
                         "status IN ('active', 'draining')",
                         name: "sdwan_service_backends_status_enum"

    add_foreign_key :system_sdwan_service_backends, :accounts
    # Cascade: a member has no meaning without its service, and the model's
    # dependent: :destroy only covers deletes that go through Rails.
    add_foreign_key :system_sdwan_service_backends, :system_sdwan_services,
                    column: :sdwan_service_id, on_delete: :cascade
    # Default (restrict) rather than nullify, unlike a plain optional FK: a
    # nullified backend_vip_id would leave a row violating the
    # sdwan_service_backends_backend_present check whenever backend_host is
    # also NULL. Matches system_sdwan_services.backend_vip_id.
    add_foreign_key :system_sdwan_service_backends, :system_sdwan_virtual_ips,
                    column: :backend_vip_id
  end
end
