# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects instances whose `running_module_digests` JSONB does not match
      # their assigned modules' current_version.oci_digest. The comparison
      # itself lives on NodeInstance#module_drift — the one definition, shared
      # with SystemFleetTool#drift_report and the deployment-scoped drift_check
      # — reached by direct AR access rather than back through the MCP tool.
      # Note #module_drift still loads each instance's assigned modules per
      # instance, so this sensor is one query per assigned module per running
      # instance; that is unchanged from the copy it replaced, not fixed by it.
      class ModuleDriftSensor < BaseSensor
        def sense
          ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: account.id })
            .where(status: "running")
            .find_each.filter_map do |inst|
            drift = compute_drift(inst)
            next if drift.blank?

            signal(
              kind: "system.module_drift",
              severity: severity_for(drift),
              payload: {
                instance_id: inst.id,
                missing_count: drift[:missing].size,
                extra_count: drift[:extra].size,
                mismatched_count: drift[:mismatched].size,
                missing: drift[:missing].keys,
                extra: drift[:extra].keys,
                mismatched: drift[:mismatched].keys
              },
              fingerprint: "module_drift:#{inst.id}"
            )
          end
        end

        private

        def compute_drift(inst)
          drift = inst.module_drift
          # Named limbs, not drift.values — a fourth key added to #module_drift
          # would silently change what this sensor treats as "no drift".
          return nil if drift[:missing].empty? && drift[:extra].empty? && drift[:mismatched].empty?

          drift
        end

        def severity_for(drift)
          total = drift[:missing].size + drift[:extra].size + drift[:mismatched].size
          return :critical if total >= 5
          return :high if total >= 3
          :medium
        end
      end
    end
  end
end
