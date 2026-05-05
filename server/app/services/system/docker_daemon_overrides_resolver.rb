# frozen_string_literal: true

module System
  # Slice 10 — resolves the merged daemon.json override JSON for a
  # NodeInstance running the docker-engine module.
  #
  # Walks dependant config-variety NodeModules of `docker-engine` that
  # are scoped to the given NodeInstance (or its parent Node), merges
  # their `config["daemon_overrides"]` payloads in ascending order of
  # `effective_priority` (higher overrides lower), and returns a hash
  # safe to ship to the agent.
  #
  # Two scoping levels are honored:
  #   1. node-scoped dependants  (config variety, node_id=node, no instance_id)
  #      → apply to every instance on the node
  #   2. instance-scoped dependants (config variety, node_instance_id=instance)
  #      → apply only to this instance, layer on top of node-scoped
  #
  # Security: keys the platform owns (TLS material + listen address)
  # are stripped from the merged result before returning. The agent
  # applies the same allow-list defensively at write time.
  #
  # Idempotent + read-only — never mutates module state. Safe to call
  # per-tick from the agent's reconcile loop.
  class DockerDaemonOverridesResolver
    PARENT_MODULE_NAME = "docker-engine"
    OVERRIDES_KEY = "daemon_overrides"

    # Keys the platform unconditionally manages — operator overrides for
    # any of these are silently dropped (with a warn log so operators
    # can investigate). The agent applies the same list defensively.
    BLOCKED_KEYS = %w[tls tlsverify tlscacert tlscert tlskey hosts].freeze

    # Returns the merged JSON-ready hash (NOT JSON-encoded) for the
    # given NodeInstance. Empty hash if no overrides apply or the
    # docker-engine module isn't assigned.
    def self.resolve(node_instance:)
      new(node_instance: node_instance).resolve
    end

    def initialize(node_instance:)
      @node_instance = node_instance
    end

    def resolve
      return {} unless docker_engine_assigned?

      base = {}
      dependants_in_priority_order.each do |mod|
        overrides = mod.config&.dig(OVERRIDES_KEY)
        next unless overrides.is_a?(Hash)

        base = deep_merge(base, overrides)
      end

      strip_blocked_keys!(base)
      base
    end

    private

    def docker_engine_assigned?
      ::System::NodeModuleAssignment
        .joins(:node_module)
        .where(node_id: @node_instance.node_id, enabled: true)
        .where(system_node_modules: { name: PARENT_MODULE_NAME })
        .exists?
    end

    def parent_module
      @parent_module ||= ::System::NodeModule.find_by(
        account_id: @node_instance.account_id,
        name: PARENT_MODULE_NAME
      )
    end

    def dependants_in_priority_order
      return ::System::NodeModule.none unless parent_module

      # Two-tier scoping: node-level, then instance-level. Lower
      # effective_priority first so higher-priority instance-level
      # children deep-merge on top.
      ::System::NodeModule
        .where(parent_module_id: parent_module.id, variety: "config", enabled: true)
        .where(
          "(node_id = ? AND node_instance_id IS NULL) OR node_instance_id = ?",
          @node_instance.node_id,
          @node_instance.id
        )
        .order(:priority)
    end

    # Recursive deep merge:
    #   - hashes: merge recursively (overlay wins on key conflict)
    #   - arrays: overlay REPLACES base (operators expecting union
    #     semantics for registry-mirrors should layer separate dependants
    #     rather than expecting array concat)
    #   - scalars: overlay wins
    def deep_merge(base, overlay)
      base.merge(overlay) do |_key, lhs, rhs|
        if lhs.is_a?(Hash) && rhs.is_a?(Hash)
          deep_merge(lhs, rhs)
        else
          rhs
        end
      end
    end

    def strip_blocked_keys!(merged)
      stripped = merged.keys & BLOCKED_KEYS
      return if stripped.empty?

      Rails.logger.warn(
        "[DockerDaemonOverridesResolver] dropped operator-supplied keys " \
        "(platform-managed): #{stripped.join(', ')} for node_instance=#{@node_instance.id}"
      )
      stripped.each { |k| merged.delete(k) }
    end
  end
end
