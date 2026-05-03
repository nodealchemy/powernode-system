# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing CRUD for per-account CI workers (narrowly-scoped
      # Worker rows assigned the ci_worker role: only system.platforms.publish_disk_image
      # plus heartbeat/api basics).
      #
      # Tokens are returned plaintext EXACTLY ONCE on create + rotate.
      # The operator stores the token in their CI's secret manager
      # (POWERNODE_CI_WORKER_TOKEN env var convention).
      #
      # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 3).
      class CiWorkersController < BaseController
        before_action :set_account
        before_action :set_worker, only: %i[show destroy rotate_token]

        def index
          require_permission("system.ci_workers.read")
          # Filter to workers that hold the ci_worker role — that's the
          # operator-meaningful slice. (account_general and is_system
          # workers are out of scope here.)
          ci_workers = @account.workers
                                .joins(:roles)
                                .where(roles: { name: "ci_worker" })
                                .distinct
                                .order(created_at: :desc)
          render_success(
            ci_workers: ci_workers.map { |w| ::System::CiWorkerSerializer.new(w).as_json }
          )
        end

        def show
          require_permission("system.ci_workers.read")
          render_success(ci_worker: ::System::CiWorkerSerializer.new(@worker).as_json)
        end

        def create
          require_permission("system.ci_workers.create")
          worker = ::Worker.create_worker!(
            name:    params.require(:name),
            account: @account,
            roles:   [ "ci_worker" ]
          )
          render_success(
            ci_worker: ::System::CiWorkerSerializer.new(worker).as_json,
            # SHOWN EXACTLY ONCE.
            token_plaintext: worker.token,
            note: "Store this token in your CI secrets as POWERNODE_CI_WORKER_TOKEN. Not recoverable — rotate to get a new one."
          )
        rescue ActiveRecord::RecordInvalid => e
          render_validation_error(e.record)
        rescue StandardError => e
          render_error("Failed to create CI worker: #{e.message}", 422)
        end

        def destroy
          require_permission("system.ci_workers.delete")
          @worker.revoke!
          render_success(message: "CI worker revoked")
        end

        # POST /api/v1/system/ci_workers/:id/rotate_token
        def rotate_token
          require_permission("system.ci_workers.rotate_token")
          new_token = "swt_#{SecureRandom.urlsafe_base64(32)}"
          @worker.update!(token_digest: Digest::SHA256.hexdigest(new_token))
          emit_rotated_event(@worker)
          render_success(
            ci_worker: ::System::CiWorkerSerializer.new(@worker).as_json,
            token_plaintext: new_token,
            note: "Store this token now — old token is revoked. Update CI immediately."
          )
        end

        private

        def set_worker
          @worker = @account.workers
                             .joins(:roles)
                             .where(roles: { name: "ci_worker" })
                             .find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("CiWorker")
        end

        def emit_rotated_event(worker)
          return unless defined?(::System::Fleet::EventBroadcaster)
          ::System::Fleet::EventBroadcaster.emit!(
            account:  @account,
            kind:     "system.ci_worker_token_rotated",
            severity: :medium,
            source:   "operator_ui",
            payload:  { worker_id: worker.id, name: worker.name, by_user_id: current_user&.id }
          )
        rescue StandardError => e
          Rails.logger.warn "[CiWorkers] rotated event emit failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
