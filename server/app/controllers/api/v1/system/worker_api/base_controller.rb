# frozen_string_literal: true

module Api
  module V1
    module System
      module WorkerApi
        # Base controller for System worker API endpoints.
        # Workers authenticate via a short-lived JWT minted by `WorkerJwt.token`
        # in the worker process. The payload is `{type: "worker", sub: <worker_id>}`;
        # this controller decodes via Security::JwtService, looks up the Worker,
        # verifies it's still active, and touches last_seen_at.
        # Each action gates access via `authorize_worker_permission!` against a
        # System extension permission (e.g. "system.tasks.execute"), so a
        # blanket capability check at this layer would be redundant.
        class BaseController < ApplicationController
          include Paginatable

          skip_before_action :authenticate_request
          before_action :authenticate_worker!

          private

          def authenticate_worker!
            token = extract_worker_token_from_request
            return render_unauthorized("Worker token required") unless token

            @current_worker = authenticate_via_jwt(token)
            return render_unauthorized("Invalid or inactive worker token") unless @current_worker

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
