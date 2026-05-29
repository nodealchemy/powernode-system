# frozen_string_literal: true

module Api
  module V1
    module System
      # Read-only operator surface projecting the reverse-proxy routes derived
      # from the account's ACME certificates. Each AcmeCertificate row yields
      # one RouteProjection describing the Traefik routers Traefik serves (or
      # would serve once the cert is valid) for that hostname.
      #
      # Routes:
      #   GET /api/v1/system/ingress_routes            (optional ?status= filter)
      #
      # Permission:
      #   system.ingress.read — view ingress / reverse-proxy state
      #
      # The projection is DERIVED — there is no IngressRoute model. The single
      # source of truth for the router metadata + host matcher is
      # Acme::TraefikConfigWriter (the write path); Acme::IngressRoutePresenter
      # reads from it so the routes shown here match what Traefik actually
      # serves. See that presenter for the per-cert field derivation.
      #
      # Plan reference: Decentralized Federation §J — Phase 2c (Ingress).
      class IngressRoutesController < ApplicationController
        def index
          return forbidden unless current_user&.has_permission?("system.ingress.read")

          certs = ::System::AcmeCertificate
                    .where(account: current_account)
                    .order(created_at: :desc)
          certs = certs.where(status: params[:status].to_s.split(",")) if params[:status].present?

          # Resolve the env-derived reverse-proxy values ONCE per request and
          # thread them into the presenter. Without this, the writer's class
          # methods re-read POWERNODE_PROXY_{BACKEND,FRONTEND}_URL once per
          # router (x9) and re-split POWERNODE_PROXY_EXTRA_HOSTS twice for EACH
          # cert — ~12 env reads per cert. Threading them in makes it 3 total.
          backend_url  = ::Acme::TraefikConfigWriter.backend_url
          frontend_url = ::Acme::TraefikConfigWriter.frontend_url
          extra_hosts  = ::Acme::TraefikConfigWriter.extra_hosts

          render_success(
            routes: certs.map do |cert|
              ::Acme::IngressRoutePresenter.project(
                cert,
                backend_url: backend_url,
                frontend_url: frontend_url,
                extra_hosts: extra_hosts
              )
            end
          )
        end

        private

        def forbidden
          render_error("Forbidden", status: :forbidden)
        end
      end
    end
  end
end
