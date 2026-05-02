# frozen_string_literal: true

module System
  module Fleet
    module Sensors
      # Detects instances whose `running_module_digests` JSONB does not match
      # their assigned modules' current_version.oci_digest. Reuses the
      # SystemFleetTool drift_report logic via direct AR access (cheaper than
      # going back through the MCP tool — sensors are hot-path).
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
          running = inst.running_module_digests || {}
          assigned = inst.node.node_modules.includes(:current_version).each_with_object({}) do |m, acc|
            digest = m.current_version&.oci_digest
            acc[m.id] = digest if digest
          end

          missing = assigned.reject { |id, _| running.key?(id.to_s) || running.key?(id) }
          extra   = running.reject { |id, _| assigned.key?(id) || assigned.key?(id.to_s) }
          mismatched = assigned.each_with_object({}) do |(id, want), acc|
            have = running[id.to_s] || running[id]
            acc[id] = { want: want, have: have } if have && have != want
          end

          return nil if missing.empty? && extra.empty? && mismatched.empty?
          { missing: missing, extra: extra, mismatched: mismatched }
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
