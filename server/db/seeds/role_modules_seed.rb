# frozen_string_literal: true

# System extension — Role-module catalog seed (M3 self-serve "Run My Code").
#
# Seeds 5 role-specific NodeModule records that PlanComposer (Slice C) uses
# to compose templates from a brief.use_case lookup, e.g.:
#
#   "discord_bot"  → nodejs-runtime + system-base + security-hardening
#   "django_app"   → python-runtime + postgres-server + system-base
#   "rails_api"    → docker-runtime + postgres-server + redis-cache
#
# Each module is `subscription`-variety (deployable, blob-shippable). When
# Slice B's `DeployAppCodeExecutor` attaches one of these to a NodeInstance
# the agent reconciles the package_spec on first boot and
# `System::CodeDeployService` follows up with the operator's git repo.
#
# Idempotent: keyed on (account, name) with `find_or_initialize_by` then
# `assign_attributes` + `save!` — re-running updates in place rather than
# duplicating rows. Safe to invoke from
# `System::AccountBootstrapService.seed_templates_for(account)` for
# per-account composition.
#
# AI-Driven Provisioning M3 — slice A (Run My Code).
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/role_modules_seed.rb')"

puts "\n  Seeding role modules (M3 self-serve)..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting role-modules seed"
  return
end

# ── Categories ────────────────────────────────────────────────────────────
#
# Three new subscription-variety categories so role modules sort
# predictably under the existing base/security/time/web/firmware buckets
# (positions 10/15/20/30/50).

cat_runtime = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "runtime") do |c|
  c.position    = 60
  c.variety     = "subscription"
  c.enabled     = true
  c.description = "Application runtime modules (Node.js, Python, Docker, ...)"
end
cat_database = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "database") do |c|
  c.position    = 65
  c.variety     = "subscription"
  c.enabled     = true
  c.description = "Database server modules (PostgreSQL, MySQL, ...)"
end
cat_cache = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "cache") do |c|
  c.position    = 67
  c.variety     = "subscription"
  c.enabled     = true
  c.description = "In-memory cache / queue modules (Redis, Memcached, ...)"
end
puts "    ✓ Categories: runtime (#{cat_runtime.position}), database (#{cat_database.position}), cache (#{cat_cache.position})"

# Helper: NodeModule#encode_specs base64-encodes string lines into the
# JSONB array shape, so we pass arrays joined by newlines (mirrors
# AccountBootstrapService pattern).
encode_spec_array = ->(arr) { Array(arr).join("\n") }

# ── Module specs — 5 roles ─────────────────────────────────────────────────
#
# The `manifest` hash lives under `config["manifest"]` — the schema has no
# first-class manifest column (config jsonb is the catch-all). PlanComposer
# reads it via `module.config["manifest"]["runtime"]`, the operator UI
# surfaces it in the "Application requirements" preview, and the agent
# uses it as fallback metadata when the repo doesn't carry a Procfile.
#
# Module-to-module deps live under `config["depends_on"]` rather than the
# rsync-glob `dependency_spec` jsonb (which is the dependant-inheritance
# mechanism — different concern). Slice C resolves these into a TemplateModule
# graph at composition time.

role_module_specs = [
  {
    name: "nodejs-runtime",
    category: cat_runtime,
    description: "Node.js 20 LTS runtime via NodeSource — provides /usr/bin/node, /usr/bin/npm, /usr/bin/git.",
    priority: 60,
    package_spec: %w[nodejs npm git ca-certificates curl],
    file_spec:    %w[/usr/bin/node /usr/bin/npm /usr/bin/npx /usr/bin/git /usr/lib/node_modules/**],
    protected_spec: [],
    depends_on:   %w[system-base],
    manifest: {
      "runtime"     => "nodejs",
      "init_script" => "curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs npm git",
      "env"         => { "NODE_ENV" => "production" },
      "ports"       => [],
      "healthcheck" => { "command" => "node --version", "interval_seconds" => 30 }
    }
  },
  {
    name: "python-runtime",
    category: cat_runtime,
    description: "Python 3.12 runtime + pip + venv + git — provides /usr/bin/python3.12.",
    priority: 60,
    package_spec: %w[python3.12 python3-pip python3-venv git ca-certificates],
    file_spec:    %w[/usr/bin/python3.12 /usr/bin/pip3 /usr/bin/git /usr/lib/python3.12/**],
    protected_spec: [],
    depends_on:   %w[system-base],
    manifest: {
      "runtime"     => "python",
      "init_script" => "apt-get install -y python3.12 python3-pip python3-venv git",
      "env"         => { "PYTHONUNBUFFERED" => "1" },
      "ports"       => [],
      "healthcheck" => { "command" => "python3 --version", "interval_seconds" => 30 }
    }
  },
  {
    name: "postgres-server",
    category: cat_database,
    description: "PostgreSQL 16 server — initdb on first boot, listens on 5432.",
    priority: 65,
    package_spec: %w[postgresql-16 postgresql-client-16 postgresql-contrib],
    file_spec:    %w[/usr/lib/postgresql/16/** /etc/postgresql/16/** /usr/bin/psql],
    protected_spec: %w[/etc/postgresql/16/main/pg_hba.conf /etc/postgresql/16/main/postgresql.conf],
    depends_on:   %w[system-base],
    manifest: {
      "runtime"     => "postgres",
      "init_script" => "apt-get install -y postgresql-16 && pg_ctlcluster 16 main start",
      "env"         => { "PGDATA" => "/var/lib/postgresql/16/main" },
      "ports"       => [5432],
      "healthcheck" => { "command" => "pg_isready -h 127.0.0.1 -p 5432", "interval_seconds" => 10 }
    }
  },
  {
    name: "redis-cache",
    category: cat_cache,
    description: "Redis 7 in-memory cache — listens on 6379.",
    priority: 67,
    package_spec: %w[redis-server],
    file_spec:    %w[/usr/bin/redis-server /usr/bin/redis-cli /etc/redis/**],
    protected_spec: %w[/etc/redis/redis.conf],
    depends_on:   %w[system-base],
    manifest: {
      "runtime"     => "redis",
      "init_script" => "apt-get install -y redis-server && systemctl enable --now redis-server",
      "env"         => {},
      "ports"       => [6379],
      "healthcheck" => { "command" => "redis-cli ping", "interval_seconds" => 10 }
    }
  },
  {
    name: "docker-runtime",
    category: cat_runtime,
    description: "Docker CE + compose plugin + buildx — adds 'ubuntu' user to the docker group.",
    priority: 60,
    package_spec: %w[docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin],
    file_spec:    %w[/usr/bin/docker /usr/bin/dockerd /usr/libexec/docker/cli-plugins/**],
    protected_spec: %w[/etc/docker/daemon.json /etc/docker/**],
    depends_on:   %w[system-base],
    manifest: {
      "runtime"     => "docker",
      "init_script" => "curl -fsSL https://get.docker.com | sh && usermod -aG docker ubuntu && systemctl enable --now docker",
      "env"         => {},
      "ports"       => [],
      "healthcheck" => { "command" => "docker info", "interval_seconds" => 30 }
    }
  }
].freeze

created_count = 0
updated_count = 0

role_module_specs.each do |spec|
  m = ::System::NodeModule.find_or_initialize_by(account: account, name: spec[:name])
  was_new = m.new_record?

  m.assign_attributes(
    category: spec[:category],
    variety: "subscription",
    priority: spec[:priority],
    description: spec[:description],
    enabled: true,
    public: true,
    package_spec:   encode_spec_array.call(spec[:package_spec]),
    file_spec:      encode_spec_array.call(spec[:file_spec]),
    protected_spec: encode_spec_array.call(spec[:protected_spec]),
    config: (m.config || {}).merge(
      "manifest"    => spec[:manifest],
      "depends_on"  => spec[:depends_on]
    )
  )
  m.save!

  if was_new
    created_count += 1
    puts "    ✓ NodeModule (created): #{spec[:name]} (#{spec[:category].name}, priority=#{spec[:priority]})"
  else
    updated_count += 1
    puts "    ↻ NodeModule (updated): #{spec[:name]} (#{spec[:category].name}, priority=#{spec[:priority]})"
  end
end

puts "    ✓ Role modules: #{created_count} created, #{updated_count} updated (#{role_module_specs.size} total)"
puts "  Done seeding role modules."
