# frozen_string_literal: true

# System extension — Powernode Platform templates seed.
#
# Creates the 5 NodeTemplates that compose the Powernode platform's own
# deploy topologies. Each template is a flat collection of platform modules
# ordered by ascending priority (lower priority = lower in the overlay stack).
#
#   - powernode-hub                Single-node complete platform (all 8 modules)
#   - powernode-hub-api            Horizontally-scaled API tier (no PG/Redis — external)
#   - powernode-hub-worker         Worker pool (no reverse-proxy — no public TLS endpoint)
#   - powernode-hub-frontend       Edge serving tier (proxy + static assets only)
#   - powernode-hub-cluster-member HA cluster member (PG streaming replica, no own postgres)
#
# Plan reference: Decentralized Federation §B, P1.9.
# Plan file: ~/.claude/plans/the-powrnode-platform-consists-peppy-salamander.md
#
# Depends on:
#   - powernode_platform_categories.rb (P1.7)
#   - powernode_platform_modules.rb    (P1.8)
#   - node_module_catalog.rb           — for ubuntu-24.04-lts NodePlatform
#
# Idempotent: find_or_initialize_by on (account, name); TemplateModule rows
# rebuilt on every run with stale removal (matches AccountBootstrapService
# pattern in node_module_catalog.rb).
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/powernode_platform_templates.rb')"

# Module lists per amended plan §B. Order = ascending priority in the
# overlay stack. Reverse-proxy intentionally first (lowest priority, bottom
# of stack — base infrastructure). Extension modules last (highest priority,
# top of stack — application overrides).
POWERNODE_PLATFORM_TEMPLATE_SPECS = {
  "powernode-hub" => {
    description: "Single-node complete platform (all services on one host). Canonical deploy unit; default for fresh installs and `local_qemu` smoke tests.",
    modules: %w[
      powernode-reverse-proxy
      powernode-base-ruby
      powernode-postgres
      powernode-redis
      powernode-hub-backend
      powernode-hub-worker
      powernode-hub-frontend
      powernode-extension-system
    ]
  },
  "powernode-hub-api" => {
    description: "Horizontally-scaled API tier. PG + Redis external (set DATABASE_URL / REDIS_URL via template config). Suitable for multi-replica behind an external LB.",
    modules: %w[
      powernode-reverse-proxy
      powernode-base-ruby
      powernode-hub-backend
      powernode-extension-system
    ]
  },
  "powernode-hub-worker" => {
    description: "Worker pool — Sidekiq only. Calls hub-backend via HTTP API. No reverse-proxy (no public TLS endpoint on workers).",
    modules: %w[
      powernode-base-ruby
      powernode-hub-backend
      powernode-hub-worker
    ]
  },
  "powernode-hub-frontend" => {
    description: "Edge serving tier — static frontend assets served by Traefik. Reverse-proxies API + WebSocket calls to a hub-api VIP.",
    modules: %w[
      powernode-reverse-proxy
      powernode-hub-frontend
    ]
  },
  "powernode-hub-cluster-member" => {
    description: "HA cluster member. Runs hub-backend + hub-worker locally, but uses pg-replica streaming from the parent's primary. Selected via cluster_member spawn mode.",
    modules: %w[
      powernode-reverse-proxy
      powernode-base-ruby
      powernode-hub-backend
      powernode-hub-worker
      powernode-pg-replica
      powernode-extension-system
    ]
  }
}.freeze

puts "\n  Seeding Powernode Platform templates (5 templates)..."

created = 0
updated = 0
errors  = []

::Account.find_each do |account|
  platform = ::System::NodePlatform.find_by(account: account, name: "ubuntu-24.04-lts")
  unless platform
    errors << "Account #{account.id}: NodePlatform 'ubuntu-24.04-lts' missing — run node_module_catalog.rb first"
    next
  end

  # Index this account's platform modules by name for fast lookup
  module_index = ::System::NodeModule.where(
    account: account,
    name: POWERNODE_PLATFORM_TEMPLATE_SPECS.values.flat_map { |s| s[:modules] }.uniq
  ).index_by(&:name)

  POWERNODE_PLATFORM_TEMPLATE_SPECS.each do |template_name, spec|
    missing = spec[:modules].reject { |m| module_index[m] }
    if missing.any?
      errors << "Account #{account.id} / #{template_name}: missing modules #{missing.inspect} — run powernode_platform_modules.rb first"
      next
    end

    template = ::System::NodeTemplate.find_or_initialize_by(account: account, name: template_name)
    was_new = template.new_record?

    template.node_platform = platform
    template.enabled = true
    template.public = false
    template.config = (template.config || {}).merge("description" => spec[:description])
    template.save!

    # Upsert TemplateModule rows in priority order; remove stale ones.
    desired_module_ids = []
    spec[:modules].each_with_index do |module_name, idx|
      mod = module_index[module_name]
      tm = ::System::TemplateModule.find_or_initialize_by(node_template: template, node_module: mod)
      tm.priority = (idx + 1) * 10
      tm.save!
      desired_module_ids << mod.id
    end

    stale = template.template_modules.where.not(node_module_id: desired_module_ids)
    stale_count = stale.count
    stale.destroy_all if stale_count.positive?

    if was_new
      created += 1
      suffix = stale_count.positive? ? " (#{stale_count} stale removed)" : ""
      puts "    ✓ Account #{account.id}: created #{template_name} → [#{spec[:modules].join(', ')}]#{suffix}"
    else
      updated += 1
    end
  end
end

puts "  Powernode Platform templates: #{created} created, #{updated} updated"
if errors.any?
  puts "  ⚠ Errors encountered:"
  errors.each { |e| puts "    - #{e}" }
end
