# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Recommend capacity adjustments for a Template's fleet. v0 uses three
      # available proxies:
      #   - assignment density (modules/instance count)
      #   - heartbeat staleness (silent instances are not contributing capacity)
      #   - error/terminated instance ratio (capacity reduction)
      #
      # Real metric-driven trend forecasting (CPU/mem time-series, queue depth)
      # arrives with the M-D2-2 telemetry pipeline. The interface is stable so
      # the linear-trend stub can be swapped without changing callers.
      #
      # Reference: Golden Eclipse plan M6 — Skills catalog (capacity_recommend row).
      class CapacityRecommendExecutor
        # Heartbeats older than this are treated as "silent" — not contributing
        # active capacity. Ties to FleetAutonomyService InstanceStatusSensor
        # (instance_silent at 3× heartbeat interval) — both should agree on
        # what "silent" means.
        SILENT_HEARTBEAT_AGE = 3.minutes

        # If active instances < target_min_active, recommend scale-up by the
        # delta. This is the only scale-up signal in v0; a real signal needs
        # CPU/queue/latency telemetry from M-D2-2.
        DEFAULT_TARGET_MIN_ACTIVE = 1

        def self.descriptor
          {
            name: "capacity_recommend",
            description: "Recommend instance count or instance-type adjustments for a Template's fleet based on heartbeat health and assignment density",
            category: "devops",
            inputs: {
              template_id: { type: "string", required: true },
              target_min_active: { type: "integer", required: false,
                                   default: DEFAULT_TARGET_MIN_ACTIVE,
                                   description: "Minimum number of healthy active instances the fleet must maintain" }
            },
            outputs: {
              template_id: :string,
              total_count: :integer,
              active_count: :integer,
              silent_count: :integer,
              errored_count: :integer,
              recommendation: :object,
              confidence: :string
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent = agent
          @user = user
        end

        def execute(template_id:, target_min_active: DEFAULT_TARGET_MIN_ACTIVE)
          tool = ::Ai::Tools::SystemFleetTool.new(account: @account, agent: @agent, user: @user)

          tmpl_check = tool.execute(params: { action: "system_get_template", template_id: template_id })
          return failure("template lookup failed: #{tmpl_check[:error]}") unless tmpl_check[:success]

          instances_resp = tool.execute(params: {
            action: "system_list_instances", template_id: template_id
          })
          return failure("instance listing failed: #{instances_resp[:error]}") unless instances_resp[:success]

          counts = bucket_counts(instances_resp[:data][:instances])
          recommendation = build_recommendation(counts, target_min_active.to_i)

          success(
            template_id: template_id,
            total_count: counts[:total],
            active_count: counts[:active],
            silent_count: counts[:silent],
            errored_count: counts[:errored],
            recommendation: recommendation,
            # Confidence is "low" until M-D2-2 telemetry arrives; we are
            # explicit so operators don't over-trust the v0 signal.
            confidence: "low",
            note: "v0 recommendation — real CPU/mem/queue trend forecasting lands with M-D2-2 telemetry pipeline"
          )
        rescue StandardError => e
          Rails.logger.error("[CapacityRecommendExecutor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        def bucket_counts(instances)
          now = Time.current
          buckets = { total: 0, active: 0, silent: 0, errored: 0, terminated: 0, provisioning: 0 }
          Array(instances).each do |i|
            buckets[:total] += 1
            case i[:status].to_s
            when "running", "starting"
              hb = parse_iso(i[:last_heartbeat_at])
              if hb && hb >= now - SILENT_HEARTBEAT_AGE
                buckets[:active] += 1
              else
                buckets[:silent] += 1
              end
            when "error"
              buckets[:errored] += 1
            when "terminated"
              buckets[:terminated] += 1
            when "provisioning", "pending"
              buckets[:provisioning] += 1
            end
          end
          buckets
        end

        def parse_iso(str)
          return nil if str.nil?
          Time.iso8601(str)
        rescue ArgumentError
          nil
        end

        def build_recommendation(counts, target_min_active)
          deficit = target_min_active - counts[:active]
          if deficit > 0
            {
              action: "scale_up",
              delta: deficit,
              reason: "Active count (#{counts[:active]}) below target_min_active (#{target_min_active})",
              suggested_skill: "provision_cluster"
            }
          elsif counts[:silent] >= 1 && counts[:active] < counts[:total] / 2
            {
              action: "investigate_silent",
              silent_count: counts[:silent],
              reason: "More than half of instances have stale heartbeats — investigate before scaling",
              suggested_skill: "drift_remediate"
            }
          elsif counts[:errored] >= 1
            {
              action: "remediate_errored",
              errored_count: counts[:errored],
              reason: "Errored instances should be reprovisioned or terminated",
              suggested_skill: "provision_cluster"
            }
          else
            {
              action: "no_change",
              reason: "Fleet appears healthy at target capacity"
            }
          end
        end

        def success(payload)
          { success: true, data: payload }
        end

        def failure(msg)
          { success: false, error: msg }
        end
      end
    end
  end
end
