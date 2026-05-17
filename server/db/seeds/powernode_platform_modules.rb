# frozen_string_literal: true

# System extension — Powernode Platform modules seed.
#
# Creates the 9 platform modules that compose the Powernode platform itself.
# These modules are what make the platform deploy itself onto its own fleet
# (the "Powernode runs Powernode" goal from the Decentralized Federation plan).
#
#   - powernode-base-ruby          Ruby 3.3 + bundler + build deps
#   - powernode-postgres           PostgreSQL 16 primary
#   - powernode-redis              Redis for Sidekiq + ActionCable + cache
#   - powernode-reverse-proxy      Traefik + ACME DNS-01 (P2.5 lives here)
#   - powernode-hub-backend        Rails API + ActionCable
#   - powernode-hub-worker         Sidekiq worker (API-only HTTP to backend)
#   - powernode-hub-frontend       Vite static assets (served by reverse-proxy)
#   - powernode-pg-replica         PG streaming replica (cluster_member only)
#   - powernode-extension-system   System extension Rails engine
#
# Each module's manifest_yaml is the authoritative source; it's parsed by
# System::ManifestImportService into ModuleService rows. The on-node Go
# agent reads the same manifest_yaml at attach time.
#
# Plan reference: Decentralized Federation §B, P1.8.
# Plan file: ~/.claude/plans/the-powrnode-platform-consists-peppy-salamander.md
#
# Depends on:
#   - powernode_platform_categories.rb (P1.7) — must run first
#   - node_module_catalog.rb           — for the ubuntu-24.04-lts NodePlatform
#
# Idempotent: re-running upserts existing modules via find_or_initialize_by;
# ManifestImportService.import! is itself idempotent.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/powernode_platform_modules.rb')"

POWERNODE_PLATFORM_CATEGORY_NAME = "Powernode Platform"

POWERNODE_PLATFORM_MODULE_MANIFESTS = {
  "powernode-base-ruby" => <<~YAML,
    schema_version: 1
    name: powernode-base-ruby
    display_name: Powernode Base Ruby Runtime
    description: Ruby 3.3 + bundler + system dependencies for Rails workloads
    license: MIT
    package_spec:
      - ruby3.3
      - ruby3.3-dev
      - bundler
      - build-essential
      - libpq-dev
      - libssl-dev
      - libyaml-dev
      - zlib1g-dev
    file_spec: []
    mask: []
    dependency_spec: []
    protected_spec: []
    reboot_required: false
  YAML

  "powernode-postgres" => <<~YAML,
    schema_version: 1
    name: powernode-postgres
    display_name: PostgreSQL 16
    description: PostgreSQL server providing the platform's primary database
    license: PostgreSQL
    package_spec:
      - postgresql-16
      - postgresql-contrib-16
      - postgresql-client-16
    file_spec: []
    mask: []
    dependency_spec: []
    protected_spec:
      - /etc/postgresql/16/main/postgresql.conf
    services:
      - name: postgres
        start_command: "/usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main -c config_file=/etc/postgresql/16/main/postgresql.conf"
        stop_command: "/usr/bin/pg_ctl -D /var/lib/postgresql/16/main stop -m fast"
        restart_policy: always
        user: postgres
        working_directory: /var/lib/postgresql
        exposed_ports:
          - { port: 5432, protocol: tcp, name: postgres }
        capabilities: []
        metadata:
          pg_data: /var/lib/postgresql/16/main
          pg_version: "16"
  YAML

  "powernode-redis" => <<~YAML,
    schema_version: 1
    name: powernode-redis
    display_name: Redis
    description: Redis for Sidekiq queues, ActionCable pub/sub, and Rails cache
    license: BSD-3-Clause
    package_spec:
      - redis-server
    file_spec: []
    mask: []
    dependency_spec: []
    protected_spec:
      - /etc/redis/redis.conf
    services:
      - name: redis
        start_command: "/usr/bin/redis-server /etc/redis/redis.conf"
        restart_policy: always
        user: redis
        exposed_ports:
          - { port: 6379, protocol: tcp, name: redis }
        capabilities: []
  YAML

  "powernode-reverse-proxy" => <<~YAML,
    schema_version: 1
    name: powernode-reverse-proxy
    display_name: Powernode Reverse Proxy (Traefik + ACME DNS-01)
    description: Traefik handles TLS termination and ACME DNS-01 cert issuance for all federated peers
    license: MIT
    package_spec: []
    file_spec:
      - /usr/local/bin/traefik
      - /etc/traefik/traefik.yml
      - /etc/systemd/system/traefik.service
    mask: []
    dependency_spec: []
    protected_spec:
      - /etc/traefik/dynamic
    services:
      - name: traefik
        start_command: "/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml"
        restart_policy: always
        user: traefik
        working_directory: /etc/traefik
        exposed_ports:
          - { port: 80,  protocol: tcp, name: http }
          - { port: 443, protocol: tcp, name: https }
        capabilities:
          - CAP_NET_BIND_SERVICE
        health:
          endpoint: /ping
          method: GET
          interval_seconds: 30
          timeout_seconds: 5
          initial_delay_seconds: 5
        metadata:
          traefik_version: "v3"
          acme_dynamic_config_path: /etc/traefik/dynamic
          notes: "Cert lifecycle managed by Acme::CertificateManager (P2.5). Dynamic config written by Acme::TraefikConfigWriter from system_acme_certificates rows."
  YAML

  "powernode-hub-backend" => <<~YAML,
    schema_version: 1
    name: powernode-hub-backend
    display_name: Powernode Hub Backend (Rails 8 API)
    description: The Powernode platform's Rails 8 API server with ActionCable; backed by powernode-postgres and powernode-redis
    license: MIT
    package_spec: []
    file_spec:
      - /opt/powernode-rails
    mask:
      - /opt/powernode-rails/tmp
      - /opt/powernode-rails/log
      - /opt/powernode-rails/node_modules
    dependency_spec: []
    protected_spec:
      - /opt/powernode-rails/config/master.key
      - /opt/powernode-rails/config/credentials
    dependencies:
      requires:
        - powernode/powernode-base-ruby@^1.0
    services:
      - name: rails
        start_command: "bundle exec puma -C config/puma.rb"
        restart_policy: always
        user: powernode
        working_directory: /opt/powernode-rails
        env:
          RAILS_ENV: production
          RAILS_LOG_TO_STDOUT: "1"
        exposed_ports:
          - { port: 3000, protocol: tcp, name: http }
        capabilities: []
        health:
          endpoint: /up
          method: GET
          interval_seconds: 30
          timeout_seconds: 5
          initial_delay_seconds: 30
        metadata:
          ruby_version: "3.3"
          rails_version: "8.0"
          notes: "ActionCable shares port 3000 via Rack-mounted /cable path."
  YAML

  "powernode-hub-worker" => <<~YAML,
    schema_version: 1
    name: powernode-hub-worker
    display_name: Powernode Hub Worker (Sidekiq)
    description: Sidekiq worker process; communicates with hub-backend via HTTP API only
    license: MIT
    package_spec: []
    file_spec:
      - /opt/powernode-worker
    mask:
      - /opt/powernode-worker/tmp
      - /opt/powernode-worker/log
    dependency_spec: []
    protected_spec: []
    dependencies:
      requires:
        - powernode/powernode-base-ruby@^1.0
    services:
      - name: sidekiq
        start_command: "bundle exec sidekiq -C config/sidekiq.yml"
        restart_policy: on-failure
        user: powernode
        working_directory: /opt/powernode-worker
        env:
          RAILS_ENV: production
          BACKEND_API_URL: "http://localhost:3000"
        capabilities: []
        metadata:
          sidekiq_version: "7.x"
          notes: "BACKEND_API_URL is the default; per-node deployments override via config-variety child module (SDWAN VIP or DNS)."
  YAML

  "powernode-hub-frontend" => <<~YAML,
    schema_version: 1
    name: powernode-hub-frontend
    display_name: Powernode Hub Frontend (Vite static assets)
    description: React TypeScript frontend built artifacts; served as static files by powernode-reverse-proxy
    license: MIT
    package_spec: []
    file_spec:
      - /opt/powernode-frontend/dist
    mask: []
    dependency_spec: []
    protected_spec: []
    dependencies:
      requires:
        - powernode/powernode-reverse-proxy@^1.0
  YAML

  "powernode-pg-replica" => <<~YAML,
    schema_version: 1
    name: powernode-pg-replica
    display_name: PostgreSQL 16 Streaming Replica
    description: PostgreSQL streaming replica following a parent platform's primary (cluster_member spawn mode)
    license: PostgreSQL
    package_spec:
      - postgresql-16
      - postgresql-client-16
    file_spec: []
    mask: []
    dependency_spec: []
    protected_spec:
      - /etc/postgresql/16/replica/postgresql.conf
      - /var/lib/postgresql/16/replica
    services:
      - name: pg-replica
        start_command: "/usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/replica -c config_file=/etc/postgresql/16/replica/postgresql.conf"
        restart_policy: always
        user: postgres
        working_directory: /var/lib/postgresql/16/replica
        exposed_ports:
          - { port: 5433, protocol: tcp, name: pg-replica }
        capabilities: []
        metadata:
          role: streaming_replica
          pg_version: "16"
          notes: "Replication slot + primary connection string injected via virtio-fw-cfg at spawn time."
  YAML

  "powernode-extension-system" => <<~YAML,
    schema_version: 1
    name: powernode-extension-system
    display_name: Powernode System Extension
    description: The Powernode System extension Rails engine (nodes, modules, SDWAN, fleet autonomy, Go agent control plane)
    license: MIT
    package_spec: []
    file_spec:
      - /opt/powernode-rails/extensions/system
    mask:
      - /opt/powernode-rails/extensions/system/tmp
    dependency_spec: []
    protected_spec: []
    dependencies:
      requires:
        - powernode/powernode-hub-backend@^1.0
  YAML
}.freeze

puts "\n  Seeding Powernode Platform modules (9 modules)..."

created = 0
updated = 0
errors  = []

::Account.find_each do |account|
  category = ::System::NodeModuleCategory.find_by(
    account: account,
    name: POWERNODE_PLATFORM_CATEGORY_NAME,
    variety: "subscription"
  )

  unless category
    errors << "Account #{account.id}: Powernode Platform category missing — run powernode_platform_categories.rb first"
    next
  end

  POWERNODE_PLATFORM_MODULE_MANIFESTS.each do |module_name, manifest_yaml|
    mod = ::System::NodeModule.find_or_initialize_by(
      account: account,
      name: module_name
    )
    was_new = mod.new_record?

    mod.variety = "subscription"
    mod.category = category
    mod.enabled = true
    mod.public = false
    mod.priority = 50
    mod.lock_spec = false
    mod.save!

    result = ::System::ManifestImportService.import!(
      node_module: mod,
      yaml: manifest_yaml,
      create_version: false
    )

    if result.ok?
      if was_new
        created += 1
        puts "    ✓ Account #{account.id}: created #{module_name} (#{mod.module_services.size} services)"
      else
        updated += 1
      end
    else
      errors << "Account #{account.id} / #{module_name}: #{result.error}"
    end
  end
end

puts "  Powernode Platform modules: #{created} created, #{updated} updated"
if errors.any?
  puts "  ⚠ Errors encountered:"
  errors.each { |e| puts "    - #{e}" }
end
