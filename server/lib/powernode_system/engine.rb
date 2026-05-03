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
  end
end
