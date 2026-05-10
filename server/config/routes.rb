# frozen_string_literal: true

# System extension routes — loaded automatically by Rails::Engine.
# Three co-mounted sub-APIs that share controllers/serializers:
#   /api/v1/system/*            — operator-facing CRUD (User-JWT auth via ApplicationController)
#   /api/v1/system/worker_api/* — Worker-token auth (X-Worker-Token or Bearer)
#   /api/v1/system/node_api/*   — Instance-JWT auth (X-Instance-Token or Bearer; type: "instance")
Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      namespace :system do
        # === Operator-facing CRUD ===
        # Public-facing tasks API: list/show/create/cancel only.
        # State mutations (start/complete/fail/abort) are worker-only via
        # /api/v1/system/worker_api/tasks to keep AASM's single source
        # of truth honest. Cancel is the one user-initiated state transition
        # an operator can legitimately make on a pending task.
        resources :tasks, only: %i[index show create] do
          member { post :cancel }
        end

        # NodeInstancesController#set_node uses params[:node_id], so node_instances
        # MUST be nested under nodes — every frontend caller already uses
        # /api/v1/system/nodes/:node_id/node_instances/.... A flat
        # `resources :node_instances` would 404 because set_node always runs.
        resources :nodes do
          resources :node_instances do
            member do
              post :start
              post :stop
              post :reboot
              post :terminate
              post :associate_public_ip
              post :disassociate_public_ip
            end
          end
        end
        resources :node_platforms, only: %i[index show create update destroy] do
          member do
            get :disk_image
            # Operator-driven rollback to a prior published publication.
            # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 3).
            post :rollback_disk_image, to: "disk_image_publications#rollback"
          end
          # Per-platform publication history list. Powers DiskImageHistoryTab.
          resources :disk_image_publications,
                    only: %i[index show],
                    controller: "disk_image_publications"
        end

        # Per-account CRUD for HMAC webhook secrets + CI workers.
        # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 3).
        resources :disk_image_webhooks, only: %i[index show create destroy] do
          member { post :rotate_secret }
        end
        resources :ci_workers, only: %i[index show create destroy] do
          member { post :rotate_token }
        end

        # Physical-device claim queue (operator-facing). See plan
        # wondrous-yawning-anchor.md — devices polling /node_api/claim
        # surface here for the operator to bind to a NodeInstance.
        resources :unclaimed_devices, only: %i[index show destroy] do
          member { post :claim }
        end

        # node_instances now nested under :nodes (see above) — flat resource removed.
        resources :node_modules do
          member do
            get :dependencies
            # Honeypot canary marker (Track F-6).
            post :mark_canary
            post :unmark_canary
            # Manifest YAML import — parses a manifest.yaml payload onto
            # this module. Used by the operator UI's "import" button and
            # by the Gitea webhook ingest path.
            post :import_manifest
          end
          resources :module_puppet_assignments, only: %i[index create]
        end
        resources :node_module_categories
        resources :module_dependencies
        resources :module_puppet_assignments, only: %i[show update destroy]

        # Per-(node, module) toggle endpoints. The assignment row carries
        # `enabled`, `priority`, `config` — toggling enabled lets operators
        # disable a module on specific nodes without losing the join state.
        # Legacy parity for powernode-server's node_module_subscription.
        # Comprehensive stabilization sweep P2.2.
        resources :node_module_assignments, only: %i[show] do
          member do
            post :enable
            post :disable
          end
        end

        # Slice 7 — instance pools.
        resources :instance_pools do
          member do
            post :replenish
            post :drain
            post :recycle_stale
          end
        end

        resources :node_templates do
          member do
            get :export
            # Returns NodeModule rows assigned via TemplateModule join,
            # priority-ordered. TemplateDetailModal calls this on open.
            get :modules
          end
          collection do
            # The action lives on this same NodeTemplatesController. Earlier
            # versions pointed at a non-existent `templates` controller,
            # which 500'd on every preview request — confirmed by the
            # rspec coverage in node_templates_compose_preview_spec.rb.
            post :compose_preview
          end
        end
        resources :node_architectures
        # node_platforms moved to top of namespace + extended with
        # the disk_image member action (claim-flow operator download).
        resources :node_scripts
        resources :node_mount_points

        # Provider catalog. Regions/availability_zones/instance_types are
        # nested under :providers because the controllers' before_actions
        # read params[:provider_id] (and AZ also params[:region_id]) — flat
        # declarations 404 every request via #set_provider rescue.
        # See docs/system/audit_2026-04-30.md S1.
        resources :providers do
          resources :regions, controller: "provider_regions" do
            resources :availability_zones, controller: "provider_availability_zones"
          end
          resources :instance_types, controller: "provider_instance_types"
        end
        resources :provider_connections do
          member do
            post :test
            post :sync_catalog
          end
        end

        # M2 Self-Serve Hardening (BYOC) — per-account encrypted cloud
        # credentials. ProviderConnection is the deployed/operational
        # connection record; ProviderCredential is the bring-your-own
        # cloud-cred bag the FirstRunWizard captures from the operator.
        resources :provider_credentials, only: %i[index create destroy] do
          collection { post :test }
        end
        # Cross-provider/global instance type listing. The frontend calls
        # /system/provider_instance_types when no provider filter is set
        # and /system/provider_instance_types/for_region for region lookup.
        resources :provider_instance_types, only: %i[index] do
          collection { get :for_region }
        end
        resources :provider_networks
        resources :provider_network_subnets
        resources :provider_volumes do
          member do
            post :attach
            post :detach
            post :snapshot
          end
        end

        resources :puppet_modules do
          resources :puppet_resources do
            member { get :puppet_dsl }
          end
        end

        # === NodeInstance-as-Agent peers (F-3) ===
        # Operator-side: list/show + activate/deactivate + delegate task.
        # Comprehensive stabilization sweep P6.
        resources :node_instance_peers, only: %i[index show] do
          collection do
            # Lightweight prefix-search for operators inspecting peers directly
            get :searchable
            # Peer-mirror Ai::Agents in MentionMember shape for the workspace
            # mention picker (parent platform's AgentConversationComponent).
            # Phase 10.7.
            get :mentionable
          end
          member do
            post :activate
            post :deactivate
            post :execute
          end
        end

        # === GitOps reconciliation (M-D2-3) ===
        resources :gitops_repositories, only: %i[index show create update destroy] do
          member do
            post :sync_now
            get :sync_runs
          end
        end

        # === SDWAN overlay (Slice 1 of we-are-continuing-development-spicy-bear.md) ===
        # Operator-side: networks CRUD + nested peer management + topology preview.
        # Node-side endpoints (config pull + status report) live in the node_api
        # block below as `config/sdwan` and `status/sdwan`.
        namespace :sdwan do
          resources :networks do
            member do
              get :topology
            end
            resources :peers
            # Slice 2: declarative network firewall.
            resources :firewall_rules
            # Slice 4: user VPN clients.
            resources :access_grants do
              member { post :revoke }
              resources :user_devices, only: %i[index show create destroy] do
                member { post :revoke }
              end
            end
            # Slice 9b: virtual IPs.
            resources :virtual_ips do
              member { post :failover }
            end
            # Slice 7b: hub DNAT port mappings.
            resources :port_mappings
          end
          # Anonymous bootstrap endpoint — token IS the auth. Fetched
          # exactly once per device; subsequent attempts 410 Gone.
          get "bootstrap/:token", to: "bootstrap#show",
              constraints: { token: /[^\/]+/ }

          # Slice 6: federation scaffold (data-only in v1).
          resources :federation_peers do
            member { post :revoke }
          end

          # Slice 9c: account-level routing/iBGP control plane.
          # Routing controller owns AS allocation, mode introspection,
          # and the live BGP-session matrix.
          get  "routing",         to: "routing#show"
          post "routing/bgp",     to: "routing#allocate_as"
          get  "routing/sessions", to: "routing#sessions"

          # Slice 9e: route policies — account-scoped CRUD with a
          # per-peer compile endpoint for "what does this look like in
          # FRR?" debugging.
          resources :route_policies do
            member { get :compile }
          end
        end

        # === Metrics (operator-facing; aggregated counters) ===
        # Action is `#index` because `dispatch` collides with
        # ActionController::Metal#dispatch.
        get "metrics/dispatch", to: "metrics#index"

        # === System Concierge bootstrap (Phase 10.3) ===
        # Returns or creates the operator's active Concierge conversation
        # against the System Concierge agent. Subsequent message exchange
        # uses the standard /api/v1/ai/conversations/:id/messages endpoint.
        post "concierge/start", to: "concierge#start"

        # === Webhooks (no operator JWT required; HMAC-validated per-resource) ===
        namespace :webhooks do
          post "gitea/module", to: "gitea_module#handle"
          # SBOM ingestion from module CI builds. Same per-module HMAC secret
          # as gitea/module above. Phase 10.2 of stabilization sweep.
          post "gitea/module_sbom", to: "module_sbom#create"
          # Disk-image build notifications from CI runners — the :webhook_id
          # segment scopes the request to a specific account's
          # DiskImageWebhook (account derived from webhook.account_id).
          # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 2).
          post "disk_image/built/:webhook_id", to: "disk_image_built#handle"
        end

        # === Netboot (operator-driven iPXE script generation) ===
        get "netboot/:instance_id/script.ipxe", to: "netboot#script", defaults: { format: "txt" }

        # === Fleet observability + attribution (Golden Eclipse M7 + M-FE-3) ===
        post "fleet/signals",                to: "fleet#signals"
        post "fleet/attribute_failure",      to: "fleet#attribute_failure"
        post "fleet/attribution_feedback",   to: "fleet#attribution_feedback"
        # Boot replay timeline — comprehensive stabilization sweep P7.1.
        get  "fleet/boot_replay",            to: "fleet#boot_replay"

        # === Module Marketplace (M-FE-2 — comprehensive sweep P7.2) ===
        # Browse-side catalog. Lists modules with trust tier badges and
        # version metadata. Submission/review pipeline is out of scope.
        resources :marketplace, only: %i[index show], controller: "marketplace"

        # === Worker API (token-authenticated workers) ===
        namespace :worker_api do
          # Async module publication processor — long-pole work the
          # webhook receiver dispatches to the worker so Gitea acks fast.
          post "module_publications/process",
               to: "module_publications#process_publication"

          # UnclaimedDevice reaper — daily cron from System::ExpireUnclaimedDevicesJob.
          post "unclaimed_devices/expire",
               to: "unclaimed_devices#expire"

          # Disk-image publication flow (Phase 2 — Chunk 2).
          # Plan: docs/plans/wondrous-yawning-anchor.md.
          # process: long-pole OCI pull + cosign verify + storage upload, called by worker job
          # initiate/finalize: cloud-direct-upload alternate path (S3/Azure/GCS only)
          # sweep_retention: per-platform retire/purge, called by daily reaper job
          resources :disk_image_publications, only: [] do
            collection do
              post :process,         action: :process_publication
              post :initiate
              post :finalize
              post :sweep_retention
            end
          end

          resources :tasks, only: %i[index show] do
            collection do
              get :pending
            end
            member do
              post :execute
              post :start
              put :progress
              post :complete
              post :fail
              post :events
            end
          end
          resources :nodes, only: %i[index show update] do
            member do
              put :ssh_keys
            end
          end
          resources :node_instances do
            member do
              post :start
              post :stop
              post :reboot
              post :sync
              post :maintenance
            end
          end
          resources :modules, only: %i[index show] do
            member do
              get :download
              post :upload
              get :versions
              post :rollback
            end
            collection do
              get "for_node/:node_id", action: :for_node
            end
          end
          resources :volumes do
            member do
              post :attach
              post :detach
              post :check
            end
            collection do
              get "for_instance/:instance_id", action: :for_instance
            end
          end

          # Fleet autonomy reconcile tick — invoked by SystemFleetReconcileJob
          # on a cron schedule. Runs sensors → DecisionEngine → LearningExtractor.
          post "fleet/reconcile", to: "fleet#reconcile"

          # CVE feed ingest tick — invoked hourly by SystemCveFeedJob.
          post "cve/ingest", to: "cve#ingest"

          # Fleet event ingestion (agent-side telemetry batches).
          post "fleet/events", to: "fleet#events"

          # Nightly retention sweep — drops aged FleetEvents.
          post "fleet/retention_sweep", to: "fleet#retention_sweep"

          # Cloud-state reconciliation — invoked hourly by SystemCloudSyncJob.
          # Iterates every account's enabled provider connections and syncs
          # each region's instances via System::CloudSyncService.
          # Comprehensive stabilization sweep P2.1.
          post "cloud_sync/reconcile", to: "cloud_sync#reconcile"

          # GitOps reconcile tick — invoked by SystemGitopsSyncJob every 5
          # minutes. Iterates GitopsRepository rows due for sync, opens
          # Ai::AgentProposal for each diff. Comprehensive stabilization
          # sweep P5; Golden Eclipse M-D2-3.
          post "gitops/reconcile", to: "gitops#reconcile"

          # Slice 5 (deferred reaper) of the SDWAN plan — daily 90-day
          # audit retention sweep over revoked Sdwan::UserDevice rows.
          post "sdwan/reap_user_devices", to: "sdwan#reap_user_devices"
        end

        # === Node API (instance-token-authenticated running instances) ===
        namespace :node_api do
          # Physical-device claim polling — anonymous, used BEFORE the
          # device has a bootstrap token. Devices flashed from a generic
          # disk image poll here while waiting for an operator to bind
          # them to a NodeInstance via the Unclaimed Devices UI panel.
          # See docs/plans/wondrous-yawning-anchor.md.
          post :claim, to: "claim#create"

          # Enrollment — bootstrap-token-authenticated; pre-mTLS path used by
          # freshly-booted nodes presenting a single-use bootstrap token.
          post :enroll, to: "enrollment#create"
          # Cert rotation — instance-cert-authenticated; consumed by the
          # agent's CertRotator goroutine before NotAfter expiry.
          post "enroll/refresh", to: "enrollment_refresh#refresh"

          # Config + key material
          get :config, to: "config#show"
          get "config/authorized_keys", to: "config#authorized_keys"
          get "config/host_keys", to: "config#host_keys"
          get "config/network", to: "config#network"
          # Phase 3 — LUKS passphrase derivation for volume-setup CLI.
          get "config/luks/:partition_label", to: "luks#show",
              constraints: { partition_label: /[a-zA-Z0-9_.-]{1,32}/ }
          # SDWAN desired-state pull (the architectural pivot — the agent reads
          # per-peer config on each heartbeat tick instead of waiting for a
          # task-lease push). Slice 1.
          # NOTE: action is `show_config` (not `config`) because Rails
          # delegates `controller.config` → `controller.config.logger`
          # via AbstractController::Logger; an action named `config`
          # would shadow that delegate and trigger infinite recursion
          # the moment Rails tried to log anything during render.
          get "config/sdwan", to: "sdwan#show_config"

          # Status, heartbeat, and assigned tasks
          get :status, to: "status#show"
          post :status, to: "status#report"
          post "status/heartbeat", to: "status#heartbeat"
          # SDWAN actual-state report — the agent pushes observed peer
          # handshake state here on each heartbeat. Slice 1.
          post "status/sdwan", to: "sdwan#report"
          # Slice 9f — agent reports observed iBGP session state; platform
          # upserts Sdwan::BgpSession rows so the dashboard shows live data.
          post "status/bgp", to: "sdwan#report_bgp"
          get "status/tasks", to: "status#tasks"
          get "status/tasks/:id", to: "status#show_task"
          post "status/tasks/:id/acknowledge", to: "status#acknowledge_task"
          post "status/tasks/:id/complete", to: "status#complete_task"
          post "status/tasks/:id/fail", to: "status#fail_task"

          # Phase B — runtime daemon handshake (Docker today; K3s/kubeadm
          # via the same endpoint in Phase 2/3). Agent posts CSR + ready
          # signals here on the dockerd lifecycle. Single endpoint, three
          # phases ('wants_cert' | 'ready' | 'stopped') keyed by
          # `runtime` enum.
          post "runtime/handshake", to: "runtime#handshake"

          # Slice 10 — per-tick agent fetch for daemon.json overrides
          # (and forward-compat for k3s / kubeadm). Returns the merged
          # config from any dependant config-variety NodeModules of the
          # base runtime module.
          get "runtime/:runtime/config", to: "runtime#runtime_config", as: :runtime_config

          # Modules + mount points (read-only from instance perspective)
          resources :modules, only: %i[index show] do
            member do
              # Phase 1 — OCI manifest + download URL.
              get :download
              # Phase 2 — server-rendered rsync filter for commit CLI.
              get :rsync_spec
            end
            # Phase 4 — commit CLI uploads a new module version
            # tarball; the platform creates a NodeModuleVersion at
            # promotion_state: "built". Operators (or autonomy) then
            # promote through the canary→staging→blessed→live chain.
            resources :versions, only: %i[create], controller: "module_versions"
          end
          resources :mount_points, only: %i[index show]

          # Puppet manifests
          get "puppet/resources", to: "puppet#resources"
          get "puppet/modules", to: "puppet#modules"
          get "puppet/modules/:id", to: "puppet#show_module"
          get "puppet/manifest", to: "puppet#manifest"

          # File downloads (binary)
          get "files/modules/:id", to: "files#module_file"
          get "files/scripts/:id", to: "files#script_file"
          get "files/node_modules", to: "files#node_modules"
          get "files/node_scripts", to: "files#node_scripts"

          # NodeInstance-as-Agent peer endpoints (F-3)
          # Comprehensive stabilization sweep P6.
          post "peer/announce", to: "peer#announce"
          post "peer/execute_result", to: "peer#execute_result"

          # Fleet event ingestion — Phase 0 of agent stub plan. Lets
          # the on-node Go agent batch-emit FleetEvent rows scoped to
          # its current_instance + current_account.
          post "fleet/events", to: "fleet#events"
        end
      end
    end
  end
end
