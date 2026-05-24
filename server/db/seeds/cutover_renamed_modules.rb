# frozen_string_literal: true

# One-off cutover script for the 2026-05-24 module-rename pass.
#
# 9 general-purpose modules were renamed to drop the powernode-* prefix
# (postgres-primary, postgres-replica, redis, reverse-proxy-traefik,
# log-forwarder-vector, node-exporter, storage-tools, runtime-ruby,
# base-os-ubuntu-noble). The on-disk module dirs + manifests were
# renamed via git mv, but existing NodeModule rows on dev/ops/prod
# still reference the old names. This script destroys the stale rows
# + re-runs the modules + templates seeds so the disk-discovery seed
# creates the renamed records.
#
# FK SAFETY: system_node_modules.current_version_id → system_node_module_versions.id
# is a non-cascading FK. When destroying a NodeModule, ActiveRecord's
# dependent_destroy on NMVs hits the FK because the NodeModule still
# holds a current_version_id pointing at one of those NMVs. We
# pre-clear current_version_id before triggering destroy.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/cutover_renamed_modules.rb')"

require "json"

OLD_NAMES = %w[
  powernode-postgres
  powernode-pg-replica
  powernode-redis
  powernode-reverse-proxy
  powernode-log-forwarder
  powernode-node-exporter
  powernode-storage-tools
  powernode-base-ruby
  powernode-system-base-ubuntu-noble
].freeze

NEW_NAMES = %w[
  postgres-primary
  postgres-replica
  redis
  reverse-proxy-traefik
  log-forwarder-vector
  node-exporter
  storage-tools
  runtime-ruby
  base-os-ubuntu-noble
].freeze

puts "\n  Cutover: 9 module renames"
puts "  -------------------------"

# --- Phase 1: enumerate ----------------------------------------------------
pre_counts = OLD_NAMES.each_with_object({}) do |name, h|
  c = ::System::NodeModule.where(name: name).count
  h[name] = c if c.positive?
end

if pre_counts.empty?
  puts "  No old-name NodeModule rows found. Cutover already applied OR fresh install."
else
  puts "  Old-name rows to destroy:"
  pre_counts.each { |name, c| puts "    #{name}: #{c} rows" }
end

# --- Phase 2: pre-clear current_version_id to avoid FK violation ----------
# Find all NMVs of the renamed modules, then null out any NodeModule's
# current_version_id pointing at them. Doing this in bulk via a single
# UPDATE is faster than per-NMV updates.
old_module_ids = ::System::NodeModule.where(name: OLD_NAMES).pluck(:id)
if old_module_ids.any?
  nmv_ids = ::System::NodeModuleVersion.where(node_module_id: old_module_ids).pluck(:id)
  if nmv_ids.any?
    cleared = ::System::NodeModule.where(current_version_id: nmv_ids).update_all(current_version_id: nil)
    puts "  Cleared current_version_id on #{cleared} NodeModule rows (FK pre-emption)"
  end
end

# --- Phase 3: destroy renamed modules (cascade NMVs + assignments) --------
destroyed = 0
::System::NodeModule.where(name: OLD_NAMES).find_each do |mod|
  nmv_count    = ::System::NodeModuleVersion.where(node_module_id: mod.id).count
  assign_count = if defined?(::System::NodeModuleAssignment)
                   ::System::NodeModuleAssignment.where(node_module_id: mod.id).count
                 else
                   0
                 end
  puts "  → destroy #{mod.id} (#{mod.name}) — #{nmv_count} NMVs, #{assign_count} assignments"
  mod.destroy!
  destroyed += 1
end
puts "  Destroyed #{destroyed} NodeModule rows"

# --- Phase 4: re-run seeds ------------------------------------------------
puts "\n  Re-running modules + templates seeds..."
load ::Rails.root.join("../extensions/system/server/db/seeds/powernode_platform_modules.rb")
load ::Rails.root.join("../extensions/system/server/db/seeds/powernode_platform_templates.rb")

# --- Phase 5: verify post state -------------------------------------------
puts "\n  Post-cutover state:"
NEW_NAMES.each do |name|
  count = ::System::NodeModule.where(name: name).count
  symbol = count.positive? ? "✓" : "✗"
  puts "    #{symbol} #{name}  (#{count} accounts)"
end

# Leftover detection
leftover = ::System::NodeModule.where(name: OLD_NAMES).count
if leftover.positive?
  puts "\n  ⚠  #{leftover} old-name rows survived destroy — investigate manually"
else
  puts "\n  ✓  No old-name rows remain. Cutover complete."
end
