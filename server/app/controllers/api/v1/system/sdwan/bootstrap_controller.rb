# frozen_string_literal: true

# Anonymous public endpoint for fetching a freshly-issued user VPN config.
# Validates the signed token (Rails MessageVerifier, 15-min TTL), then
# checks the device's single-use status — once last_downloaded_at is set,
# subsequent fetches return 410 Gone.
#
# Returns text/plain so users can pipe directly into wg-quick / WireGuard
# clients; no JSON envelope, no auth required (the token IS the auth).
#
# Slice 4 of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class BootstrapController < ApplicationController
          skip_before_action :authenticate_request, raise: false
          skip_before_action :verify_authenticity_token, raise: false

          # GET /api/v1/system/sdwan/bootstrap/:token
          def show
            token = params[:token].to_s
            return render_text_error("missing token", 400) if token.blank?

            payload = begin
              ::Sdwan::UserDeviceIssuer.verify_bootstrap_token!(token)
            rescue ::Sdwan::UserDeviceIssuer::BootstrapTokenError => e
              return render_text_error("invalid or expired bootstrap token: #{e.message}", 401)
            end

            device = ::Sdwan::UserDevice.find_by(id: payload[:device_id])
            return render_text_error("device not found", 404) unless device

            unless device.downloadable?
              status_msg =
                if device.revoked?
                  "device has been revoked"
                elsif device.last_downloaded_at.present?
                  "this bootstrap link has already been used"
                elsif !device.access_grant.active?
                  "underlying access grant is not active"
                else
                  "device is not downloadable"
                end
              return render_text_error(status_msg, 410)
            end

            config = ::Sdwan::WgConfigRenderer.render(device)

            # Mark single-use BEFORE rendering — if anything goes wrong
            # downstream (network blip, tab close), the token is still
            # consumed. Operators recover by issuing a new device.
            device.mark_downloaded!

            render plain: config, content_type: "text/plain", status: :ok
          end

          private

          def render_text_error(message, status)
            render plain: "# #{message}\n", content_type: "text/plain", status: status
          end
        end
      end
    end
  end
end
