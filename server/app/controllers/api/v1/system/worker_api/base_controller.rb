# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Base controller for System worker API endpoints.
        # Authenticated via mTLS — same pattern as Internal::InternalBaseController.
        # The Sidekiq worker is deployed as a NodeInstance (Stage 8b); the
        # reverse proxy verifies the worker's client cert against the
        # platform's internal CA on the websecure entrypoint (optional mTLS,
        # VerifyClientCertIfGiven) and forwards the CN (= NodeInstance.id) via
        # X-Forwarded-Tls-Client-Cert-Info.
        # We resolve the Worker via `node_instance_id` and confirm it's active.
        class BaseController < ApplicationController
          include Paginatable

          skip_before_action :authenticate_request
          before_action :authenticate_worker!

          private

          def authenticate_worker!
            # Federation mTLS Phase 2: verify against OUR CA before trusting the
            # CN (peer CAs now share the Traefik client-auth bundle), so a
            # peer-CA-signed cert can't impersonate a worker. Graceful when no
            # full cert is forwarded (pre-symmetric posture).
            subject_cn = ::Security::MtlsTrust.verify_request(request)
            return render_unauthorized("mTLS client certificate required") if subject_cn.blank?

            @current_worker = ::Worker.find_by(node_instance_id: subject_cn)
            return render_unauthorized("Worker not found for mTLS subject") unless @current_worker
            return render_unauthorized("Worker is not active") unless @current_worker.active?

            @current_worker.touch(:last_seen_at)
          end

          # Check worker has specific permission
          def authorize_worker_permission!(permission_name)
            unless current_worker.has_permission?(permission_name)
              render_forbidden("Permission denied: #{permission_name}")
            end
          end

          # Get account from worker or params
          def worker_account
            @worker_account ||= if current_worker.account?
                                  current_worker.account
            elsif params[:account_id].present?
                                  Account.find(params[:account_id])
            end
          end

          # Standard error handler for record not found
          def render_record_not_found(resource_type)
            render_not_found(resource_type)
          end

          # Pagination helpers
          def paginate(scope)
            page = pagination_params[:page]
            per_page = pagination_params[:per_page]
            scope.page(page).per(per_page)
          end

          def pagination_meta
            {
              current_page: pagination_params[:page],
              per_page: pagination_params[:per_page]
            }
          end

          attr_reader :current_worker

          # Per-gate counts for sweep summaries a fenced service declined
          # (IMP-5fee957b75b5 — shared by the fulfillment and CI-lease sweep
          # controllers). halted outranks the fence in each summary (the
          # services report it that way); a :gate_error fence status is
          # broken out from a genuine standby, so an operator hunting "why
          # is nothing advancing" can tell an emergency stop from a fence
          # from a failing gate.
          def gate_breakdown(gated)
            return {} if gated.empty?

            {
              halted: gated.count { |s| s[:halted] },
              standby: gated.count { |s| s[:standby] && s[:gate_status] != :gate_error },
              gate_error: gated.count { |s| s[:gate_status] == :gate_error }
            }
          end
        end
      end
    end
  end
end
