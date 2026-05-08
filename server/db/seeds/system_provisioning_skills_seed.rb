# frozen_string_literal: true

# System extension — Ai::Skill registration for the new provisioning
# executors introduced in the AI-Driven Provisioning plan (M0+M1).
#
# This seed is companion to `system_skills_seed.rb` (which registers the
# original 14 system executors). It registers the *additional* skills that
# the provisioning conversation depends on. M0 ships the first row only
# (`provision_full_stack`); the remaining rows are placeholders for
# M1/M2 executors and only insert if the executor class is autoloadable.
#
# Per `system_skills_seed.rb`: Ai::Skill has no first-class `executor_class`
# column — we stash it in `metadata.executor_class`. Category must be one
# of `Ai::Skill::CATEGORIES` (the executor's own descriptor uses tighter
# labels — those go in `metadata.system_subdomain`).
#
# AI-Driven Provisioning plan — slice 4 (M0).
#
# Idempotent: re-running updates by slug.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/system_provisioning_skills_seed.rb')"

puts "\n  Seeding AI-driven provisioning skills..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting"
  return
end

PROVISIONING_SKILLS_DATA = [
  {
    name: "Provision Full Stack",
    slug: "system-provision-full-stack",
    description: "Provision a full compute + (optional) network + (optional) storage stack from a NodeTemplate — composes provision_instance per node, optionally provisions per-instance volumes, and compiles the SDWAN topology",
    category: "devops",
    subdomain: "provisioning",
    executor: "System::Ai::Skills::ProvisionFullStackExecutor",
    blast_radius: "medium",
    tags: %w[provisioning fleet templates storage sdwan stack],
    system_prompt: <<~PROMPT.strip
      Use this skill when an operator's brief calls for a complete stack —
      compute + (optional) SDWAN attach + (optional) per-instance storage —
      from a single Template. Inputs: template_id, count (1-50),
      provider_region_id, provider_instance_type_id, network_id (optional),
      with_storage_gb (optional), dry_run. Returns created node ids,
      node instance ids, storage volume ids, sdwan peer ids, and a
      planned_actions audit log. Has a rollback handler that terminates
      provisioned instances + deletes provisioned volumes in reverse order.
    PROMPT
  },
  {
    name: "Scale Project",
    slug: "system-scale-project",
    description: "Scale a provisioning project — add replicas in-region, plan a vertical resize via rolling module upgrade, or expand into a new region. Composes ProvisionFullStackExecutor + RollingModuleUpgradeExecutor.",
    category: "devops",
    subdomain: "provisioning",
    executor: "System::Ai::Skills::ScaleProjectExecutor",
    blast_radius: "medium",
    tags: %w[provisioning scaling adaptation fleet],
    system_prompt: <<~PROMPT.strip
      Use this skill when the AdaptationProposer detects capacity pressure
      or a region-imbalance condition on an existing provisioning project.
      Inputs: project_id (Ai::Mission id), target_count (1-50),
      scaling_strategy (add_replicas | vertical_resize | add_region) plus
      strategy-specific lookups (template_id, provider_region_id,
      provider_instance_type_id, module_id, target_version_id, network_id,
      with_storage_gb), dry_run. Returns the unified outputs envelope so
      the runner's rollback dispatch can terminate any new instances and
      delete any new volumes uniformly with the M0 contract.
    PROMPT
  },
  {
    name: "Relocate Workload",
    slug: "system-relocate-workload",
    description: "Relocate a project's compute workload from one region to another via blue/green or drain cutover. Composes ProvisionFullStackExecutor (target) + ProvisioningService.terminate_instance (source).",
    category: "devops",
    subdomain: "provisioning",
    executor: "System::Ai::Skills::RelocateWorkloadExecutor",
    blast_radius: "high",
    tags: %w[provisioning relocation cutover adaptation],
    system_prompt: <<~PROMPT.strip
      Use this skill when an adaptation calls for moving a workload to a
      different region (region failure, latency drift, cost arbitrage).
      Inputs: project_id, from_region_id, to_region_id, cutover_strategy
      (blue_green | drain), template_id, provider_instance_type_id, count
      (1-50), source_instance_ids[], network_id (optional),
      with_storage_gb (optional), dry_run. Requires approval (high blast
      radius). Rollback terminates the new target stack — source
      instances cannot be un-terminated.
    PROMPT
  },
  {
    name: "Attach Storage",
    slug: "system-attach-storage",
    description: "Provision a cloud volume, attach it to a running NodeInstance, and mount it at the requested path. Composes VolumeManagementService.provision/attach + SshExecutionService for filesystem setup.",
    category: "devops",
    subdomain: "provisioning",
    executor: "System::Ai::Skills::AttachStorageExecutor",
    blast_radius: "low",
    tags: %w[provisioning storage volume mount adaptation],
    system_prompt: <<~PROMPT.strip
      Use this skill when an instance needs a fresh attached volume — for
      data growth, log retention, or attaching project-scoped storage.
      Inputs: instance_id, size_gb (1-16384), volume_type (optional),
      mount_point (default /data), dry_run. Returns storage_volume_ids
      and the mount sub-hash (instance_id, device, mount_point) so the
      operator can verify provisioning succeeded. Rollback detaches and
      deletes the volume.
    PROMPT
  },
  {
    name: "Configure SDWAN for Project",
    slug: "system-configure-sdwan-for-project",
    description: "Create an SDWAN network for a project, attach the supplied instances as peers, optionally provision a project VIP, and compile the topology preview. Composes Sdwan::Network + Sdwan::PeerEnroller + Sdwan::VirtualIp + Sdwan::TopologyCompiler.",
    category: "devops",
    subdomain: "provisioning",
    executor: "System::Ai::Skills::ConfigureSdwanForProjectExecutor",
    blast_radius: "medium",
    tags: %w[provisioning sdwan network vip topology adaptation],
    system_prompt: <<~PROMPT.strip
      Use this skill when an adaptation introduces an overlay between
      project instances (e.g. "stitch the new region peers into the
      existing project mesh"). Inputs: project_id, instance_ids[]
      (1-100), network_name, topology (hub_and_spoke | mesh), with_vip
      (optional), vip_name (optional), vip_cidr (required when with_vip),
      dry_run. Returns sdwan_network_id, sdwan_peer_ids, virtual_ip_id,
      and a topology_preview. Rollback destroys the VIP, peers, and
      network in reverse order.
    PROMPT
  },
  {
    # M3 self-serve "Run My Code" — registered here for skill metadata; the
    # executor (Slice B) is gated by the executor_loaded check below so this
    # row is a no-op until the class lands.
    name: "Deploy Application Code",
    slug: "system-deploy-app-code",
    description: "Clone a Git repository onto a provisioned NodeInstance over SSH, detect (or accept) the runtime, install dependencies, and create a systemd unit that runs the operator-supplied start command. Composes System::CodeDeployService.",
    category: "devops",
    subdomain: "provisioning",
    executor: "System::Ai::Skills::DeployAppCodeExecutor",
    blast_radius: "medium",
    tags: %w[provisioning deploy git systemd m3 self-serve],
    system_prompt: <<~PROMPT.strip
      Use this skill when an operator's brief carries a Git repository URL
      and (optionally) a start command — the M3 "Run My Code" path. Inputs:
      node_instance_id, repo_url, branch (default "main"), start_command
      (optional — auto-detected from package.json/requirements.txt when
      absent), deploy_key (optional, for private repos), dry_run. Returns
      commit_sha, public_url, systemd_unit_path. Auto-detect runtime falls
      back to nodejs (package.json) → python (requirements.txt or
      pyproject.toml). Rollback removes /opt/app and disables the systemd
      unit. SSH transport is delegated to System::SshExecutionService.
    PROMPT
  }
].freeze

created_count = 0
updated_count = 0
skipped_count = 0

PROVISIONING_SKILLS_DATA.each do |data|
  # Defensive: skip if the executor class isn't loaded (M1/M2 placeholders).
  executor_loaded = begin
    data[:executor].constantize
    true
  rescue NameError
    false
  end

  unless executor_loaded
    puts "    ⊘ Skipping #{data[:slug]} — executor class #{data[:executor]} not loaded yet"
    skipped_count += 1
    next
  end

  skill = ::Ai::Skill.find_or_initialize_by(slug: data[:slug])
  was_new = skill.new_record?
  skill.assign_attributes(
    account: account,
    name: data[:name],
    description: data[:description],
    category: data[:category],
    status: "active",
    system_prompt: data[:system_prompt],
    commands: [],
    activation_rules: {},
    metadata: {
      "author" => "system_extension",
      "icon" => data[:subdomain],
      "system_subdomain" => data[:subdomain],
      "executor_class" => data[:executor],
      "blast_radius" => data[:blast_radius]
    },
    tags: data[:tags] + %w[system workspace provisioning],
    is_system: true,
    is_enabled: true,
    version: "1.0.0"
  )
  skill.save!
  was_new ? created_count += 1 : updated_count += 1
end

puts "    ✓ Provisioning skills: #{created_count} created, #{updated_count} updated, #{skipped_count} skipped (#{PROVISIONING_SKILLS_DATA.size} total)"
puts "  Done seeding AI-driven provisioning skills."
