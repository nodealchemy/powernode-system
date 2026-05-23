# frozen_string_literal: true

module Api
  module V1
    module System
      # POST /api/v1/system/module_publications
      #
      # CI-direct webhook receiver for module-publish events. The
      # build-platform-modules workflow POSTs here after each
      # successful `oras push + cosign sign`, with the module name +
      # tag + per-format artifact descriptors. This is the fast path —
      # avoids round-tripping through Gitea's push webhook (which
      # listens to git pushes, not OCI artifact pushes).
      #
      # Authenticated via Bearer POWERNODE_CI_WORKER_TOKEN — same
      # token the worker uses; matches Gitea Actions secret name.
      #
      # Body shape (from .gitea/workflows/build-platform-modules.yaml
      # "Notify platform" step):
      #
      #   {
      #     "module_name": "powernode-hub-backend",
      #     "tag":         "c71ebc3",
      #     "artifacts": {
      #       "erofs": {
      #         "oci_ref":       "git.ipnode.org/powernode/powernode-hub-backend:c71ebc3",
      #         "fsverity_root": "sha256:...",
      #         "size":          50000000,
      #         "media_type":    "application/vnd.powernode.erofs"
      #       }
      #     }
      #   }
      #
      # The processor does the heavy lifting: pulls OCI manifest,
      # verifies cosign signature against COSIGN_PUBLIC_KEY_FILE,
      # populates NodeModuleVersion.artifacts JSONB.
      class ModulePublicationsController < ApplicationController
        skip_before_action :authenticate_request, raise: false
        skip_before_action :verify_authenticity_token, raise: false

        def create
          unless valid_ci_bearer?
            return render_error("CI worker token required", :unauthorized)
          end

          module_name = params[:module_name].to_s
          tag         = params[:tag].to_s
          artifacts   = params[:artifacts] || {}
          artifacts   = artifacts.to_unsafe_h if artifacts.respond_to?(:to_unsafe_h)
          return render_error("module_name + tag required", :bad_request) if module_name.empty? || tag.empty?

          # Scope by gitea_repo_full_name first — the OCI namespace
          # uniquely identifies which account's NodeModule row owns
          # the registry slot. Multiple accounts can carry rows for
          # the same module name (multi-tenant seeds, demo data), and
          # an unscoped find_by(name:) returns whichever the DB sorts
          # first — non-deterministic, and we've seen it land on the
          # wrong row. The platform-admin account's rows are the ones
          # the CI publishes for; their gitea_repo_full_name matches
          # the OCI namespace.
          gitea_repo = "powernode/#{module_name}"
          node_module = ::System::NodeModule.find_by(gitea_repo_full_name: gitea_repo) ||
                        ::System::NodeModule.find_by(name: module_name)
          return render_not_found("NodeModule for gitea_repo=#{gitea_repo} (or name=#{module_name.inspect})") unless node_module

          # Fast path: CI already signed with cosign + produced the
          # artifact descriptors. Trust the payload and write directly.
          # The heavy ModuleOciIngestService flow (OCI manifest fetch,
          # server-side cosign re-verify) is reserved for the Gitea
          # push webhook path where the server doesn't have CI-side
          # provenance to start from.
          version = find_or_create_version(node_module, tag)
          if artifacts.is_a?(Hash) && artifacts.any?
            normalized = artifacts.transform_values { |h| h.is_a?(Hash) ? h.stringify_keys : h }
            version.update_columns(artifacts: normalized)
          else
            Rails.logger.warn "[ModulePublicationsController] empty artifacts hash for #{module_name}@#{tag}"
          end

          emit_published_event(node_module, version, tag)

          render_success(
            node_module_version_id: version.id,
            version_number:         version.version_number,
            artifacts_keys:         Array(version.artifacts.keys)
          )
        end

        private

        # Mirror of ModulePublicationProcessor#find_or_create_version
        # so this controller doesn't need the whole processor's
        # ManifestFetchService + cosign-verify chain (those run on the
        # Gitea-webhook path; this path trusts the CI-signed payload).
        def find_or_create_version(node_module, tag)
          existing = ::System::NodeModuleVersion
                       .where(node_module: node_module)
                       .where("config->>'git_tag' = ?", tag)
                       .order(version_number: :desc)
                       .first
          return existing if existing

          ::System::NodeModuleVersion.create!(
            node_module:    node_module,
            changelog:      "CI publish tag #{tag}",
            mask:           Array(node_module.mask),
            file_spec:      Array(node_module.file_spec),
            package_spec:   Array(node_module.package_spec),
            protected_spec: Array(node_module.protected_spec),
            config:         { "git_tag" => tag }
          )
        end

        def emit_published_event(node_module, version, tag)
          return unless defined?(::System::Fleet::EventBroadcaster)
          ::System::Fleet::EventBroadcaster.emit!(
            account:                node_module.account,
            kind:                   "system.module_published",
            severity:               :low,
            source:                 "ci_webhook",
            node_module_id:         node_module.id,
            node_module_version_id: version.id,
            payload: {
              module_name:    node_module.name,
              version_number: version.version_number,
              git_tag:        tag,
              artifacts_keys: Array(version.artifacts.keys)
            }
          )
        rescue StandardError => e
          Rails.logger.warn "[ModulePublicationsController] fleet event emit failed: #{e.class}: #{e.message}"
        end

        # Bearer-token check. The CI worker token lives in Vault on the
        # platform side; ENV is the canonical home for plain-secret
        # config (worker tokens are short-lived rotational secrets
        # injected by the boot scripts).
        def valid_ci_bearer?
          expected = ENV["POWERNODE_CI_WORKER_TOKEN"].to_s
          return false if expected.empty?

          provided = request.headers["Authorization"].to_s.sub(/\ABearer\s+/i, "")
          return false if provided.empty?

          ActiveSupport::SecurityUtils.secure_compare(expected, provided)
        end
      end
    end
  end
end
