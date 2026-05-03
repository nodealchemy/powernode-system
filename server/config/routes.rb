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

        resources :nodes
        resources :node_platforms, only: %i[index show create update destroy] do
          member { get :disk_image }
        end

        # Physical-device claim queue (operator-facing). See plan
        # wondrous-yawning-anchor.md — devices polling /node_api/claim
        # surface here for the operator to bind to a NodeInstance.
        resources :unclaimed_devices, only: %i[index show destroy] do
          member { post :claim }
        end

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

        resources :providers
        resources :provider_connections do
          member do
            post :test
            post :sync_catalog
          end
        end
        resources :provider_regions do
          resources :provider_availability_zones
        end
        resources :provider_instance_types
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

        # === Webhooks (no operator JWT required; HMAC-validated per-resource) ===
        namespace :webhooks do
          post "gitea/module", to: "gitea_module#handle"
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

          # Config + key material
          get :config, to: "config#show"
          get "config/authorized_keys", to: "config#authorized_keys"
          get "config/host_keys", to: "config#host_keys"
          get "config/network", to: "config#network"

          # Status, heartbeat, and assigned tasks
          get :status, to: "status#show"
          post :status, to: "status#report"
          post "status/heartbeat", to: "status#heartbeat"
          get "status/tasks", to: "status#tasks"
          post "status/tasks/:id/acknowledge", to: "status#acknowledge_task"
          post "status/tasks/:id/complete", to: "status#complete_task"
          post "status/tasks/:id/fail", to: "status#fail_task"

          # Modules + mount points (read-only from instance perspective)
          resources :modules, only: %i[index show]
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
        end
      end
    end
  end
end
