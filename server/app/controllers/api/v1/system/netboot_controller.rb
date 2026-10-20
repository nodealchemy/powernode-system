# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing netboot endpoint. Renders the iPXE chainload script
      # for a NodeInstance, issuing a fresh BootstrapToken on each call so
      # multiple "boot this instance now" requests don't share a single
      # one-shot token.
      #
      # Auth: standard JWT. Operator must hold system.instances.create OR
      # system.instances.control to render a script for an instance — these
      # are the same gates as provision/start, so anyone authorized to
      # bring an instance up can also generate its boot script.
      #
      # Reference: Golden Eclipse plan M3 — iPXE chainload endpoint.
      class NetbootController < ApplicationController
        # ca is the one public action: a booting agent has no credentials yet.
        skip_before_action :authenticate_request, only: :ca, raise: false
        before_action :authorize_netboot!, except: :ca
        before_action :load_instance!, except: :ca

        # GET /api/v1/system/netboot/ca.pem
        # Public. Serves ONLY the CERTIFICATE blocks of the configured enrolment
        # CA (never any other PEM block). The agent accepts these bytes solely if
        # they match the ca_fingerprint pin on its kernel cmdline, so the pin
        # authenticates the content and the transport need not.
        def ca
          pem = ::System::ProvisioningDocument.configured_ca_certificates_pem
          return render_not_found("CA") if pem.blank?

          response.set_header("Cache-Control", "public, max-age=300")
          render plain: pem, content_type: "application/x-pem-file"
        end

        # GET /api/v1/system/netboot/:instance_id/script.ipxe
        # Returns text/plain so iPXE chainload (`chain http://...`) consumes
        # it directly. Optional ?image_base=... overrides the default.
        def script
          ttl = parse_ttl
          return if performed?

          result = ::System::BootstrapService.render_for_instance(
            instance: @instance,
            image_base: params[:image_base].presence,
            ttl: ttl,
            purpose: "netboot"
          )

          # BootstrapService::Result = Struct.new(:ok?, ...) — accessor is
          # `ok?`, not `success?`. The mismatch surfaced as a 500 for every
          # iPXE script render.
          if result.ok?
            response.set_header("Cache-Control", "no-store")
            response.set_header("X-Powernode-Token-Id", result.token_id.to_s)
            render plain: result.script, content_type: "text/plain"
          else
            render_error("Failed to render iPXE script: #{result.error}", 422)
          end
        end

        private

        def authorize_netboot!
          unless current_user&.has_permission?("system.instances.create") ||
                 current_user&.has_permission?("system.instances.control")
            render_forbidden("Permission denied: system.instances.create or .control required")
          end
        end

        def load_instance!
          @instance = ::System::NodeInstance.joins(:node)
            .where(system_nodes: { account_id: current_user.account.id })
            .find(params[:instance_id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("NodeInstance")
        end

        # Netboot tokens are platform-injected: capped at the netboot purpose
        # maximum (1 hour). Anything above is refused, not silently clamped.
        def parse_ttl
          return ::System::BootstrapToken.default_ttl_for("netboot") if params[:ttl_minutes].blank?

          max = (::System::BootstrapToken.max_ttl_for("netboot") / 60).to_i
          val = params[:ttl_minutes].to_i
          unless val.between?(1, max)
            render_error("ttl_minutes must be between 1 and #{max}", 422)
            return nil
          end
          val.minutes
        end
      end
    end
  end
end
