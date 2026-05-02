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
        before_action :authorize_netboot!
        before_action :load_instance!

        # GET /api/v1/system/netboot/:instance_id/script.ipxe
        # Returns text/plain so iPXE chainload (`chain http://...`) consumes
        # it directly. Optional ?image_base=... overrides the default.
        def script
          result = ::System::BootstrapService.render_for_instance(
            instance: @instance,
            image_base: params[:image_base].presence,
            ttl: parse_ttl,
            purpose: "netboot"
          )

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

        def parse_ttl
          val = params[:ttl_minutes].to_i
          return 1.hour unless val.between?(1, 360) # 1 min – 6 hr
          val.minutes
        end
      end
    end
  end
end
