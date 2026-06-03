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
          def aggregate
            run_phase!("aggregate") { fleet_service.aggregate! }
          end

          # POST .../reap
          def reap
            run_phase!("reap") { fleet_service.reap! }
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
            result.slice(:ok, :count, :delegation, :skipped).compact
          end

          def load_mission
            @mission = ::Ai::Mission.find_by(id: params[:mission_id])
            return render_not_found("Mission") unless @mission
            return render_error("Not an agent_fleet mission", status: :unprocessable_content) unless @mission.mission_type == "agent_fleet"
          end
        end
      end
    end
  end
end
