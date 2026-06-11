# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # AI/MCP workload substrate L3 — agent-fleet mission phase callbacks.
        #
        # Each AiAgentFleet*Job (worker) POSTs its phase here after core's
        # Ai::Missions::OrchestratorService dispatched it (by job_class string
        # from the system_agent_fleet template — core never references these
        # classes). The controller invokes the matching
        # System::AgentFleetMissionService phase method, then SELF-ADVANCES the
        # mission via OrchestratorService#advance!(expected_phase:) — the same
        # pattern the core provisioning verify/handoff actions use. After the
        # single review_fleet approval gate clears, the chain
        # provision → delegate → aggregate → reap runs autonomously.
        #
        # Lives in the extension (not core) because it calls System::* services:
        # core must never depend on the extension; extension→core is fine.
        #
        # Auth: mTLS worker (BaseController) — same trust model as core's
        # Internal::Ai::ProvisioningController.
        class AgentFleetController < BaseController
          before_action :load_mission
          before_action :halt_unless_mission_active, except: [ :reap ]

          # POST /api/v1/system/worker_api/agent_fleet/missions/:mission_id/plan_fleet
          def plan_fleet
            run_phase!("plan_fleet") { fleet_service.plan! }
          end

          # POST .../provision_fleet
          def provision_fleet
            run_phase!("provision_fleet") { fleet_service.provision! }
          end

          # POST .../delegate
          def delegate
            run_phase!("delegate") { fleet_service.delegate! }
          end

          # POST .../aggregate
          # Execution wait: while dispatched subtask work is still running on
          # the fleet, do NOT advance — re-enqueue a delayed aggregate re-check
          # instead. Reap is only reached once execution settled or the
          # configurable timeout elapsed (outcome recorded on the report).
          def aggregate
            result = fleet_service.aggregate!
            return run_phase!("aggregate") { result } unless result[:waiting]

            if (delay = fleet_service.reserve_aggregate_recheck!)
              WorkerJobService.enqueue_job("AiAgentFleetAggregateJob", args: [{
                "mission_id" => @mission.id,
                "account_id" => @mission.account_id
              }], queue: "ai_execution", delay: delay)
            end
            render_success(result.merge(mission_id: @mission.id, phase: @mission.current_phase))
          rescue StandardError => e
            Rails.logger.error("[WorkerApi::AgentFleet#aggregate] #{e.class}: #{e.message}")
            render_error("aggregate failed: #{e.message}", status: :unprocessable_content)
          end

          # POST .../reap
          # Reap runs as a normal phase on active missions. On a cancelled or
          # failed mission it still RUNS — releasing instances is the safe
          # direction, and the cancel path dispatches it as cleanup — but a
          # terminal mission is never advanced. Anything else (paused, draft,
          # completed) skips entirely.
          def reap
            case @mission.status
            when "active"
              run_phase!("reap") { fleet_service.reap! }
            when "cancelled", "failed"
              result = fleet_service.reap!
              render_success(result.merge(cleanup: true, mission_id: @mission.id, phase: @mission.current_phase))
            else
              render_success({ skipped: true, reason: "mission #{@mission.status}",
                               mission_id: @mission.id, phase: @mission.current_phase })
            end
          rescue StandardError => e
            Rails.logger.error("[WorkerApi::AgentFleet#reap] #{e.class}: #{e.message}")
            render_error("reap failed: #{e.message}", status: :unprocessable_content)
          end

          private

          # Run a phase's work, then self-advance the mission past `phase`. The
          # expected_phase guard makes a stale Sidekiq retry a no-op (the
          # mission already moved on). advance! dispatches the next phase's job
          # unless that phase is an approval gate (review_fleet).
          def run_phase!(phase)
            result = yield
            ::Ai::Missions::OrchestratorService.new(mission: @mission)
                                               .advance!(result: { phase => phase_summary(result) }, expected_phase: phase)
            render_success(result.merge(mission_id: @mission.id, phase: @mission.reload.current_phase))
          rescue StandardError => e
            Rails.logger.error("[WorkerApi::AgentFleet##{phase}] #{e.class}: #{e.message}")
            render_error("#{phase} failed: #{e.message}", status: :unprocessable_content)
          end

          def fleet_service
            ::System::AgentFleetMissionService.new(mission: @mission)
          end

          # Compact summary for phase_history — the full member/assignment/report
          # arrays already live in mission.configuration["fleet"], so we don't
          # duplicate them into the phase exit record.
          def phase_summary(result)
            return result unless result.is_a?(Hash)
            result.slice(:ok, :count, :delegation, :skipped, :execution_outcome).compact
          end

          def load_mission
            @mission = ::Ai::Mission.find_by(id: params[:mission_id])
            return render_not_found("Mission") unless @mission
            return render_error("Not an agent_fleet mission", status: :unprocessable_content) unless @mission.mission_type == "agent_fleet"
          end

          # An in-flight Sidekiq phase job arriving after cancel/pause/failure
          # must not run phase work, advance the mission, or dispatch follow-on
          # jobs. (reap is exempt: terminal missions still release their fleet
          # — see #reap.)
          def halt_unless_mission_active
            return if @mission.status == "active"

            Rails.logger.info("[WorkerApi::AgentFleet] Skipping #{action_name} — mission #{@mission.id} is #{@mission.status}")
            render_success({ skipped: true, reason: "mission #{@mission.status}",
                             mission_id: @mission.id, phase: @mission.current_phase })
          end
        end
      end
    end
  end
end
