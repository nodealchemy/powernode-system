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
        decorators
      ].each do |subdir|
        path = engine_root.join("app", subdir)
        app.config.autoload_paths << path.to_s if path.exist?
      end

      # `lib/` for pure helpers that don't fit the app/ Zeitwerk conventions
      # (e.g., System::CveOps::VersionMatcher — a stateless table-driven
      # version-range matcher). Comprehensive stabilization sweep P4.
      lib_path = engine_root.join("lib")
      app.config.autoload_paths << lib_path.to_s if lib_path.exist?
    end

    # Load decorators that extend core models (none expected initially).
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
          features_module: defined?(PowernodeSystem::Features) ? PowernodeSystem::Features : nil
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

    # Register all action_categories the system extension owns with the core
    # AutonomyGate registry. Without this, InterventionPolicy seeds for these
    # categories would fail validation (Phase 5 — Action Category Registry).
    initializer "powernode_system.autonomy_categories", after: :load_config_initializers do
      config.after_initialize do
        next unless defined?(::Ai::InterventionPolicy)

        categories = []

        # Fleet Autonomy domain (existing)
        categories.concat(%w[
          system.cert_rotate system.cert_revoke
          system.module_assign system.module_promote_to_live
          system.instance_reboot system.instance_reprovision system.instance_terminate
          system.fleet_rolling_upgrade system.region_expansion system.capacity_resize
          system.observation
        ])

        # SDWAN Manager domain
        categories.concat(%w[
          system.sdwan_peer_remediate system.sdwan_key_rotate system.sdwan_failover
          system.sdwan_user_device_revoke system.sdwan_bgp_session_remediate
          system.sdwan_vip_failover system.sdwan_route_policy_audit
          sdwan.network_create sdwan.network_update sdwan.network_delete
          sdwan.peer_create sdwan.peer_update sdwan.peer_delete
          sdwan.firewall_rule_create sdwan.firewall_rule_update sdwan.firewall_rule_delete
          sdwan.virtual_ip_create sdwan.virtual_ip_update sdwan.virtual_ip_delete
          sdwan.route_policy_create sdwan.route_policy_update sdwan.route_policy_delete
          sdwan.port_mapping_create sdwan.port_mapping_update sdwan.port_mapping_delete
          sdwan.access_grant_create sdwan.access_grant_revoke
          sdwan.user_device_create
          sdwan.federation_peer_propose sdwan.federation_peer_accept sdwan.federation_peer_revoke
        ])

        # CVE Responder domain
        categories.concat(%w[
          system.cve_remediate system.cve_sbom_ingest
          system.cve_exposure_scan system.cve_auto_remediate
        ])

        # Disk Image Manager domain
        categories.concat(%w[
          system.disk_image_publication_promote system.disk_image_publication_rollback
          system.disk_image_retention_update system.disk_image_webhook_trigger
        ])

        # Runtime Manager domain
        categories.concat(%w[
          system.runtime_docker_provision system.runtime_docker_decommission
          system.runtime_docker_tls_rotate
          system.runtime_k8s_cluster_bootstrap system.runtime_k8s_cluster_decommission
          system.runtime_k8s_node_join system.runtime_k8s_node_drain
          system.runtime_k8s_runtime_upgrade
          system.runtime_docker_host_provision system.runtime_docker_host_decommission
          system.runtime_k8s_cluster_create
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
