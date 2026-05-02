# frozen_string_literal: true

module PowernodeSystem
  module Features
    # Feature flags registered with Flipper at boot.
    # The system extension is core operator-tooling without commercial gating,
    # so flags are simple on/off switches rather than tiered plan checks.
    SYSTEM_FLAGS = %i[
      system_mode
      system_task_dispatch
      system_provisioning
      system_module_distribution
    ].freeze

    class << self
      # Whether a feature is available. Used by Powernode::ExtensionRegistry
      # via features_module: passed at register time. Returns true for
      # unknown features (open by default — feature_flag absence is not gating).
      def available?(feature, account: nil)
        flag_name = :"system_#{feature}"
        return true unless SYSTEM_FLAGS.include?(flag_name)
        return true unless defined?(Flipper)

        Flipper.enabled?(flag_name, account)
      end
    end
  end
end
