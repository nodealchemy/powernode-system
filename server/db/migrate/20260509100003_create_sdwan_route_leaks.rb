# frozen_string_literal: true

# Sdwan::RouteLeak — explicit cross-VRF prefix import. Models the only
# supported cross-network communication path (no implicit leakage). The
# compiler emits a per-VRF `import vrf <source>` clause plus a
# prefix-list-backed route-map filter (one direction per row, with
# `bidirectional` causing the compiler to also emit the reverse leak).
#
# Phase N1a of the in-house encrypted mesh overlay roadmap.
class CreateSdwanRouteLeaks < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_route_leaks, id: :uuid do |t|
      t.references :source_network, null: false, type: :uuid,
                   foreign_key: { to_table: :sdwan_networks }
      t.references :dest_network, null: false, type: :uuid,
                   foreign_key: { to_table: :sdwan_networks }
      t.references :account, null: false, type: :uuid, foreign_key: true

      # JSONB list — [{cidr: "fd00:abcd::/48", action: "permit"|"deny"}, ...].
      # Compiler renders into a prefix-list referenced by the leak
      # route-map; deny entries land first (FRR evaluates in order).
      t.jsonb :prefix_filter, null: false, default: -> { "'[]'::jsonb" }

      t.string :direction, null: false, default: "one_way"

      # Audit trail surface: "federation:<peer_id>" when synthesized by
      # the federation negotiator, "operator:<user_id>" when an operator
      # filed it from the UI, "ai:<agent_id>" when policy synthesizer
      # proposed it.
      t.string :reason

      t.references :approved_by, type: :uuid, foreign_key: { to_table: :users }, null: true

      t.string :state, null: false, default: "proposed"

      t.datetime :activated_at
      t.datetime :revoked_at

      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    # Same direction can have at most one leak between a given pair.
    # Bidirectional leaks expand into two compiled clauses but still
    # occupy a single row (direction column carries the intent).
    add_index :sdwan_route_leaks,
              %i[source_network_id dest_network_id direction],
              unique: true,
              name: "index_sdwan_route_leaks_on_pair_and_direction"

    add_index :sdwan_route_leaks, :state

    add_check_constraint :sdwan_route_leaks,
                         "direction IN ('one_way','bidirectional')",
                         name: "sdwan_route_leaks_direction_check"

    add_check_constraint :sdwan_route_leaks,
                         "state IN ('proposed','active','revoked')",
                         name: "sdwan_route_leaks_state_check"

    add_check_constraint :sdwan_route_leaks,
                         "source_network_id <> dest_network_id",
                         name: "sdwan_route_leaks_distinct_networks"
  end
end
