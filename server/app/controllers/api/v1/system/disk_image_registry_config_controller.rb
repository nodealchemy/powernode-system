# frozen_string_literal: true

module Api
  module V1
    module System
      # GET /api/v1/system/disk_image_registry_config
      #
      # CI-direct config fetch — the build-disk-image workflow calls this
      # (Bearer <per-worker token>, same Worker table + auth idiom as
      # ModulePublicationsController) immediately before `oras login` +
      # push, instead of reading POWERNODE_REGISTRY_HOST/_USER/_TOKEN out of
      # Gitea Actions secrets. DK1 restoration: registry config now lives in
      # AdminSetting (host) + Security::SecretStore (user/token, Vault-or-DB)
      # via System::DiskImageRegistryConfig, with the Worker/Gitea-secret
      # duplication this replaces documented in the "CI worker token has two
      # sources of truth" learning.
      #
      # This response body IS the secret delivery to the authenticated CI
      # worker — that's the endpoint's purpose. The token must never be
      # logged: no Rails.logger call in this controller references
      # registry_user/registry_token, and the audit FleetEvent payload below
      # carries only the worker identity, never the credential.
      class DiskImageRegistryConfigController < ApplicationController
        skip_before_action :authenticate_request, raise: false
        skip_before_action :verify_authenticity_token, raise: false

        def show
          return render_error("CI worker token required", :unauthorized) unless valid_ci_bearer?

          unless @current_ci_worker.has_permission?("system.platforms.publish_disk_image")
            return render_forbidden("Permission denied: system.platforms.publish_disk_image")
          end

          unless ::System::DiskImageRegistryConfig.configured?
            return render_error(
              "disk-image OCI registry not configured — set the registry host (AdminSetting) " \
              "and Vault-backed registry_user/registry_token before CI can publish",
              :service_unavailable
            )
          end

          emit_registry_config_read_event

          render_success(
            registry_host:  ::System::DiskImageRegistryConfig.registry_host,
            registry_user:  ::System::DiskImageRegistryConfig.registry_user,
            registry_token: ::System::DiskImageRegistryConfig.registry_token
          )
        end

        private

        # Mirror of ModulePublicationsController#valid_ci_bearer? — bearer
        # token hashed + compared against workers.token_digest via
        # Worker.authenticate. Per-worker storage (vs. a shared ENV secret)
        # gives operators individual revocation + last_seen_at auditing.
        def valid_ci_bearer?
          provided = request.headers["Authorization"].to_s.sub(/\ABearer\s+/i, "")
          return false if provided.empty?

          worker = ::Worker.authenticate(provided)
          return false unless worker

          @current_ci_worker = worker
          true
        end

        # There's no other audit trail for a registry-secret fetch (unlike
        # token rotation, which already flows through AuditLog via
        # Worker#log_token_regeneration). Best-effort: emit failure never
        # blocks the response.
        def emit_registry_config_read_event
          return unless defined?(::System::Fleet::EventBroadcaster)

          ::System::Fleet::EventBroadcaster.emit!(
            account:  @current_ci_worker.account,
            kind:     "system.disk_image_registry_config_read",
            severity: :low,
            source:   "ci_worker",
            payload:  { worker_id: @current_ci_worker.id, worker_name: @current_ci_worker.name }
          )
        rescue StandardError => e
          Rails.logger.warn "[DiskImageRegistryConfigController] audit emit failed: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
