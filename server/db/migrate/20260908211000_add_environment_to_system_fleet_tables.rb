# frozen_string_literal: true

# Environment campaign, increment 1 — every fleet row learns which plane it is
# in.
#
# Core owns the noun (ai_environments, created in the core band); the fleet
# tables that CARRY it are this extension's, so the cross-owner foreign keys
# live here, in the later band, and core still builds standalone.
#
# Templates are the anchor: a node inherits from its template, an instance
# from its node, a pool from its template. Peers carry one only when they are
# a child plane (a platform peer we merely federate with has none).
#
# BACKFILL, in the same migration so no row is ever NULL where the model now
# requires a value: every template lands in its account's default environment
# and the fleet inherits from it. Which template is the control plane, or
# production, is an operator decision made afterwards through the update
# verbs — not something a migration can know.
class AddEnvironmentToSystemFleetTables < ActiveRecord::Migration[8.0]
  TABLES = %i[system_node_templates system_nodes system_node_instances system_instance_pools system_federation_peers].freeze

  def up
    TABLES.each do |table|
      add_reference table, :environment, type: :uuid, foreign_key: { to_table: :ai_environments }
    end

    # Every template lands in its account's DEFAULT environment. Placement of
    # the control plane (ops) and of a production plane is an OPERATOR step
    # through system_update_template / system_update_node, never a name rule:
    # a rule keyed on template names would encode one deployment's naming in a
    # tracked file and silently misplace any deployment named otherwise.
    execute <<~SQL.squish
      UPDATE system_node_templates t
      SET environment_id = d.id
      FROM ai_environments d
      WHERE d.account_id = t.account_id AND d.is_default AND t.environment_id IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE system_nodes n SET environment_id = t.environment_id
      FROM system_node_templates t
      WHERE t.id = n.node_template_id AND n.environment_id IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE system_node_instances i SET environment_id = n.environment_id
      FROM system_nodes n
      WHERE n.id = i.node_id AND i.environment_id IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE system_instance_pools p SET environment_id = t.environment_id
      FROM system_node_templates t
      WHERE t.id = p.node_template_id AND p.environment_id IS NULL
    SQL

    # The models now REQUIRE the value on every save. A row left NULL here would
    # not fail now; it would fail on its next unrelated write, which is the
    # worst place. Refuse to finish instead. (Peers are optional by design.)
    remaining = %w[system_node_templates system_nodes system_node_instances system_instance_pools].to_h do |table|
      [ table, select_value("SELECT count(*) FROM #{table} WHERE environment_id IS NULL").to_i ]
    end
    leftover = remaining.select { |_, n| n.positive? }
    raise ActiveRecord::MigrationError, "environment backfill left NULL rows: #{leftover.inspect} — " \
                                        "an account has no default Ai::Environment; run the core seed migration first" if leftover.any?
  end

  def down
    TABLES.each do |table|
      remove_reference table, :environment, type: :uuid, foreign_key: { to_table: :ai_environments }
    end
  end
end
