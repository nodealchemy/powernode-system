# frozen_string_literal: true

module System
  # Campaign 019f5885 inc10 — the single source of truth for which module-
  # build path is authoritative right now. Three positions:
  #
  #   "gitea"  (DEFAULT) — current behavior. Native module builds do
  #            NOTHING: System::ModuleBuildTriggerService no-ops, the fleet
  #            keeps consuming whatever Gitea's build-platform-modules.yaml
  #            publishes exactly as it always has. This is the fail-safe
  #            default — an operator must explicitly opt in.
  #
  #   "dual"   — Gitea stays authoritative (the fleet still consumes its
  #            `:<sha>` tag + current_version), but every push ALSO
  #            dispatches a shadow System::ModuleBuildBatch that builds the
  #            same modules natively, publishes to `:native-<sha>` tags with
  #            promote: false, and is structurally compared against the
  #            Gitea artifact by System::ModuleBuildParityService. Nothing
  #            the fleet reads ever changes in this mode.
  #
  #   "native" — the native path becomes authoritative (inc11 flips this on
  #            for good): a push dispatches a normal (non-shadow) batch that
  #            promotes on publish, same as today's manual/CVE dispatch via
  #            system_dispatch_module_build_batch.
  #
  # Read via SiteSetting so an operator can flip it without a deploy. Any
  # unrecognized/blank value falls back to "gitea" — fail-safe, never
  # fail-open into a build path nobody asked for.
  module ModuleBuildModeResolver
    SETTING_KEY = "system.module_builds.mode"

    GITEA  = "gitea"
    DUAL   = "dual"
    NATIVE = "native"

    MODES = [ GITEA, DUAL, NATIVE ].freeze
    DEFAULT_MODE = GITEA

    class << self
      def current
        raw = ::SiteSetting.get(SETTING_KEY).presence
        MODES.include?(raw) ? raw : DEFAULT_MODE
      end

      def gitea?
        current == GITEA
      end

      def dual?
        current == DUAL
      end

      def native?
        current == NATIVE
      end
    end
  end
end
