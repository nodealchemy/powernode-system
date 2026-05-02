# frozen_string_literal: true

module System
  module Honeypot
    # Marks NodeModules as honeypot canaries — modules that *look*
    # attractive (named "secrets-store", "production-keys", "admin-shell")
    # but should never be touched in normal operation. Any access triggers
    # a high-severity FleetEvent and routes through governance_scan.
    #
    # Reference: Golden Eclipse plan F-6 honeypot canary modules.
    #
    # The marker is stored under config["honeypot"] = { canary, lure_kind, marked_at }.
    # Using the existing JSONB column avoids a migration and keeps the
    # marker invisible to standard module list serializers (operators see
    # canary status only via the dedicated honeypot dashboard tile).
    class CanaryModuleService
      CONFIG_KEY = "honeypot"
      HONEYPOT_TAG = "honeypot:canary" # legacy alias kept for any external reference

      def self.mark!(node_module:, lure_kind: "credential_store")
        new.mark!(node_module: node_module, lure_kind: lure_kind)
      end

      def self.canary?(node_module:)
        return false unless node_module.respond_to?(:config)
        node_module.config&.dig(CONFIG_KEY, "canary") == true
      end

      def self.observe_access!(node_module:, source: "unknown", context: {})
        return unless canary?(node_module: node_module)

        ::System::Fleet::EventBroadcaster.emit!(
          account: node_module.account,
          kind: "system.honeypot_triggered",
          severity: :high,
          payload: {
            module_id: node_module.id,
            module_name: node_module.name,
            source: source,
            context: context
          },
          source: "honeypot",
          node_module_id: node_module.id
        )
      end

      def mark!(node_module:, lure_kind:)
        return false unless node_module.respond_to?(:config)

        config = (node_module.config || {}).deep_dup
        return true if config.dig(CONFIG_KEY, "canary") == true

        config[CONFIG_KEY] = {
          "canary" => true,
          "lure_kind" => lure_kind,
          "marked_at" => Time.current.iso8601
        }
        node_module.update!(config: config)
        true
      rescue StandardError => e
        Rails.logger.error("[CanaryModuleService] mark failed: #{e.message}")
        false
      end
    end
  end
end
