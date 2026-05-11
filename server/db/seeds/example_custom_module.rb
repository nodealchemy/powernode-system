# frozen_string_literal: true

# Companion seed for docs/examples/07-build-custom-module.md.
#
# Demonstrates the platform-side ingestion of a new custom module — bypasses
# the actual Gitea CI + Cosign signing pipeline (which requires external infra)
# but creates the resulting NodeModule + NodeModuleVersion rows directly so
# operators can see what the OCI ingest service would produce.
#
# Idempotent.
#
# Run via:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/example_custom_module.rb')"

puts "\n  Seeding example_custom_module (Example 07)..."

account = ::Account.first
return puts("  ⚠️  No account — skipping") unless account
user = account.users.find_by(email: "admin@powernode.org") || account.users.first
return puts("  ⚠️  No admin user — skipping") unless user

# ── Synthetic manifest YAML (would be authored in a Gitea repo) ──────────

manifest = {
  schema_version: 1,
  identity: {
    name: "my-redis",
    category: "userland",
    variety: "subscription",
    description: "Redis 7.4 in-memory data store",
    cosign_identity_regexp: '^https://git\.ipnode\.org/.*/modules/my-redis-module@.*$',
    cosign_issuer_regexp: '^https://gitea\.ipnode\.org$'
  },
  package_spec: %w[redis-server redis-tools],
  file_spec: {
    include: ["/etc/redis/**", "/var/lib/redis/.gitkeep"],
    exclude: ["/etc/redis/sentinel.conf"]
  },
  protected_spec: ["/etc/redis/redis.conf"],
  dependency_spec: [
    { name: "system-base" },
    { name: "security-hardening" }
  ]
}

# ── Ensure category exists ────────────────────────────────────────────────

category = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "Userland") do |c|
  c.position = 90
end

# ── Create / update the NodeModule ───────────────────────────────────────

mod = ::System::NodeModule.find_or_initialize_by(account: account, name: manifest[:identity][:name])
mod.assign_attributes(
  category: category,
  variety: manifest[:identity][:variety],
  description: manifest[:identity][:description],
  # Schema stores the manifest as YAML text in `manifest_yaml`. (Earlier
  # iterations of this seed referenced a non-existent `manifest:` JSONB
  # attribute and a `manifest_type:` column; neither exists on the
  # current `system_node_modules` table.)
  manifest_yaml: manifest.deep_stringify_keys.to_yaml
)
mod.save!
puts "  ✅ NodeModule: #{mod.name} (#{mod.previously_new_record? ? 'created' : 'updated'})"

# ── Create v1 in `built` ──────────────────────────────────────────────────

v = ::System::NodeModuleVersion.find_or_initialize_by(node_module: mod, version_number: 1)
v.assign_attributes(
  promotion_state: "built",
  changelog: "my-redis 0.1.0 — initial release"
)
v.save!
puts "  ✅ NodeModuleVersion: v1 (promotion_state=built, 0.1.0)"

# ── Promote: built → staging → blessed → live ────────────────────────────

%w[staging blessed live].each do |target_state|
  next if v.promotion_state == target_state || v.promotion_state == "live"

  v.update!(promotion_state: target_state)
  puts "  ✅ Promoted v1 → #{target_state}"
end

# ── Show current dependency resolution ────────────────────────────────────
# DependencyResolutionService takes (available_modules, options) positionally
# — the original seed passed `account:` as a kwarg which became the
# `available_modules` argument and blew up on `.map(&:id)` inside
# initialize. Resolve over this account's full module set instead.

available_modules = account.system_node_modules.to_a
resolver = ::System::DependencyResolutionService.new(available_modules)
result = resolver.resolve([mod]) rescue nil

if result&.success?
  names = result.modules.map(&:name).join(' → ')
  puts "  ✅ Dependency resolution: #{names}"
elsif result
  puts "  ℹ️  Dependency resolver returned with errors: #{result.errors.join('; ')}"
else
  puts "  ℹ️  Dependency resolver raised — system-base + security-hardening modules may not be seeded yet"
end

puts "  ℹ️  In production, the full flow is:"
puts "       1. Operator pushes manifest.yaml + Containerfile + rootfs/ to a Gitea repo"
puts "       2. .gitea/workflows/build.yaml runs the two-stage CI"
puts "       3. Cosign signs; oras pushes to registry.example.com/<account>/modules/<name>"
puts "       4. ModuleOciIngestService polls + ingests; creates NodeModule + Version rows"
puts "       5. Operator promotes via system_promote_module_version"
puts "  Done. See docs/examples/07-build-custom-module.md and runbooks/module-authoring.md."
