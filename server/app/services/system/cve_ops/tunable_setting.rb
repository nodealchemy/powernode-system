# frozen_string_literal: true

module System
  module CveOps
    # IMP-60717919d4a0 — the ONE resolution ladder for the CVE Responder's
    # operator-tunable integers.
    #
    # The fleet sensors resolve their tunables through
    # `System::Fleet::Sensors::BaseSensor#threshold`, which reads a
    # `System::Fleet::SensorConfig` row. The CVE Responder's sensors are
    # deliberately outside that catalog (`SystemFleetTool#configurable_sensors`
    # enumerates `FleetAutonomyService::SENSORS` only, and CvePublishedSensor
    # lives in `System::CveOps::Sensors` precisely so the fleet tick does not
    # sweep it up), so a SensorConfig row would be un-writable by the MCP
    # verbs and un-discoverable — which is why the operator direction on this
    # task specified a SiteSetting-resolved value with a constant fallback.
    #
    # What is NOT re-invented here is the definition of a usable value:
    # `SensorConfig.coerce_threshold` is "THE ONE definition of 'a usable
    # threshold value'" and is called directly, so a value this ladder accepts
    # is exactly a value the fleet ladder would accept.
    #
    # Ladder, most specific first (the shape ModulePromotionBacklogSensor
    # #lag_seconds uses):
    #   1. `Account#settings[account_key]`
    #   2. the deployment-wide `SiteSetting[site_setting_key]`
    #   3. `default`
    #
    # An UNUSABLE value at a rung falls THROUGH to the next one rather than
    # short-circuiting to the constant: `0` and `"abc"` are present-but-unusable
    # (Object#presence says "present" for both), and treating them as "the
    # account decided" silently discarded a deployment-wide window an operator
    # really had configured.
    #
    # Never raises and never returns nil: these values are read on an
    # unattended 60s tick, where a bad row must not stop the pass.
    module TunableSetting
      def self.resolve(account:, account_key:, site_setting_key:, default:)
        coerce(account&.settings&.dig(account_key)) ||
          coerce(::SiteSetting.get(site_setting_key)) ||
          default
      rescue StandardError => e
        Rails.logger.warn(
          "[CveOps::TunableSetting] #{site_setting_key} fell back to its default: #{e.class}: #{e.message}"
        )
        default
      end

      def self.coerce(value)
        ::System::Fleet::SensorConfig.coerce_threshold(value)
      end
      private_class_method :coerce
    end
  end
end
