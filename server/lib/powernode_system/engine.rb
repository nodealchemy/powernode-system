# frozen_string_literal: true

module PowernodeSystem
  class Engine < ::Rails::Engine
    isolate_namespace PowernodeSystem

    # Add system extension app directories to autoload paths.
    # All System::* infrastructure code lives here (extension owns the namespace);
    # core has no System::* code after the migration. Multiple roots may still
    # coexist via Zeitwerk if any are added back later.
    initializer "powernode_system.autoload", before: :set_autoload_paths do |app|
      engine_root = root

      # NOTE: `decorators` is intentionally NOT in this list — those files
      # monkey-patch core classes (e.g. `Account.class_eval do ... end`)
      # and don't define a constant matching their path. Zeitwerk's
      # eager_load_all in production raises Zeitwerk::NameError on each
      # one. They're loaded explicitly via the `config.to_prepare` block
      # below, which uses `load` (path-based) and doesn't require the
      # directory to be on autoload_paths.
      %w[
        models
        models/concerns
        services
        services/concerns
        controllers
        controllers/concerns
        serializers
        channels
        jobs
      ].each do |subdir|
        path = engine_root.join("app", subdir)
        app.config.autoload_paths << path.to_s if path.exist?
      end

      # `lib/` for pure helpers that don't fit the app/ Zeitwerk conventions.
      # Currently that is Powernode::Bootstrap (lib/powernode/bootstrap.rb).
      #
      # This comment used to cite System::CveOps::VersionMatcher as the reason
      # the root exists. That file was a DUPLICATE of the real matcher in
      # app/services/system/cve_ops/ and has been deleted: app/services precedes
      # lib/ on the autoload path, so the lib copy was permanently shadowed —
      # inert for autoload AND eager-load, and reachable only by an explicit
      # `require`, which is exactly how a spec silently swapped the naive
      # implementation into every example in the process.
      #
      # Note before adding anything here: a class under lib/ that DUPLICATES a
      # name under app/ will never load in production and will look fine until
      # something requires it directly.
      lib_path = engine_root.join("lib")
      app.config.autoload_paths << lib_path.to_s if lib_path.exist?
    end

    # Tell Zeitwerk to ignore the decorators directory entirely. Rails
    # Engine convention auto-adds every `app/*` subdir to autoload paths,
    # but our decorators use `Class.class_eval do ... end` which doesn't
    # define a constant Zeitwerk can autoload by path. The `ignore` call
    # must run during the loader-config phase (before eager_load), so
    # we wire it as an initializer rather than to_prepare.
    initializer "powernode_system.ignore_decorators", before: :set_autoload_paths do |_app|
      decorators_path = root.join("app", "decorators")
      Rails.autoloaders.main.ignore(decorators_path.to_s) if decorators_path.exist?
    end

    # Load decorators that extend core models — explicitly via `load` (path-
    # based, not autoload-based). Decorator files use `Account.class_eval do ... end`
    # and similar reopen patterns that don't define their own constant.
    config.to_prepare do
      Dir[PowernodeSystem::Engine.root.join("app", "decorators", "**", "*_decorator.rb")].each do |decorator|
        load decorator
      end
    end

    # Add extension migrations to the application migration paths.
    initializer "powernode_system.migrations" do |app|
      migrations_path = root.join("db", "migrate")
      if migrations_path.exist?
        app.config.paths["db/migrate"] << migrations_path.to_s
      end
    end

    # Register with the dynamic extension registry.
    initializer "powernode_system.register" do
      config.after_initialize do
        Powernode::ExtensionRegistry.register(
          slug: "system",
          engine: PowernodeSystem::Engine,
          version: defined?(PowernodeSystem::VERSION) ? PowernodeSystem::VERSION : nil,
          features_module: defined?(PowernodeSystem::Features) ? PowernodeSystem::Features : nil,
          capabilities: [ :kubernetes_deploy ],
          # Contribute behavior to core through generic seams without core ever naming System::.
          # Resolved lazily by class name:
          #   * deploy_method_providers   — Kubernetes deploy method for Ai::Deploy::MethodRegistry
          #   * provision_label_resolver  — instance/region display labels for PlanSnapshotService
          #   * ingress_certs / ingress_routers — per-account ACME certs + the advanced
          #     mTLS/federation/worker/node_api/Sidekiq routers for
          #     Core::IngressConfigWriter (docs/operations/reverse-proxy.md §7-8,
          #     campaign 019f3458 increment 8). Both keys resolve to the SAME class —
          #     Acme::TraefikConfigWriter already owns cert selection and router
          #     rendering together as one cohesive per-account write; Core only
          #     engages the seam (and delegates the ENTIRE write, for byte-identical
          #     output) when BOTH keys resolve to the same registered object. Nil
          #     ⇒ core mode (self-signed baseline cert + 4 generic routers).
          providers: {
            deploy_method_providers: "System::Deploy::MethodProvider",
            provision_label_resolver: "System::ProvisionLabelResolver",
            #   * provision_verifier — live-provider reconciliation for the
            #     verify phase (Ai::Provisioning::VerificationService, F2):
            #     row exists / has provider identity / provider reports
            #     running / region matches. Fail-closed.
            provision_verifier: "System::ProvisionVerifier",
            #   * provision_prerequisites — compose-time "can this plan's
            #     skills run against this template?" checks for
            #     PlanComposerService (overlay requirements today).
            provision_prerequisites: "System::ProvisionPrerequisites",
            #   * adaptation_gate — the policy gate for `adaptation_diff` plans
            #     (Ai::Provisioning::AdaptationDispatchService, INC-2), and the
            #     store for the RemediationOutcome an applied adaptation mints.
            #     Answers from InterventionPolicy + the Fleet Autonomy agent's
            #     ApprovalChain — the same gate every fleet remediation passes.
            #     Nil ⇒ core mode, and core PARKS the plan in draft rather than
            #     proceeding ungated.
            adaptation_gate: "System::AdaptationGate",
            ingress_certs: "Acme::TraefikConfigWriter",
            ingress_routers: "Acme::TraefikConfigWriter"
          }
        )
      end
    end

    # Register feature flags with Flipper.
    initializer "powernode_system.feature_flags", after: :load_config_initializers do
      config.after_initialize do
        if defined?(Flipper)
          PowernodeSystem::Features::SYSTEM_FLAGS.each do |flag|
            Flipper.add(flag) unless Flipper.features.map(&:name).include?(flag.to_s)
          end
        end
      rescue StandardError => e
        Rails.logger.warn "[PowernodeSystem] Could not register feature flags: #{e.message}"
      end
    end

    # Subscribe the Phase 10.5 metrics collector to AS::Notifications.
    # Idempotent — safe across Rails reloader cycles in dev.
    initializer "powernode_system.metrics_subscriber", after: :load_config_initializers do
      config.after_initialize do
        ::System::Metrics::Subscriber.subscribe!
      rescue StandardError => e
        Rails.logger.warn "[PowernodeSystem] Could not register metrics subscriber: #{e.message}"
      end
    end

    # Federation mTLS Phase 2 — inject our internal-CA bundle into the core
    # Security::MtlsTrust seam so core auth (worker / internal / cable) can
    # verify client certs against OUR CA without depending on the extension
    # (dependency points extension → core). InternalCaService owns the CA.
    initializer "powernode_system.mtls_trust", after: :load_config_initializers do
      config.after_initialize do
        next unless defined?(::Security::MtlsTrust) && defined?(::System::InternalCaService)

        ::Security::MtlsTrust.own_ca_provider = -> { ::System::InternalCaService.ca_chain_pem }

        # AI/MCP workload substrate L2 — let core MCP auth resolve an instance
        # principal from a verified client-cert CN (= NodeInstance.id) without
        # depending on the extension (dependency points extension → core).
        if defined?(::Mcp::Principal)
          ::Mcp::Principal.instance_resolver = lambda do |cn|
            ::System::NodeInstance.where(id: cn).where.not(status: "terminated").first
          end
          # Default-deny tool grant: an instance's allowed tool-name glob patterns
          # come from its NodeInstancePeer (empty until explicitly granted).
          ::Mcp::Principal.tool_grant_resolver = lambda do |node_instance|
            next [] if node_instance.nil?

            ::System::NodeInstancePeer
              .where(node_instance_id: node_instance.id).pick(:granted_mcp_tools) || []
          end
        end
      rescue StandardError => e
        Rails.logger.warn "[PowernodeSystem] Could not wire MtlsTrust CA provider: #{e.message}"
      end
    end

    # Register extension permissions + role grants with the parent platform's
    # Permissions module. Without this, db:seed's Role.sync_from_config! would
    # destructively replace role_permissions with ONLY the parent config's
    # static list — wiping grants that this extension's migrations added.
    # Runs after_initialize so the autoload paths are populated; idempotent
    # so safe across Rails reloader cycles.
    initializer "powernode_system.register_permissions", after: :load_config_initializers do
      config.after_initialize do
        next unless defined?(::Permissions) && ::Permissions.respond_to?(:register_catalog)

        # FULL system-extension permission catalog, declared via the Permissions
        # catalog DSL. `register_catalog` routes through register_permissions +
        # register_role_permissions, so grants survive Role#sync_permissions!'s
        # destructive replace on every db:seed.
        #
        # Grant convention (from the permission audit):
        #   operator surface (controllers + AI tools)  -> admin
        #   worker surface  (authorize_worker_permission!) -> system_worker
        #   both surfaces -> both. super_admin gets everything programmatically.
        #
        # `resource :<r>, actions:` generates "system.<r>.<action>".
        # `permission "full.name", ...` is the escape hatch for irregular /
        # namespace-level names (feature-area singletons, non-CRUD verbs, and
        # the 4-segment system.sdwan.* names the resource helper can't express).
        ::Permissions.register_catalog(namespace: "system") do
          # ---------------------------------------------------------------
          # Worker reconcile ticks + feature-area singletons (pre-existing 13,
          # folded in unchanged) + operator scale/health dashboard.
          # ---------------------------------------------------------------
          permission "system.cloud_sync.reconcile", "Trigger CloudSyncService reconcile tick (worker, hourly)",
                     grant: { system_worker: true }
          permission "system.fleet.reconcile", "Trigger FleetAutonomyService reconcile tick (worker, 60s)",
                     grant: { system_worker: true }
          permission "system.fleet.autonomy", "Fleet autonomy decision making (worker)",
                     grant: { system_worker: true }
          permission "system.fleet.read", "View fleet / concierge state",
                     grant: { admin: true }
          permission "system.gitops.reconcile", "Trigger GitOps reconcile tick (worker, cron)",
                     grant: { system_worker: true }
          permission "system.gitops.sync", "Sync a GitOps repository (worker)",
                     grant: { system_worker: true }
          permission "system.gitops.read", "Read GitOps repository state",
                     grant: { system_worker: true }
          permission "system.gitops.write", "Modify GitOps repository state", grant: {}
          permission "system.metrics.read", "Read system metrics + telemetry",
                     grant: { system_worker: true }
          permission "system.health.check", "Check worker / system health (WorkerPermissionsView + health endpoints)",
                     grant: { admin: true, system_worker: true }
          permission "system.packages.embed", "Lease + write package embeddings (worker)",
                     grant: { system_worker: true }
          permission "system.packages.reembed", "Manually re-embed a package repository's catalog (operator)", grant: {}
          permission "system.ingress.read", "View ingress / reverse-proxy / public-exposure state (SystemIngressTool floor)",
                     grant: { admin: true }
          permission "system.ingress.manage", "Compose reverse proxies + expose services publicly (SystemIngressTool)",
                     grant: { admin: true }
          permission "system.marketplace.read", "Browse the system node-module marketplace (CatalogPage MarketplaceTab)",
                     grant: { admin: true, manager: true, member: true }

          # ---------------------------------------------------------------
          # Platform dashboard (singular `platform`) — operator deploy/scale/health.
          # (was db/seeds/system_platform_permissions.rb)
          # ---------------------------------------------------------------
          permission "system.platform.read", "View the unified Platform dashboard (counts, status, overview)",
                     grant: { admin: true }
          permission "system.platform.scale", "Draft scaling plans for platform components",
                     grant: { admin: true }
          permission "system.platform.scale.apply", "Apply a drafted scaling plan (provisions/decommissions instances)",
                     grant: { admin: true }
          permission "system.platform.health.read", "Read platform health metrics (uptime, queue depth, etc.)",
                     grant: { admin: true }
          permission "system.platform.deploy", "Deploy a new Powernode platform (standalone or federated)",
                     grant: { admin: true }
          permission "system.migrations.read", "View platform infrastructure migrations (PlatformInfraTab)",
                     grant: { admin: true }
          permission "system.migrations.apply", "Compose, advance, or run multi-hop migration chains",
                     grant: { admin: true }
          permission "system.migrations.cancel", "Cancel an active multi-hop migration chain",
                     grant: { admin: true }

          # ---------------------------------------------------------------
          # ACME / DNS certificate lifecycle (was db/seeds/system_acme_permissions.rb).
          # system.acme.manage pre-existed in the engine seam; folded in here.
          # ---------------------------------------------------------------
          permission "system.acme.read", "View issued ACME certificates and renewal state",
                     grant: { admin: true }
          permission "system.acme.issue", "Request a new ACME certificate for a domain",
                     grant: { admin: true }
          permission "system.acme.renew", "Trigger an out-of-band renewal of an existing certificate",
                     grant: { admin: true }
          permission "system.acme.revoke", "Revoke an issued certificate",
                     grant: { admin: true }
          permission "system.acme.manage", "Provision/renew ACME certificates via the ingress tool",
                     grant: { admin: true }

          # ---------------------------------------------------------------
          # CVE exposure (was db/seeds/system_cve_permissions.rb).
          # ---------------------------------------------------------------
          permission "system.cve.read", "View CVE exposures across the fleet (severity, state, affected modules)",
                     grant: { admin: true, manager: true, member: true }
          permission "system.cve.manage", "Triage CVE exposures (mark remediating / resolved / wont_fix)",
                     grant: { admin: true, manager: true }

          # ---------------------------------------------------------------
          # Storage assignments + credentials (was db/seeds/system_storage_permissions.rb).
          # Worker compliance archival. system.storage.* tool floor.
          # ---------------------------------------------------------------
          permission "system.compliance.archive", "Archive daily compliance snapshots (worker)",
                     grant: { system_worker: true }
          permission "system.storage.read", "Read storage-owner assignments + chown status (tool floor)",
                     grant: { admin: true }

          # ---------------------------------------------------------------
          # CRUD resources (operator surface -> admin unless noted).
          # ---------------------------------------------------------------
          resource :architectures, actions: %i[read create delete manage propose], grant: { admin: :all }
          resource :children, actions: %i[read spawn manage], grant: { admin: :all }
          resource :connections, actions: %i[read create update delete test], grant: { admin: :all }
          # On-demand capability fulfillment (campaign 019f6084 inc-M). The
          # `composed → approved` decision is the ONE human gate in the
          # flow — the worker sweep deliberately excludes `composed`, so this is
          # the only surface that releases a frozen plan to execute. Admin-only,
          # mirroring every other infra-mutation resource in this block.
          resource :fulfillment_requests, actions: %i[approve], grant: { admin: :all },
                   descriptions: {
                     approve: "Approve a composed capability-fulfillment request, releasing its FROZEN plan to execute"
                   }
          resource :infra_tasks, actions: %i[read create control], grant: { admin: :all }
          resource :instances, actions: %i[read create update delete control claim], grant: { admin: :all }
          # `rollback` is an OPERATOR recovery verb, deliberately not granted to
          # system_worker: repointing current_version is a human decision made
          # after a bad publish, not something a reconcile tick should do.
          resource :modules, actions: %i[read create update delete rollback],
                   grant: { admin: :all, system_worker: %i[read update] }
          resource :networks, actions: %i[read create update delete], grant: { admin: :all }
          resource :node_instances, actions: %i[read create update delete manage],
                   grant: { admin: %i[read manage], system_worker: :all }
          resource :nodes, actions: %i[read create update delete],
                   grant: { admin: :all, system_worker: %i[read update] }
          resource :package_modules, actions: %i[create view refresh],
                   grant: { admin: :all, system_worker: %i[create refresh] }
          resource :package_repositories, actions: %i[view create update delete sync manage_shared],
                   grant: { admin: :all, system_worker: %i[sync] }
          resource :packages, actions: %i[search view], grant: { admin: :all }
          resource :peers, actions: %i[read invite manage activate execute], grant: { admin: :all }
          resource :platforms, actions: %i[read create update delete], grant: { admin: :all }
          resource :providers, actions: %i[read create update delete test], grant: { admin: :all }
          resource :puppet, actions: %i[read create update delete], grant: { admin: :all }
          resource :regions, actions: %i[read create update delete], grant: { admin: :all }
          resource :scripts, actions: %i[read create update delete], grant: { admin: :all }
          resource :service_offerings, actions: %i[read manage], grant: { admin: :all }
          resource :service_subscriptions, actions: %i[read subscribe cancel], grant: { admin: :all }
          resource :templates, actions: %i[read create update delete], grant: { admin: :all }
          resource :unclaimed_devices, actions: %i[read discard],
                   grant: { admin: :all, system_worker: %i[discard] }
          resource :volumes, actions: %i[read create update delete snapshot manage],
                   grant: { admin: %i[read create update delete snapshot], system_worker: %i[read create update delete manage] }

          # Worker-only task queue (distinct principal from operator infra_tasks).
          resource :tasks, actions: %i[read create manage execute], grant: { system_worker: :all }

          # ACME DNS provider credentials + DNS record CRUD (acme seed).
          resource :acme_dns, actions: %i[read manage], grant: { admin: :all }
          resource :dns, actions: %i[read manage], grant: { admin: :all }

          # Per-NodeInstance Claude Code CLI credential (claude-tmux module).
          resource :node_instance_credentials, actions: %i[read manage], grant: { admin: :all }

          # Storage assignments (storage seed).
          # admin -> all; manager -> assignments {read,create,update,assign,rotate_credential}
          # (NOT delete); member -> assignments read.
          resource :"storage.assignments",
                   actions: %i[read create update delete assign rotate_credential],
                   grant: {
                     admin: :all,
                     manager: %i[read create update assign rotate_credential],
                     member: %i[read]
                   }

          # ---------------------------------------------------------------
          # SDWAN — user's prefix rule: system.sdwan.* (tables are system_sdwan_*).
          # 4-segment names => permission escape hatch. operator CRUD -> admin;
          # sidecar/service ingest -> system_worker (machine credential, not admin).
          # ---------------------------------------------------------------
          permission "system.sdwan.networks.read", "View SDWAN overlay networks",
                     grant: { admin: true }
          permission "system.sdwan.networks.manage", "Create, update, and delete SDWAN networks",
                     grant: { admin: true }
          permission "system.sdwan.peers.read", "View SDWAN peers and compiled topology",
                     grant: { admin: true }
          permission "system.sdwan.peers.manage", "Attach, detach, and update SDWAN peers",
                     grant: { admin: true }
          permission "system.sdwan.firewall.read", "View SDWAN firewall rules",
                     grant: { admin: true }
          permission "system.sdwan.firewall.manage", "Create, update, and delete SDWAN firewall rules",
                     grant: { admin: true }
          permission "system.sdwan.host_bridges.read", "View SDWAN host bridges",
                     grant: { admin: true }
          permission "system.sdwan.host_bridges.manage", "Create, activate, and release SDWAN host bridges",
                     grant: { admin: true }
          permission "system.sdwan.ipfix.read", "View SDWAN IPFIX collectors and flow samples",
                     grant: { admin: true }
          permission "system.sdwan.ipfix.manage", "Create and delete SDWAN IPFIX collectors",
                     grant: { admin: true }
          permission "system.sdwan.ipfix.ingest", "Ingest IPFIX flow-sample batches (sidecar/service token)",
                     grant: { system_worker: true }
          permission "system.sdwan.ovn.read", "View SDWAN OVN deployments, switches, ports, and ACLs",
                     grant: { admin: true }
          permission "system.sdwan.ovn.manage", "Create and delete SDWAN OVN deployments, switches, ports, and ACLs",
                     grant: { admin: true }
          permission "system.sdwan.port_mappings.read", "View SDWAN hub port mappings (DNAT)",
                     grant: { admin: true }
          permission "system.sdwan.port_mappings.manage", "Create, update, and delete SDWAN port mappings",
                     grant: { admin: true }
          permission "system.sdwan.route_policies.read", "View and compile SDWAN route policies",
                     grant: { admin: true }
          permission "system.sdwan.route_policies.manage", "Create, update, and delete SDWAN route policies",
                     grant: { admin: true }
          permission "system.sdwan.routing.read", "View SDWAN routing state (subnet advertisements, BGP sessions)",
                     grant: { admin: true }
          permission "system.sdwan.routing.manage", "Manage SDWAN routing (LAN subnets, routing mode, AS number)",
                     grant: { admin: true }
          permission "system.sdwan.user_devices.manage", "Manage SDWAN user VPN devices and access grants",
                     grant: { admin: true }
          permission "system.sdwan.federation.read", "View SDWAN federation peers, scans, and audit log",
                     grant: { admin: true }
          permission "system.sdwan.federation.manage", "Propose, accept, revoke, and configure SDWAN federation peers",
                     grant: { admin: true }
          permission "system.sdwan.vips.read", "View SDWAN virtual IPs and assignments",
                     grant: { admin: true }
          permission "system.sdwan.vips.manage", "Create, update, delete, and fail over SDWAN virtual IPs",
                     grant: { admin: true }
        end

        # ---------------------------------------------------------------
        # system.module_builds.read (campaign 019f6084 inc2 — ModuleBuildBatch
        # read API). The permission itself is declared in core
        # server/config/permissions.rb's SYSTEM_PERMISSIONS hash, adjacent to
        # system.module_builds.dispatch (that's the existing precedent for
        # this permission name — .dispatch is worker/webhook-dispatched, so
        # it lives where the git-push webhook + AI tool gate it). A raw
        # SYSTEM_PERMISSIONS entry only reaches the system_worker role by
        # default; granting the operator-facing read surface to admin/manager
        # is extension policy, so it's registered here rather than inlined
        # into core's ROLES admin/manager lists.
        # ---------------------------------------------------------------
        # system.module_builds.cancel rides the same policy as .read and for
        # the same reason: it is an OPERATOR surface. Leaving it on the raw
        # SYSTEM_PERMISSIONS default (system_worker only) would reproduce the
        # exact defect this permission exists to fix — an operator watching a
        # runaway batch with no way to stop it.
        ::Permissions.register_role_permissions("admin", %w[system.module_builds.read system.module_builds.cancel])
        ::Permissions.register_role_permissions("manager", %w[system.module_builds.read system.module_builds.cancel])

        # ---------------------------------------------------------------
        # Operator-facing gap closure (improvement 019f6479). These names are
        # all declared in core server/config/permissions.rb's SYSTEM_PERMISSIONS
        # hash (disk-image publication / CI worker / CI runner lease block), but
        # a raw SYSTEM_PERMISSIONS entry only reaches system_worker by default —
        # same reason system.module_builds.read is registered here rather than
        # inlined into core's ROLES. Confirmed operator-facing by grepping the
        # actual controllers/AI-tool gates (not just the permission name):
        #   CiWorkersController, DiskImageWebhooksController, and
        #   DiskImagePublicationsController#rollback all gate on
        #   require_permission(...) against current_user (operator auth), and
        #   SystemFleetTool::ACTION_PERMISSIONS maps the ci_runner_lease MCP
        #   actions (lease/release/list) to the same names for the chat/agent
        #   surface. Read -> admin + manager (list-only, and the serializers
        #   for both CiWorker and DiskImageWebhook deliberately never return
        #   token/secret plaintext — see their CRITICAL comments — so read
        #   access can't leak credential material). Create/delete/rotate/
        #   rollback/manage -> admin only, mirroring every other admin-only
        #   resource CRUD block above (architectures, instances, platforms,
        #   providers, ...) — manager doesn't get infra-mutation rights
        #   anywhere else in this file either.
        #
        #   Deliberately EXCLUDED from these role grants:
        #   system.platforms.publish_disk_image and
        #   system.module_builds.dispatch. The WorkerApi:: and
        #   DiskImageRegistryConfig controllers gate them on
        #   authorize_worker_permission! / @current_ci_worker.has_permission?
        #   — a CiWorker principal, not a User — so no OPERATOR endpoint
        #   checks either name against current_user.
        #
        #   That is a bound on explicit GRANTS, not on effective access, and
        #   it does NOT put the permission out of a User's reach.
        #   User#has_permission? short-circuits on system.admin
        #   (app/models/user.rb:138-144): it returns true for EVERY permission
        #   name before any exclusion here is consulted, so a system.admin
        #   holder satisfies both of these regardless of this list. Same
        #   mechanism, stated the same way, as SystemFleetTool's
        #   WORKER_ONLY_ACTIONS note.
        #
        #   Nor is the User-facing path hypothetical:
        #   Ai::Tools::DiskImageOperatorTool declares REQUIRED_PERMISSION =
        #   "system.platforms.publish_disk_image" and is registered live
        #   (platform_api_tool_registry.rb:358-360), where BaseTool.permitted?
        #   resolves it through User#has_permission?. Its provision_ci_worker
        #   action mints a CI-worker token carrying that very permission.
        #   So the exclusion bounds what a leaked NON-ADMIN token can reach —
        #   not what an admin can reach.
        # ---------------------------------------------------------------
        ::Permissions.register_role_permissions("admin", %w[
          system.ci_workers.read
          system.ci_workers.create
          system.ci_workers.delete
          system.ci_workers.rotate_token
          system.disk_image_webhooks.read
          system.disk_image_webhooks.create
          system.disk_image_webhooks.delete
          system.disk_image_webhooks.rotate_secret
          system.platforms.rollback_disk_image
          system.platforms.manage_disk_image_policy
          system.ci_runner_leases.read
          system.ci_runner_leases.create
          system.ci_runner_leases.update
        ])
        ::Permissions.register_role_permissions("manager", %w[
          system.ci_workers.read
          system.disk_image_webhooks.read
          system.ci_runner_leases.read
        ])
      rescue StandardError => e
        Rails.logger.warn "[PowernodeSystem] Could not register extension permissions: #{e.message}"
      end
    end

    # Register this extension's audit ACTIONS via the AuditActions seam (the
    # audit twin of register_catalog). The system.node_instance.* lifecycle
    # tokens were relocated out of core's AuditActions concern — they are emitted
    # only here, by the System::NodeInstance lifecycle-auditable decoration on
    # every AASM transition (app/models/concerns/system/lifecycle_auditable.rb).
    # AuditLog#action validates against the dynamic AuditActions.all_actions
    # union, so once this runs at boot those audit rows validate.
    initializer "powernode_system.register_audit_actions", after: :load_config_initializers do
      config.after_initialize do
        next unless defined?(::AuditActions) && ::AuditActions.respond_to?(:register_actions)

        # Single source of truth: the fully-qualified tokens are defined beside
        # each emitter (System::LifecycleAuditable, System::InternalCaService),
        # so the registered set can never drift from what they actually emit.
        ::AuditActions.register_actions(
          "system",
          ::System::LifecycleAuditable::AUDITED_ACTIONS +
            ::System::InternalCaService::AUDITED_ACTIONS
        )
      rescue StandardError => e
        Rails.logger.warn "[PowernodeSystem] Could not register audit actions: #{e.message}"
      end
    end

    # Register this extension's skill-routing domain with the parent's
    # ConciergeRouter. Used as the fallback when a skill's metadata
    # doesn't explicitly declare `domain`, and as the affinity signal
    # when multiple chat-facing agents are bound to one skill.
    initializer "powernode_system.register_routing_domain", after: :load_config_initializers do
      config.after_initialize do
        next unless defined?(::Ai::Skill) && ::Ai::Skill.respond_to?(:register_domain)

        ::Ai::Skill.register_domain(
          name: "system",
          executor_namespace_pattern: /\ASystem::/
        )
      rescue StandardError => e
        Rails.logger.warn "[PowernodeSystem] Could not register routing domain: #{e.message}"
      end
    end

    # IMP-8880bc817ea3 — OVN container-fabric hook. Core fires :created /
    # :removed for every Devops::DockerContainer record from its
    # ContainerLifecycleRegistry seam (no-op in core mode); this registers the
    # SDWAN switch-port allocator so labeled containers on heavyweight hosts
    # get their OVN logical switch port at creation and lose it at removal.
    # `to_prepare` (not `after_initialize`): the registry is an autoloaded
    # core service, so a dev-mode reload replaces the constant and drops its
    # handler map — to_prepare re-registers after every reload (and still runs
    # once at boot elsewhere). Registration is replace-by-name, so re-running
    # is idempotent. The allocator constant resolves lazily at call time for
    # the same reload-safety reason.
    initializer "powernode_system.container_lifecycle_hooks", after: :load_config_initializers do
      config.to_prepare do
        next unless defined?(::Devops::ContainerLifecycleRegistry)

        ::Devops::ContainerLifecycleRegistry.register(:sdwan_switch_port) do |event, container|
          ::Sdwan::ContainerSwitchPortAllocator.call(event, container)
        end
      rescue StandardError => e
        Rails.logger.warn "[PowernodeSystem] Could not register container lifecycle hook: #{e.message}"
      end
    end

    # Register all action_categories the system extension owns with the core
    # AutonomyGate registry (Phase 5 — Action Category Registry).
    #
    # IMP-097a267b50b7: what an unregistered category actually breaks. NOT
    # seed validation — `Ai::InterventionPolicy` validates action_category for
    # presence only, never against the registry, so an unregistered category
    # seeds, resolves and gates perfectly well. The one consumer that fails is
    # operator-facing: System::AutonomyActions#update (the bulk PATCH
    # /api/v1/system/autonomy behind the Autonomy modal) rejects any update
    # whose category is not `category_registered?`. A seeded row for an
    # unregistered category is therefore VISIBLE in the modal — the by_action
    # pivot reads policy rows, not this registry — and un-saveable. Five
    # sensor-gated categories shipped in exactly that state.
    #
    # INVARIANT, enforced by
    # spec/lib/powernode_system/autonomy_categories_registration_spec.rb:
    # every action_category in DecisionEngine::SIGNAL_BINDINGS must appear
    # below. Both of the engine's `gate_action!` call sites pass
    # `binding[:action_category]`, so that constant is the complete set of
    # categories the sensor pipeline can put in front of an operator. Adding a
    # signal binding without its category here reds that spec.
    #
    # IMP-8d444c6437a3: this used to run in `config.after_initialize`, which
    # fires exactly once at boot. `Ai::InterventionPolicy.@category_registry`
    # is a class-level ivar set in the class body (`STATIC_CATEGORIES`) —
    # every Zeitwerk unload/reload cycle (any dev-mode code reload) redefines
    # the class and wipes that ivar back to core's static list, dropping
    # every category this block ever registered until the process restarts.
    # `config.to_prepare` fires at boot AND after every such reload (same
    # mechanism already used for the decorators load above), so re-running
    # this block there keeps the registry populated across reloads without
    # touching core. `register_categories!` is idempotent (backed by a Set),
    # so re-registering on each prepare cycle is harmless.
    initializer "powernode_system.autonomy_categories", after: :load_config_initializers do
      config.to_prepare do
        next unless defined?(::Ai::InterventionPolicy)

        categories = []

        # Fleet Autonomy domain (existing)
        categories.concat(%w[
          system.cert_rotate system.cert_revoke system.acme_cert_rotate
          system.module_assign system.module_promote_to_live
          system.instance_reboot system.instance_reprovision system.instance_terminate
          system.fleet_rolling_upgrade system.region_expansion system.capacity_resize
          system.observation
          system.capability_gap_review
          system.gitops_drift_remediate system.storage_assignment_reconcile
          system.template_closure_apply
          system.node_boot_image_drift system.package_repository.sync
          system.package_module.create system.package_module.refresh
          system.architecture.propose system.architecture.create
          system.architecture.update system.architecture.delete
        ])

        # SDWAN Manager domain
        categories.concat(%w[
          system.sdwan_peer_remediate system.sdwan_key_rotate system.sdwan_failover
          system.sdwan_user_device_revoke system.sdwan_bgp_session_remediate
          system.sdwan_vip_failover
          system.sdwan_credential_refresh
          sdwan.network_create sdwan.network_update sdwan.network_delete
          sdwan.peer_create sdwan.peer_update sdwan.peer_delete
          sdwan.firewall_rule_create sdwan.firewall_rule_update sdwan.firewall_rule_delete
          sdwan.virtual_ip_create sdwan.virtual_ip_update sdwan.virtual_ip_delete
          sdwan.route_policy_create sdwan.route_policy_update sdwan.route_policy_delete
          sdwan.port_mapping_create sdwan.port_mapping_update sdwan.port_mapping_delete
          sdwan.access_grant_create sdwan.access_grant_reactivate
          sdwan.access_grant_revoke sdwan.access_grant_delete
          sdwan.user_device_create
          sdwan.federation_peer_propose sdwan.federation_peer_accept sdwan.federation_peer_revoke
          sdwan.host_bridge_create sdwan.host_bridge_update sdwan.host_bridge_delete
          sdwan.ovn_deployment_create sdwan.ovn_deployment_delete
          sdwan.ovn_logical_switch_create sdwan.ovn_logical_switch_update sdwan.ovn_logical_switch_delete
          sdwan.ovn_logical_switch_port_create sdwan.ovn_logical_switch_port_update
          sdwan.ovn_logical_switch_port_delete
          sdwan.ovn_acl_create sdwan.ovn_acl_delete
          sdwan.ipfix_collector_create sdwan.ipfix_collector_delete
          system.sdwan_service_health_investigate
          system.sdwan_ovn_deployment_investigate
          system.sdwan_bgp_observation_investigate
        ])

        # Phase 3 (Federation & Multi-Site) — SDWAN-first federation actions.
        # `system.federation_peer_remediate` is the autonomy action the
        # DecisionEngine gates off the FederationPeerLivenessSensor (routed
        # through FleetAutonomyService#gate_action!) — registering it here is
        # REQUIRED or an operator cannot retune the SDWAN Manager policy row
        # for it (see the header: the seed itself saves fine; the bulk PATCH
        # endpoint is what refuses). The three compose categories
        # (federation_compose / multi_tenant_isolation / service_discovery_compose)
        # are approval-gated, operator/Concierge-driven composer skills (bound
        # to the System Topology Designer assistant, not autonomy reconcilers);
        # they're registered so any operator-authored intervention policy for
        # them validates uniformly.
        categories.concat(%w[
          system.federation_peer_remediate
          system.sdwan_federation_compose
          system.multi_tenant_isolation
          system.service_discovery_compose
        ])

        # GitOps Reconciler domain — operator-initiated gitops actions, seeded
        # by db/seeds/system_gitops_reconciler_agent.rb. (The AUTONOMOUS
        # system.gitops_drift_remediate lives on Fleet Autonomy above, because
        # GitopsDriftSensor runs in FleetAutonomyService::SENSORS.)
        categories.concat(%w[
          system.gitops_apply_proposal system.gitops_register_repository
          system.gitops_sync_repository
        ])

        # CVE Responder domain
        categories.concat(%w[
          system.cve_remediate system.cve_sbom_ingest
          system.cve_exposure_scan system.cve_auto_remediate
          system.module_critical_upgrade_ready
        ])

        # Disk Image Manager domain
        categories.concat(%w[
          system.disk_image_publication_promote system.disk_image_publication_rollback
          system.disk_image_retention_update system.disk_image_webhook_trigger
          system.disk_image_webhook_revoke system.disk_image_webhook_rotate_secret
          system.disk_image_publication_investigate
        ])

        # Runtime Manager domain.
        #
        # `system.runtime_docker_tls_rotate` is deliberately ABSENT and must not
        # be re-added. The 2026-05-19 doc-accuracy audit deleted its seeded
        # policy because nothing executes it — operators rotate Docker daemon
        # TLS through the broader `system.cert_rotate` flow (see
        # db/seeds/system_runtime_manager_agent.rb) — but the registration
        # survived here for three months.
        #
        # There is no executor class for it either, as of IMP-75f851ce0bf0.
        # One used to exist — a deliberate raising stub
        # (System::Executors::Runtime::RotateDockerTls, IMP-967901b9d2e1) that
        # refused rather than keep reporting `rotated: true` without touching
        # TLS material. Raising was the right fix while the category was still
        # registered and the class therefore dispatchable; once this
        # registration was removed nothing could reach it, and a raising stub
        # no dispatcher can name is not a safety net — it is a name that reads
        # as an implementation to the next person who greps for it. This
        # comment used to have to say so explicitly, which is the clearest
        # evidence the ambiguity was real.
        #
        # Re-register only alongside a real implementation AND a seeded policy
        # row. Note the two SIBLING stubs from the same commit
        # (Runtime::DrainK3sNode, Runtime::UpgradeK3sRuntime) are deliberately
        # still present and still raising: their categories
        # (system.runtime_k8s_node_drain, system.runtime_k8s_runtime_upgrade)
        # ARE registered below, so they remain dispatchable and the raise is
        # still doing its job there.
        #
        # Three further names are ABSENT for a different reason (IMP-eb60db901f5f)
        # — they were never capabilities, only second SPELLINGS of the three
        # seeded ones directly below:
        #
        #   system.runtime_docker_host_provision    -> system.runtime_docker_provision
        #   system.runtime_docker_host_decommission -> system.runtime_docker_decommission
        #   system.runtime_k8s_cluster_create       -> system.runtime_k8s_cluster_bootstrap
        #
        # The 2026-05-10 five-agent split (d579be93) added this whole block and
        # wrote both spellings of each action into it: the seeded policy name AND
        # the executor CLASS name. `git log -S` over every path finds each of the
        # three in that commit and nowhere else — never seeded, never gated,
        # never executed — and live powernode_production held zero policy /
        # deferred-operation / remediation-outcome rows for them when they were
        # removed on 2026-08-14.
        #
        # The executor classes they were spelled after are REAL and are not
        # evidence to the contrary: app/services/system/executors/runtime/
        # {provision_docker_host,decommission_docker_host,bootstrap_k3s_cluster}.rb
        # are working implementations. An executor declares no action_category —
        # the binding is the `executor_class:` string a gate site passes — and
        # today NO gate site names any of those three (the only runtime executor
        # with a call site is DecommissionK3sCluster, from core's
        # Api::V1::Devops::Kubernetes::ClustersController#destroy under
        # system.runtime_k8s_cluster_decommission). So the classes are evidence
        # of the vocabulary, never of a backing for the removed names. When a
        # Docker/K3s surface does get gated — e.g.
        # Devops::Docker::HostsController#create, which is permission-gated
        # (`devops.docker.manage`) but NOT autonomy-gated today — cite the
        # SEEDED spelling above; do not re-add a second one.
        #
        # Registration is not cosmetic: it is
        # the gate System::AutonomyActions#update passes, so a
        # registered-but-unseeded category is one the bulk
        # PATCH /api/v1/system/autonomy will `find_or_initialize_by` a policy
        # row for, giving an operator a durable control over an action nothing
        # can execute. Pinned by
        # spec/lib/powernode_system/autonomy_categories_registration_spec.rb and,
        # through the endpoint itself, by
        # spec/controllers/api/v1/system/autonomy_controller_spec.rb.
        categories.concat(%w[
          system.runtime_docker_provision system.runtime_docker_decommission
          system.runtime_k8s_cluster_bootstrap system.runtime_k8s_cluster_decommission
          system.runtime_k8s_node_join system.runtime_k8s_node_drain
          system.runtime_k8s_runtime_upgrade
        ])

        # Instance pools (slice 7)
        categories.concat(%w[
          system.instance_pool_create system.instance_pool_update system.instance_pool_delete
          system.instance_pool_replenish system.instance_pool_drain system.instance_pool_acquire
        ])

        # System::Task commands (manual operator scope)
        %w[start stop restart terminate reboot provision deprovision
           associate_public_ip disassociate_public_ip
           create_volume delete_volume attach_volume detach_volume
           create_snapshot delete_snapshot restore_snapshot
           create_network delete_network sync sync_modules apply_config
           build_module commit_module ssh_command backup restore custom].each do |cmd|
          categories << "system.task.#{cmd}"
        end

        ::Ai::InterventionPolicy.register_categories!(categories)
      rescue StandardError => e
        Rails.logger.warn "[PowernodeSystem] Could not register autonomy categories: #{e.message}"
      end
    end
  end
end
