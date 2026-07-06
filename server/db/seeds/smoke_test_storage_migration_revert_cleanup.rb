# frozen_string_literal: true

# Increment 9 (campaign 019f3458) — revert_binding! (R) / cleanup (C)
# scratch-instance smoke test.
#
# Exercises the fail → revert → cleanup lifecycle end to end against
# SCRATCH model state, following smoke_test_powernode_hub.rb's
# recorder-mode conventions (idempotent find_or_create_by! fixtures,
# a small pass/fail result recorder, non-zero exit on failure). This
# is model + node_api layer only — it does NOT start a real agent, VM,
# or NFS mount; the "agent reports back" steps are simulated by
# calling the exact model methods node_api's revert_complete /
# cleanup_complete actions call (#revert_completed! / #cleanup_completed!),
# which is the same code path a real agent's POST would hit.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_storage_migration_revert_cleanup.rb')"
#
# Exits non-zero on any check failure so CI can gate on it.
#
# Plan reference: increment 9, campaign 019f3458.

class StorageMigrationSmokeResult
  attr_reader :passed, :failed
  def initialize
    @passed = []
    @failed = []
  end

  def check(label)
    yield
    @passed << label
    puts "    ✓ #{label}"
  rescue StandardError => e
    @failed << [ label, e.message ]
    puts "    ✗ #{label} — #{e.message}"
  end

  def report!
    total = @passed.size + @failed.size
    puts ""
    puts "  ======================================="
    puts "  Storage migration revert/cleanup smoke: #{@passed.size}/#{total} passed"
    puts "  ======================================="
    @failed.each { |label, msg| puts "    FAIL: #{label} — #{msg}" }
    exit(@failed.empty? ? 0 : 1)
  end
end

puts "\n  Increment 9 — revert_binding! / cleanup smoke (scratch state, never live)"
puts "  ======================================================================="

account = ::Account.first or abort("  ❌ No account")

results = StorageMigrationSmokeResult.new

# ── Scratch fixtures (idempotent) ──────────────────────────────────────

architecture = ::System::NodeArchitecture.find_or_create_by!(name: "smoke_storage_revert_arch") do |a|
  a.family = "other"
  a.is_canonical = false
  a.enabled = true
  a.public = false
end

platform = ::System::NodePlatform.find_or_create_by!(account: account, name: "smoke-storage-revert-platform") do |p|
  p.node_architecture = architecture
  p.enabled = true
  p.public = false
  p.build_script = "#!/bin/bash\necho build"
  p.init_script  = "#!/bin/bash\necho init"
  p.sync_script  = "#!/bin/bash\necho sync"
end

template = ::System::NodeTemplate.find_or_create_by!(account: account, name: "smoke-storage-revert-template") do |t|
  t.node_platform = platform
  t.enabled = true
  t.public = false
  t.admin_user = "admin"
  t.config = {}
end

node = ::System::Node.find_or_create_by!(account: account, name: "smoke-storage-revert-node") do |n|
  n.node_template = template
  n.enabled = true
  n.config = {}
  n.allocate_public_ip = false
  n.runtime_amount = 0
  n.tmpfs_store = false
end

provider = ::System::Provider.find_or_create_by!(account: account, name: "smoke-storage-revert-provider") do |p|
  p.provider_type = "local_qemu"
  p.enabled = true
  p.config = {}
  p.capabilities = {}
end

region = ::System::ProviderRegion.find_or_create_by!(account: account, provider: provider, region_code: "smoke-local") do |r|
  r.name = "Smoke Local"
  r.enabled = true
  r.capabilities = {}
end

instance_type = ::System::ProviderInstanceType.find_or_create_by!(
  account: account, provider: provider, instance_type_code: "smoke.small"
) do |it|
  it.name = "smoke.small"
  it.vcpus = 1
  it.memory_mb = 512
  it.storage_gb = 8
  it.enabled = true
  it.specs = {}
end

instance = ::System::NodeInstance.find_or_create_by!(
  account: account, node: node, name: "smoke-storage-revert-instance-1"
) do |i|
  i.provider_instance_type = instance_type
  i.provider_region = region
  i.status = "running"
  i.config = { "storage_volume" => { "mount_point" => "/var/lib/postgresql", "volume_id" => nil } }
end

nfs_type = ::System::ProviderVolumeType.find_or_create_by!(
  account: account, provider: provider, name: "smoke-nfs-pool"
) do |t|
  t.volume_type = "nfs"
  t.min_size_gb = 1
  t.max_size_gb = 1000
  t.enabled = true
end

source_volume = ::System::ProviderVolume.find_or_create_by!(
  account: account, provider_region: region, volume_type: nfs_type, name: "smoke-vol-source"
) do |v|
  v.size_gb = 50
  v.status = "available"
  v.config = { "nfs" => { "server" => "nas1.smoke.internal", "export_path" => "/v1/powernode" } }
end

target_volume = ::System::ProviderVolume.find_or_create_by!(
  account: account, provider_region: region, volume_type: nfs_type, name: "smoke-vol-target"
) do |v|
  v.size_gb = 50
  v.status = "available"
  v.config = { "nfs" => { "server" => "nas2.smoke.internal", "export_path" => "/v2/powernode" } }
end

puts "  Fixtures ready: instance=#{instance.id[0, 8]} source_volume=#{source_volume.id[0, 8]} target_volume=#{target_volume.id[0, 8]}"
puts ""

# ── Stage 1: plan + fail from cutover (cutover_diverged) ───────────────

migration = nil
results.check("migrate_storage_component plans a migration in `approved`") do
  migration = ::System::StorageMigration.create!(
    account: account, node_instance: instance, source_volume: source_volume, target_volume: target_volume,
    role: "postgres", status: "approved",
    source_subpath: "deployments/smoke/postgres", target_subpath: "deployments/smoke/postgres",
    snapshot_subpath: "migrations/smoke/deployments/smoke/postgres",
    plan: { "agent_contract" => { "v" => 1, "steps" => %w[mount_target snapshot rsync verify cutover unmount_source] } }
  )
  raise "expected status=approved" unless migration.status == "approved"
end

results.check("walking preparing→syncing→verifying→cutover advances the migration") do
  %w[preparing syncing verifying cutover].each { |status| migration.transition_to!(status, message: "smoke: #{status}") }
  raise "expected status=cutover" unless migration.reload.status == "cutover"
end

results.check("mark_failed! from cutover sets metadata.cutover_diverged") do
  migration.mark_failed!(reason: "smoke: agent crashed mid-remount")
  migration.reload
  raise "expected status=failed" unless migration.status == "failed"
  raise "expected metadata.cutover_diverged=true" unless migration.metadata["cutover_diverged"] == true
end

# ── Stage 2: revert ─────────────────────────────────────────────────────

results.check("can_revert_binding? is true from failed") do
  raise "expected revertible" unless migration.can_revert_binding?
end

results.check("revert_binding! records requested intent + audit entry") do
  migration.revert_binding!(reason: "smoke: diverged mount", user: nil)
  migration.reload
  raise "expected revert_status=requested" unless migration.metadata["revert_status"] == "requested"
  raise "expected an audit entry naming the revert" unless migration.audit_log.last["message"].to_s.include?("Revert-to-source requested")
end

results.check("node_api#index would surface this migration (pending_binding_intent)") do
  surfaced = ::System::StorageMigration.where(node_instance_id: instance.id)
                                        .merge(::System::StorageMigration.active.or(::System::StorageMigration.pending_binding_intent))
                                        .exists?(migration.id)
  raise "expected migration to be surfaced despite being terminal" unless surfaced
end

results.check("revert_completed! (simulated agent report) records a per-artifact audit entry") do
  migration.revert_completed!(artifacts: [
    { "path" => "nas1.smoke.internal:/v1/powernode/deployments/smoke/postgres", "mount_point" => "/var/lib/postgresql" }
  ])
  migration.reload
  raise "expected revert_status=completed" unless migration.metadata["revert_status"] == "completed"
  raise "expected reverted_at to be set" unless migration.metadata["reverted_at"].present?
  raise "expected audit entry naming the exact path" unless migration.audit_log.last["message"].to_s.include?("nas1.smoke.internal:/v1/powernode/deployments/smoke/postgres")
end

# ── Stage 3: cleanup (immediate, bypassing the grace window) ──────────

results.check("can_cleanup? is true from failed") do
  raise "expected cleanup-eligible" unless migration.can_cleanup?
end

results.check("request_cleanup! without immediate refuses inside the grace window") do
  raised = false
  begin
    migration.request_cleanup!(reason: "smoke", grace_hours: 24)
  rescue ArgumentError => e
    raised = e.message.include?("grace window") || e.message.include?("Grace window")
  end
  raise "expected ArgumentError citing the grace window" unless raised
end

results.check("request_cleanup!(immediate: true) records requested intent") do
  migration.request_cleanup!(reason: "smoke: triaged, safe to remove", immediate: true)
  migration.reload
  raise "expected cleanup_status=requested" unless migration.metadata["cleanup_status"] == "requested"
  raise "expected cleanup_immediate=true" unless migration.metadata["cleanup_immediate"] == true
end

results.check("cleanup_completed! (simulated agent report) records one audit entry per artifact") do
  before_count = migration.audit_log.size
  migration.cleanup_completed!(artifacts: [
    { "label" => "target_subpath", "path" => "nas2.smoke.internal:/v2/powernode/deployments/smoke/postgres", "already_clean" => false },
    { "label" => "snapshot_subpath", "path" => "nas2.smoke.internal:/v2/powernode/migrations/smoke/deployments/smoke/postgres", "already_clean" => true }
  ])
  migration.reload
  raise "expected cleanup_status=completed" unless migration.metadata["cleanup_status"] == "completed"
  raise "expected cleaned_at to be set" unless migration.metadata["cleaned_at"].present?
  raise "expected 2 new audit entries (one per artifact)" unless migration.audit_log.size == before_count + 2
  raise "expected an 'already clean' entry" unless migration.audit_log.last["message"].to_s.include?("already clean")
end

# ── Absolute invariants ─────────────────────────────────────────────────

results.check("source_volume was never touched (status still available)") do
  raise "source_volume status changed" unless source_volume.reload.status == "available"
end

results.check("target_volume record itself was never deleted (row still exists)") do
  raise "target_volume was deleted" unless ::System::ProviderVolume.exists?(target_volume.id)
end

results.report!
