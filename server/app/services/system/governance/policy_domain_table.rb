# frozen_string_literal: true

module System
  module Governance
    # The System extension's intervention-policy DOMAIN table: which domain owns
    # a policy category, as category prefixes, first match wins.
    #
    # Registered with core's Ai::ClaudeExport::PolicyDomains seam at boot
    # (lib/powernode_system/engine.rb), which is how core's policy panel
    # (GET /api/v1/ai/intervention_policies/grouped) files these categories
    # into sections, and how the Claude-export skeleton and the router derive an
    # agent's policy domains. Core cannot name this constant (Extension
    # Isolation), so registration is the only path in.
    #
    # The frontend presents these same keys (label, icon, blurb) through
    # featureRegistry.registerPolicyDomains('system', ...) in register.ts; a key
    # with no presentation still renders under a humanised label.
    module PolicyDomainTable
      # ORDER IS SIGNIFICANT. Core resolves first-match-wins over the registered
      # table (Ai::InterventionPolicies::GroupedView), so any prefix that EXTENDS
      # another entry's prefix has to be declared before it. Three such pairs exist today:
      #
      #   system.instance_pool_           ⊂ system.instance_  (node_lifecycle)
      #   system.module_critical_upgrade_ ⊂ system.module_    (node_lifecycle)
      #   system.sdwan_federation_compose ⊂ system.sdwan_     (topology)
      #
      # The first two were mis-filed until this map was ordered specific-first:
      # the whole `instance_pool` domain was unreachable, and the CVE Responder's
      # `system.module_critical_upgrade_ready` landed under node_lifecycle. Note
      # that category is NOT prefixed `system.cve_`, so moving "cve" ahead of
      # "node_lifecycle" does not on its own file it correctly — the specific
      # prefix has to be listed too.
      #
      # Every category the extension REGISTERS (lib/powernode_system/engine.rb,
      # the same registry core's bulk save admits) must match some entry here —
      # not just the seeded ones: a registered-but-unseeded category reaches the
      # grouped view the moment an operator saves a policy row for it. "other" is the
      # catch-all for rows whose category this extension does not own.
      # spec/requests/api/v1/ai/system_policy_domains_spec.rb pins both
      # properties (no registered system./sdwan. category reaches "other"; no
      # declared domain is left unreachable) so a new family or a reorder cannot
      # regress silently.
      PREFIXES = {
        "instance_pool"     => %w[system.instance_pool_],
        "cve"               => %w[system.cve_ system.module_critical_upgrade_],
        # The System Topology Designer's composer trio — since HIER-P2DECL all
        # three are declared on that agent's own set
        # (PolicyDeclarations::TOPOLOGY_DESIGNER_POLICIES; sdwan_federation_
        # compose was registered-and-unseeded until then, the other two sat in
        # FLEET_AUTONOMY_POLICIES since IMP-4ba48fd088ce). Kept as a family
        # here regardless of ownership: the pivot is by FAMILY, not by owner.
        # Declared BEFORE "sdwan" because system.sdwan_federation_compose
        # extends system.sdwan_ and first match wins.
        "topology"          => %w[system.sdwan_federation_compose system.multi_tenant_isolation system.service_discovery_compose],
        "sdwan"             => %w[system.sdwan_ sdwan. system.federation_],
        "container_runtime" => %w[system.runtime_],
        "disk_image"        => %w[system.disk_image_],
        "gitops"            => %w[system.gitops_],
        # ONE spelling here too (IMP-2effedffc990): `system.package_module_` used
        # to pivot PackageModuleCreateExecutor's derived
        # system.package_module_create beside the seeded
        # system.package_module.create row — same interim, same fix as the
        # architecture family below.
        "packages"          => %w[system.package_module. system.package_repository.],
        # ONE spelling (IMP-51e5c6184ae4). `system.architecture_<verb>` — the
        # gated executors' derived categories under APO-1c — used to be listed
        # here alongside the seeded `system.architecture.<verb>` rows so the modal
        # at least filed both under one domain. The executors now DECLARE the
        # dotted category, the underscored rows are retired, and a second
        # spelling must not come back: it would render as a SECOND control over
        # the same action, which pivoting it into this domain hides rather than
        # fixes.
        "architecture"      => %w[system.architecture.],
        # system.volume_snapshot_ — the gated snapshot delete (IMP-e025722ef14e),
        # and the schedule family the snapshot sensor will route to.
        "storage"           => %w[system.storage_ system.restore_volume system.volume_snapshot_],
        # Service exposure + certificate issuance (APO-1c gated executors).
        # system.service_backends_ — the SystemIngressTool backend-set gate
        # (IMP-0c10b9fd5596). A UI BUCKET, and since HIER-P2DECL also where the
        # category is OWNED: it travels with the ingress group in
        # PolicyDeclarations::INGRESS_MANAGER_POLICIES (HIER-P2A had filed it
        # here while leaving ownership on Fleet Autonomy; the two axes agree
        # now).
        "ingress"           => %w[system.expose_service_ system.acme_certificate_ system.service_backends_],
        # Platform-deployment scaling (APO-3b): the hub-excluded replica reconciler.
        "platform"          => %w[system.platform.],
        # DELIBERATE: project.* is core-owned (Ai::InterventionPolicy::STATIC_CATEGORIES). Claiming it here is a
        # display choice for this account-wide view, not a core→extension dependency (that arrow points the
        # permitted way) — do NOT "fix" by filtering core rows out. Ruled 2026-08-23 (IMP-fa63f411633b).
        "project"           => %w[project.],
        # system.abandoned_instance_ / system.pool_guest_ — the two sensor-routed
        # reap lanes (AbandonedInstanceSensor, OrphanPoolGuestSensor), filed beside
        # system.instance_reap from the same CAPACITY_POLICY_KEYS set
        # (IMP-9c8c05f8617e). The pool-guest reap acts on a provider guest no
        # instance row knows, through a name-verified terminate, not on the pool
        # record, so it does not belong under instance_pool.
        "node_lifecycle"    => %w[system.cert_ system.acme_cert_ system.module_ system.instance_ system.fleet_ system.region_ system.capacity_ system.capability_gap_ system.observation system.task. system.task_ system.template_closure_ system.node_boot_image_ system.node_lkg_ system.fulfill_capability_ system.relocate_ system.replica_promote system.abandoned_instance_ system.pool_guest_]
      }.freeze
    end
  end
end
