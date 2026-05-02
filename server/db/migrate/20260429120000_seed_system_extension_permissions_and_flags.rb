# frozen_string_literal: true

# Seeds the System extension's Flipper feature flag and
# permission rows. Embedded directly in this migration (rather than a
# separate seed file) so that `rails db:migrate` is sufficient to bring the
# extension fully online — no extra `rails runner` step required.
#
# Idempotent: every Flipper.add and Permission.find_or_create_by guards
# against duplicates, so re-running this migration (or running it after a
# manual partial seed) is safe.
class SeedSystemExtensionPermissionsAndFlags < ActiveRecord::Migration[8.1]
  # Permission rows keyed by `name`, value is { resource, action, description }.
  # The `category` for all infrastructure CRUD permissions is "resource"
  # (matches the Docker permissions convention — see db/seeds/docker_permissions.rb).
  PERMISSIONS = {
    # Tasks (operator + worker_api). Originally seeded with system.operations.*
    # names; renamed to system.tasks.* by 20260430130000_rename_system_operations_to_tasks.rb.
    # Keys here match the post-rename names so fresh installs land on the
    # platform-standard "Task" terminology directly.
    "system.tasks.read"          => { resource: "system.tasks", action: "read",    description: "View system tasks" },
    "system.tasks.create"        => { resource: "system.tasks", action: "create",  description: "Create system tasks" },
    "system.tasks.manage"        => { resource: "system.tasks", action: "manage",  description: "Update task state (start/progress/complete/fail/events)" },
    "system.tasks.execute"       => { resource: "system.tasks", action: "execute", description: "Trigger server-side execution of a task via worker_api" },

    # Operator-facing task transitions (cancel-only on the public API; other
    # state mutations are worker-only via worker_api).
    "system.infra_tasks.read"    => { resource: "system.infra_tasks", action: "read",    description: "View operator-controlled task transitions" },
    "system.infra_tasks.create"  => { resource: "system.infra_tasks", action: "create",  description: "Create operator-driven tasks" },
    "system.infra_tasks.control" => { resource: "system.infra_tasks", action: "control", description: "Cancel operator-driven tasks" },

    # Nodes
    "system.nodes.read"   => { resource: "system.nodes", action: "read",   description: "View nodes" },
    "system.nodes.create" => { resource: "system.nodes", action: "create", description: "Create nodes" },
    "system.nodes.update" => { resource: "system.nodes", action: "update", description: "Update nodes" },
    "system.nodes.delete" => { resource: "system.nodes", action: "delete", description: "Delete nodes" },

    # Node instances (operator + worker_api)
    "system.node_instances.read"   => { resource: "system.node_instances", action: "read",   description: "View node instances" },
    "system.node_instances.create" => { resource: "system.node_instances", action: "create", description: "Create node instances" },
    "system.node_instances.update" => { resource: "system.node_instances", action: "update", description: "Update node instances" },
    "system.node_instances.manage" => { resource: "system.node_instances", action: "manage", description: "Worker-side management of node instances" },
    "system.node_instances.delete" => { resource: "system.node_instances", action: "delete", description: "Delete node instances" },

    # Instances (lifecycle control)
    "system.instances.read"    => { resource: "system.instances", action: "read",    description: "View running instances" },
    "system.instances.create"  => { resource: "system.instances", action: "create",  description: "Create instances" },
    "system.instances.update"  => { resource: "system.instances", action: "update",  description: "Update instances" },
    "system.instances.control" => { resource: "system.instances", action: "control", description: "Control instance lifecycle (start/stop/reboot/terminate)" },
    "system.instances.delete"  => { resource: "system.instances", action: "delete",  description: "Delete instances" },

    # Node modules
    "system.modules.read"   => { resource: "system.modules", action: "read",   description: "View node modules" },
    "system.modules.create" => { resource: "system.modules", action: "create", description: "Create node modules" },
    "system.modules.update" => { resource: "system.modules", action: "update", description: "Update node modules" },
    "system.modules.delete" => { resource: "system.modules", action: "delete", description: "Delete node modules" },

    # Templates / architectures / platforms / scripts
    "system.templates.read"     => { resource: "system.templates",     action: "read",   description: "View node templates" },
    "system.templates.create"   => { resource: "system.templates",     action: "create", description: "Create node templates" },
    "system.templates.update"   => { resource: "system.templates",     action: "update", description: "Update node templates" },
    "system.templates.delete"   => { resource: "system.templates",     action: "delete", description: "Delete node templates" },
    "system.architectures.read"   => { resource: "system.architectures", action: "read",   description: "View node architectures" },
    "system.architectures.create" => { resource: "system.architectures", action: "create", description: "Create node architectures" },
    "system.architectures.update" => { resource: "system.architectures", action: "update", description: "Update node architectures" },
    "system.architectures.delete" => { resource: "system.architectures", action: "delete", description: "Delete node architectures" },
    "system.platforms.read"   => { resource: "system.platforms", action: "read",   description: "View node platforms" },
    "system.platforms.create" => { resource: "system.platforms", action: "create", description: "Create node platforms" },
    "system.platforms.update" => { resource: "system.platforms", action: "update", description: "Update node platforms" },
    "system.platforms.delete" => { resource: "system.platforms", action: "delete", description: "Delete node platforms" },
    "system.scripts.read"   => { resource: "system.scripts", action: "read",   description: "View node scripts" },
    "system.scripts.create" => { resource: "system.scripts", action: "create", description: "Create node scripts" },
    "system.scripts.update" => { resource: "system.scripts", action: "update", description: "Update node scripts" },
    "system.scripts.delete" => { resource: "system.scripts", action: "delete", description: "Delete node scripts" },

    # Cloud provider catalog
    "system.providers.read"   => { resource: "system.providers",   action: "read",   description: "View cloud providers" },
    "system.providers.create" => { resource: "system.providers",   action: "create", description: "Create provider records" },
    "system.providers.update" => { resource: "system.providers",   action: "update", description: "Update providers" },
    "system.providers.delete" => { resource: "system.providers",   action: "delete", description: "Delete providers" },
    "system.providers.test"   => { resource: "system.providers",   action: "test",   description: "Test provider connection credentials" },
    "system.connections.read"   => { resource: "system.connections", action: "read",   description: "View provider connections" },
    "system.connections.create" => { resource: "system.connections", action: "create", description: "Create provider connections" },
    "system.connections.update" => { resource: "system.connections", action: "update", description: "Update provider connections" },
    "system.connections.delete" => { resource: "system.connections", action: "delete", description: "Delete provider connections" },
    "system.connections.test"   => { resource: "system.connections", action: "test",   description: "Test connection credentials" },
    "system.regions.read"   => { resource: "system.regions", action: "read",   description: "View provider regions" },
    "system.regions.create" => { resource: "system.regions", action: "create", description: "Create provider regions" },
    "system.regions.update" => { resource: "system.regions", action: "update", description: "Update provider regions" },
    "system.regions.delete" => { resource: "system.regions", action: "delete", description: "Delete provider regions" },

    # Networks + volumes
    "system.networks.read"   => { resource: "system.networks", action: "read",   description: "View networks" },
    "system.networks.create" => { resource: "system.networks", action: "create", description: "Create networks" },
    "system.networks.update" => { resource: "system.networks", action: "update", description: "Update networks" },
    "system.networks.delete" => { resource: "system.networks", action: "delete", description: "Delete networks" },
    "system.volumes.read"     => { resource: "system.volumes", action: "read",     description: "View volumes" },
    "system.volumes.create"   => { resource: "system.volumes", action: "create",   description: "Create volumes" },
    "system.volumes.update"   => { resource: "system.volumes", action: "update",   description: "Update volumes" },
    "system.volumes.manage"   => { resource: "system.volumes", action: "manage",   description: "Attach / detach / manage volumes" },
    "system.volumes.snapshot" => { resource: "system.volumes", action: "snapshot", description: "Create volume snapshots" },
    "system.volumes.delete"   => { resource: "system.volumes", action: "delete",   description: "Delete volumes" },

    # Puppet
    "system.puppet.read"   => { resource: "system.puppet", action: "read",   description: "View puppet modules + resources" },
    "system.puppet.create" => { resource: "system.puppet", action: "create", description: "Create puppet modules + resources" },
    "system.puppet.update" => { resource: "system.puppet", action: "update", description: "Update puppet modules + resources" },
    "system.puppet.delete" => { resource: "system.puppet", action: "delete", description: "Delete puppet modules + resources" }
  }.freeze

  FLIPPER_FLAGS = %i[
    system_mode
    system_task_dispatch
    system_provisioning
    system_module_distribution
  ].freeze

  def up
    seed_flipper_flags
    seed_permissions
  end

  def down
    # Permissions and flags are configuration; deleting them on rollback would
    # cascade-revoke production access. Make this migration deliberately
    # one-way. To remove a permission, use a separate explicit migration.
    say "SeedSystemExtensionPermissionsAndFlags is one-way; permissions and flags are kept on rollback."
  end

  private

  def seed_flipper_flags
    return unless defined?(Flipper)

    FLIPPER_FLAGS.each do |flag|
      Flipper.add(flag) unless Flipper.features.map(&:name).include?(flag.to_s)
    end
    say "Registered #{FLIPPER_FLAGS.size} Flipper flags for system extension."
  rescue StandardError => e
    say "Flipper seeding skipped: #{e.message}"
  end

  def seed_permissions
    created = 0
    PERMISSIONS.each do |name, attrs|
      record = Permission.find_or_create_by!(name: name) do |p|
        p.resource    = attrs[:resource]
        p.action      = attrs[:action]
        p.category    = "resource"
        p.description = attrs[:description]
      end
      created += 1 if record.previously_new_record?
    end
    say "Seeded #{created} new system permissions (#{PERMISSIONS.size} total declared)."
  end
end
