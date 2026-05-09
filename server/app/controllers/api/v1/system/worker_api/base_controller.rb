# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Base controller for System worker API endpoints.
        # Workers authenticate via token (X-Worker-Token header or Bearer).
        # Each action gates access via `authorize_worker_permission!` against a
        # System extension permission (e.g. "system.tasks.execute"), so a
        # blanket capability check at this layer would be redundant.
        class BaseController < ApplicationController
          include Paginatable

          # Skip default authenticate_request and use worker-specific auth
          skip_before_action :authenticate_request
          before_action :authenticate_worker!

          private

          # Authenticate worker via token. Accepts BOTH formats:
          #   1. JWT (preferred) — minted by `WorkerJwt.token` in the worker;
          #      decode via `Security::JwtService.decode`, look up the Worker
          #      by `payload[:sub]`. This is the modern path used by the
          #      `Internal::*` controllers via `authenticate_service_token`.
          #   2. Legacy opaque token — SHA256-digest comparison via
          #      `Worker.authenticate(token)`. Fallback for any pre-JWT
          #      worker still in the wild; can be retired once all workers
          #      are confirmed on JWT.
          #
          # Prior to this fix, the controller only supported (2) and rejected
          # all requests from the JWT-based worker — that's why the entire
          # `/api/v1/system/worker_api/*` namespace was 401-ing in production
          # while `Internal::*` worked.
          def authenticate_worker!
            token = extract_worker_token_from_request
            return render_unauthorized("Worker token required") unless token

            @current_worker = authenticate_via_jwt(token) || ::Worker.authenticate(token)
            return render_unauthorized("Invalid or inactive worker token") unless @current_worker

            # Record worker activity (JWT path doesn't auto-touch like the
            # opaque-token path does, so do it explicitly here for both).
            @current_worker.touch(:last_seen_at)
          end

          def authenticate_via_jwt(token)
            return nil unless token.include?(".")
            payload = ::Security::JwtService.decode(token)
            return nil unless payload[:type] == "worker"
            worker = ::Worker.find_by(id: payload[:sub])
            worker&.active? ? worker : nil
          rescue StandardError
            nil
          end

          # Extract token from X-Worker-Token header or Authorization Bearer
          def extract_worker_token_from_request
            # Prefer X-Worker-Token header
            token = request.headers["X-Worker-Token"]
            return token if token.present?

            # Fallback to Authorization header
            auth_header = request.headers["Authorization"]
            return nil unless auth_header&.start_with?("Bearer ")

            auth_header.split(" ", 2).last
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
        end
      end
    end
  end
end
