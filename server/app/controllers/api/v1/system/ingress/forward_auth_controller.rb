# frozen_string_literal: true

module Api
  module V1
    module System
      module Ingress
        # Traefik forwardAuth endpoint for LOCALLY exposed services (the
        # Sdwan::Service local plane). Traefik calls this with the original
        # request's headers (Authorization / cookies) before proxying /svc/<slug>:
        #
        #   200 + identity headers → allow (headers forwarded to the backend via
        #                            the middleware's authResponseHeaders)
        #   401 / 403 / 404        → deny (status returned to the caller)
        #
        # Authentication is the inherited `authenticate_request` filter, so a
        # missing/invalid token yields 401 before #show. `public` services omit
        # the forwardAuth middleware entirely and never reach here; `authenticated`
        # services allow any valid platform user; `scoped` services additionally
        # require a permission or group.
        class ForwardAuthController < ApplicationController
          def show
            service = ::Sdwan::Service.active.find_by(id: params[:service], account_id: current_account&.id)
            return head(:not_found) if service.nil?
            return head(:forbidden) if service.local_auth_mode == "scoped" && !authorized_for?(service)

            response.set_header("X-Powernode-User", current_user.id.to_s)
            response.set_header("X-Powernode-Account", current_account.id.to_s)
            response.set_header("X-Powernode-Groups", current_user_group_names.join(","))
            head :ok
          end

          private

          # scoped services authorize by an explicit permission (preferred) or,
          # failing that, membership in a named group (mapped to role names).
          def authorized_for?(service)
            if service.local_required_permission.present?
              current_user.has_permission?(service.local_required_permission)
            elsif service.local_required_group.present?
              current_user_group_names.include?(service.local_required_group)
            else
              false
            end
          end

          def current_user_group_names
            @current_user_group_names ||= current_user.roles.pluck(:name)
          end
        end
      end
    end
  end
end
