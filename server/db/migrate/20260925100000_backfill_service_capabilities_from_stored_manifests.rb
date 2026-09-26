# frozen_string_literal: true

# IMP-caef5c00d63f — re-derive pre-stage-1 service capabilities from the
# manifests the platform already stores (system_node_modules.manifest_yaml).
#
# 20260920182328 made system_module_services.capabilities nullable but shipped
# no backfill, so a row written before the presence-preserving import holds []
# even where its manifest OMITS the key ("inherit the module ceiling"). This
# migration applies exact re-import semantics to every row NOT yet flagged
# capabilities_presence_recorded:
#
#   key absent or null in the stored manifest -> NULL, flagged
#   non-empty list                           -> copied, flagged
#   declared []                              -> [], NOT flagged
#   unparseable manifest, service not found,
#   or a value that is not a list of strings -> untouched, NOT flagged
#
# A declared [] is left unflagged on purpose: the stored manifests are often
# the pre-sweep versions, whose [] is boilerplate (postgres, redis, vault,
# hub-worker sidekiq/worker-web). Flagging it would give the module the
# service_capabilities_presence marker and the agent would zero those units.
# Only a real import of the swept manifest (ManifestImportService) may flag a
# declared [].
#
# Rows already flagged were written by a real import and are never touched, so
# the migration is idempotent and cannot undo an import. Self-contained (raw
# SQL, inline parsing) so a later change to app code cannot change what it does;
# System::ServiceCapabilitiesProvenance.classify is the same rule for the
# read-only drift check.
class BackfillServiceCapabilitiesFromStoredManifests < ActiveRecord::Migration[8.1]
  def up
    rows = select_all(<<~SQL.squish).to_a
      SELECT s.id, s.name, m.manifest_yaml
        FROM system_module_services s
        JOIN system_node_modules m ON m.id = s.node_module_id
       WHERE s.capabilities_presence_recorded = FALSE
    SQL

    parsed_manifests = {}
    rows.each do |row|
      yaml = row["manifest_yaml"]
      manifest = parsed_manifests.fetch(yaml) { parsed_manifests[yaml] = parse(yaml) }
      next if manifest.nil?

      entry = Array(manifest["services"]).find { |s| s.is_a?(Hash) && s["name"] == row["name"] }
      next if entry.nil?

      caps = entry["capabilities"]
      if caps.nil?
        store_capabilities(row["id"], nil, flagged: true)
      elsif caps.is_a?(Array) && caps.all?(String)
        caps.empty? ? store_capabilities(row["id"], [], flagged: false) : store_capabilities(row["id"], caps, flagged: true)
      end
    end
  end

  # Lossy by design, as 20260920182328's own `down` is: every NULL becomes []
  # ("grant nothing") and every flag clears, including flags a real import set
  # after this ran. Safe in the revoking direction; run it only in the window
  # right after landing.
  def down
    execute(<<~SQL.squish)
      UPDATE system_module_services
         SET capabilities = '[]'::jsonb
       WHERE capabilities IS NULL
    SQL
    execute("UPDATE system_module_services SET capabilities_presence_recorded = FALSE")
  end

  private

  def parse(yaml)
    return nil if yaml.nil? || yaml.strip.empty?

    parsed = YAML.safe_load(yaml, permitted_classes: [ Symbol, Date, Time ], aliases: true)
    parsed.is_a?(Hash) ? parsed : nil
  rescue Psych::Exception
    nil
  end

  def store_capabilities(id, capabilities, flagged:)
    caps_sql = capabilities.nil? ? "NULL" : "#{connection.quote(capabilities.to_json)}::jsonb"
    execute(<<~SQL.squish)
      UPDATE system_module_services
         SET capabilities = #{caps_sql},
             capabilities_presence_recorded = #{flagged ? 'TRUE' : 'FALSE'}
       WHERE id = #{connection.quote(id)}
    SQL
  end
end
