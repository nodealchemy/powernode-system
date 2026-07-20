# frozen_string_literal: true

# System extension — Powernode dev-cell seed (increment 21).
#
# Provisions the platform's own warm AI-agent dev-cell topology: a
# NodeTemplate composing the dev-cell module stack, a paused InstancePool
# bound to it (operator arms it deliberately — see below), and an isolated
# Sdwan::Network whose id the template's config references.
#
# Kept as its own file rather than folded into
# POWERNODE_PLATFORM_TEMPLATE_SPECS (powernode_platform_templates.rb):
# that spec hash is built once and shared across every account in the
# Account.find_each loop, so it can't carry a per-account
# config["sdwan_network_id"] — each account gets its own Sdwan::Network row
# (uniqueness scoped to account) with a distinct id. This seed creates that
# network first, then writes its id into the per-account NodeTemplate.config.
#
# Idempotent: find_or_initialize_by throughout; TemplateModule rows rebuilt
# with stale-module pruning — mirrors the upsert pattern in
# powernode_platform_templates.rb exactly.
#
# Depends on:
#   - node_module_catalog.rb           — for the ubuntu-24.04-lts NodePlatform
#   - powernode_platform_modules.rb    — for powernode-system-base,
#     base-os-ubuntu-noble, runtime-ruby, postgres-primary, qemu-guest-agent
#   - claude-tmux module catalog entry
#   - the dev-cell module itself (increment 21). Landing order: commit
#     modules/dev-cell/ to disk → run powernode_platform_modules.rb (the
#     loader seed that creates the NodeModule row) → then this seed. It IS
#     present on disk as of this seed's authorship (currently untracked);
#     the missing-module guard below only protects accounts that haven't
#     run the loader seed yet (same idiom as powernode_platform_templates.rb).
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/powernode_dev_cell.rb')"

DEV_CELL_MODULES = %w[
  powernode-system-base
  base-os-ubuntu-noble
  runtime-ruby
  postgres-primary
  qemu-guest-agent
  claude-tmux
  dev-cell
  redis
  dev-cell-docker
  dev-cell-browser
  tmux-manager
].freeze
# tmux-manager ships installed-but-not-enabled (see its own manifest) —
# template-wide assignment is safe: no dev-cell instance auto-starts a tmux
# session just by carrying this module. The operator's personal session
# config (~pnadmin/.tmux-manager/powernode.conf) is still delivered
# per-instance, separately, not via this module.

DEV_CELL_TEMPLATE_NAME = "powernode-dev-cell"
DEV_CELL_POOL_NAME     = "dev-cell-pool"
DEV_CELL_NETWORK_NAME  = "dev-fleet"

puts "\n  Seeding Powernode dev-cell topology (template + pool + SDWAN)..."

created = 0
updated = 0
errors  = []

::Account.find_each do |account|
  platform = ::System::NodePlatform.find_by(account: account, name: "ubuntu-24.04-lts")
  unless platform
    errors << "Account #{account.id}: NodePlatform 'ubuntu-24.04-lts' missing — run node_module_catalog.rb first"
    next
  end

  module_index = ::System::NodeModule.where(account: account, name: DEV_CELL_MODULES).index_by(&:name)
  missing = DEV_CELL_MODULES.reject { |m| module_index[m] }
  if missing.any?
    errors << "Account #{account.id} / #{DEV_CELL_TEMPLATE_NAME}: missing modules #{missing.inspect} — " \
              "run powernode_platform_modules.rb (and seed the dev-cell module, once it lands) first"
    next
  end

  # ── Sdwan::Network — must exist before the template, since the template's
  #    config references the network's id ────────────────────────────────
  network = ::Sdwan::Network.find_or_initialize_by(account: account, name: DEV_CELL_NETWORK_NAME)
  if network.new_record?
    network.assign_attributes(
      description: "Isolated overlay for warm dev-cell instances (inc21). Peers enroll via " \
                    "Sdwan::PeerEnroller when a dev-cell NodeInstance provisions off this pool; " \
                    "cross-tenant isolation comes from kernel routing on a distinct /64 (same " \
                    "guarantee as example_multi_tenant.rb).",
      routing_protocol: "static"
      # status intentionally omitted — defaults to "registered"; peer health
      # flips it to "active" once a real dev-cell instance enrolls.
    )
  end
  network.save!

  # No firewall rule here, deliberately. Sdwan::FirewallCompiler emits no
  # `ct state established,related accept` preamble before compiling a
  # `drop` onto the WireGuard `input` hook, so a default-deny-ingress rule
  # would black-hole solicited RETURN traffic too — the cell's own
  # connections (including its enrollment handshake) would break, not just
  # unsolicited inbound. Egress-hook compilation (the rule that could
  # actually scope this to "no unsolicited inbound") is unshipped. Isolation
  # for this overlay comes from routing — distinct /64 per network, same
  # guarantee example_multi_tenant.rb documents — not a firewall rule.

  # ── NodeTemplate ─────────────────────────────────────────────────────────
  template = ::System::NodeTemplate.find_or_initialize_by(account: account, name: DEV_CELL_TEMPLATE_NAME)
  was_new = template.new_record?

  template.node_platform = platform
  template.enabled = true
  template.public = false
  template.description = "Warm AI-agent dev cell: Powernode-as-OS base + Ruby runtime + local " \
                          "Postgres + claude-tmux harness, enrolled onto the dev-fleet SDWAN overlay."
  # boot_mode: uefi_disk. dev-cell layers the same system-base +
  # base-os-ubuntu-noble pivot-boot stack as powernode-hub-pivot, but is
  # provisioned onto Proxmox via an API token — and PVE restricts the qemu
  # `args` key (which direct_kernel needs to pass -kernel/-initrd/-append)
  # to the literal root@pam ticket user, so an API-token provision cannot
  # set it. The platform publishes a UEFI disk image; the cell boots that
  # image and the agent's initramfs does the module pull + switch_root from
  # there (same pivot outcome, without needing qemu `args`).
  template.config = (template.config || {}).merge(
    "boot_mode" => "uefi_disk",
    "sdwan_network_id" => network.id
  )
  template.save!

  desired_module_ids = []
  DEV_CELL_MODULES.each_with_index do |module_name, idx|
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
    puts "    ✓ Account #{account.id}: created #{DEV_CELL_TEMPLATE_NAME} → [#{DEV_CELL_MODULES.join(', ')}]"
  else
    updated += 1
  end

  # ── InstancePool ─────────────────────────────────────────────────────────
  # provider_region / provider_instance_type are optional on the model, but
  # the replenisher needs both to actually provision a cloud instance
  # (System::ProvisioningService.provision_instance). Resolve them from the
  # SAME provider — picking each independently via `.first` risks pairing a
  # region on one provider with an instance type on another, which makes
  # resolve_preset! hard-fail forever. Prefer a Proxmox/PVE provider (the
  # dev-cell's actual target); if the account has none, leave both nil
  # rather than bind a mismatched pair — the pool stays replenish-inert
  # until an operator sets bindings explicitly.
  provider = ::System::Provider.find_by(account: account, provider_type: "proxmox")
  region = instance_type = nil
  if provider
    region = ::System::ProviderRegion.where(account: account, provider: provider).first
    instance_type = ::System::ProviderInstanceType.where(account: account, provider: provider).first
    region = instance_type = nil unless region && instance_type
  end

  # Seeded PAUSED, not active. An active pool with target_size >= 1 hands
  # control to the 60s reaper (InstancePool.replenishable scope = active +
  # draining) the instant this seed loads, which means real VM provisioning
  # on every account, unbidden. Paused pools are excluded from the reaper's
  # listing — a true no-op until an operator deliberately flips status to
  # "active". target_size stays modest (1) as belt-and-suspenders once armed.
  #
  # Sizing/status/provider bindings are operator-tunable after creation, so
  # only set them on first creation — re-runs must not clobber a drain or
  # retune (mirrors example_instance_pool.rb's new_record? guard).
  pool = ::System::InstancePool.find_or_initialize_by(account: account, name: DEV_CELL_POOL_NAME)
  if pool.new_record?
    pool.assign_attributes(
      provider_region: region,
      provider_instance_type: instance_type,
      lifecycle_class: "ephemeral",
      target_size: 1,
      min_size: 0,
      max_size: 3,
      status: "paused"
    )
  end
  pool.description = "Warm pool for on-demand AI-agent dev cells (inc21). Conservative sizing — " \
                      "raise target_size once real utilization data justifies it. Seeded paused — " \
                      "an operator must arm it (status: active) once provider bindings are verified."
  pool.node_template = template
  pool.save!

  provider_note = region && instance_type ? "region=#{region.region_code || region.name}" : "no provider_region/instance_type yet — replenish will no-op until set"
  puts "    ✓ Account #{account.id}: #{DEV_CELL_POOL_NAME} (status=#{pool.status}, target_size=#{pool.target_size}, network=#{network.name}, #{provider_note})"
rescue StandardError => e
  errors << "Account #{account.id}: #{e.class}: #{e.message}"
end

puts "  Powernode dev-cell topology: #{created} template(s) created, #{updated} updated"
if errors.any?
  puts "  ⚠ Errors encountered:"
  errors.each { |e| puts "    - #{e}" }
end
