# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # POST /api/v1/system/node_api/claim
        #
        # Anonymous endpoint physical devices poll while waiting for an
        # operator to claim them via the Unclaimed Devices UI panel.
        # The claim flow is the platform's user-friendly first-boot
        # provisioning path: a generic disk image flashed onto an SD card
        # boots, the agent has no identity, polls here every 30s with
        # its discovered MAC + DMI UUID, and the platform either tells
        # it to keep polling (and what claim_code to display on console)
        # or hands it a single-use bootstrap token to enroll with.
        #
        # No authentication — there's no credential at this point in the
        # device's lifecycle. Rate-limited per IP by the Rack::Attack
        # "system_node_claim_by_ip" throttle (config/initializers/rack_attack.rb),
        # which deliberately excludes this path from the node_api safelist.
        # Returns 200 in all success/pending/expired branches; non-2xx only on
        # malformed request bodies (per the platform's webhook receiver rules).
        #
        # Reference: docs/plans/wondrous-yawning-anchor.md §5.
        class ClaimController < ApplicationController
          skip_before_action :authenticate_request, raise: false
          skip_before_action :verify_authenticity_token, raise: false

          POLL_INTERVAL_SECONDS = 30

          def create
            mac = params[:mac].to_s.strip.downcase
            return render_error("mac is required", 400) if mac.blank?

            discovery = ::System::PhysicalEnrollmentService.record_discovery!(
              mac:           mac,
              dmi_uuid:      params[:dmi_uuid].presence,
              hostname:      params[:hostname].presence,
              agent_version: params[:agent_version].presence,
              architecture:  params[:architecture].presence,
              platform_hint: params[:platform_hint].presence
            )

            # Claim-by-ID auto-confirm: a device flashed from a generic image
            # carries a per-instance identity.cfg (ID=<uuid>) and sends
            # instance_id here. When it matches a claimable NodeInstance, bind
            # it now so this same poll returns the bootstrap token — the
            # operator never has to confirm in the Unclaimed Devices UI. A
            # stray/unknown ID is a no-op (falls through to the normal
            # claim-code path), so it can't strand a device.
            if params[:instance_id].present?
              ::System::PhysicalEnrollmentService.auto_confirm_by_instance_id!(
                unclaimed:   discovery.unclaimed,
                instance_id: params[:instance_id].to_s.strip
              )
            end

            poll = ::System::PhysicalEnrollmentService.poll_status(discovery.unclaimed)

            response = {
              status:             poll.status,
              poll_after_seconds: poll.poll_after_seconds || POLL_INTERVAL_SECONDS
            }
            response[:claim_code]      = poll.claim_code      if poll.claim_code
            response[:bootstrap_token] = poll.bootstrap_token if poll.bootstrap_token
            response[:instance_uuid]   = poll.instance_uuid   if poll.instance_uuid
            response[:platform_url]    = poll.platform_url    if poll.platform_url
            response[:ca_pem_url]      = poll.ca_pem_url      if poll.ca_pem_url
            render_success(response)
          rescue ArgumentError => e
            render_error(e.message, 400)
          rescue StandardError => e
            Rails.logger.error "[ClaimController] #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            # Per the platform's webhook receiver rule: never 500 on a
            # device-side endpoint. Devices retry forever; a 500 storm is
            # worse than a single dropped poll. We pass `data:` explicitly
            # so the `status:` key in the payload doesn't get interpreted
            # as the HTTP status code by render_success.
            render_success(
              data: {
                status: "error",
                poll_after_seconds: POLL_INTERVAL_SECONDS,
                message: "internal error; will retry"
              }
            )
          end
        end
      end
    end
  end
end
