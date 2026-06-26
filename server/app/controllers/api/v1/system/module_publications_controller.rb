# frozen_string_literal: true

require "base64"

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
      # Authenticated via Bearer <per-worker token>. The token is
      # provisioned via `system_provision_ci_worker` (creates a Worker row
      # with role=ci_worker; returns the plaintext token once for the
      # operator to store as a Gitea Actions secret). Revocation = flip
      # the Worker row's status to "revoked". No global shared secret.
      #
      # Body shape (from .gitea/workflows/build-platform-modules.yaml
      # "Notify platform" step):
      #
      #   {
      #     "module_name":       "powernode-hub-backend",
      #     "tag":               "c71ebc3",
      #     "manifest_yaml_b64": "<base64 of modules/<slug>/manifest.yaml>",
      #     "artifacts": {
      #       "erofs": {
      #         "oci_ref":       "git.powernode.org/powernode/powernode-hub-backend:c71ebc3",
      #         "fsverity_root": "sha256:...",
      #         "size":          50000000,
      #         "media_type":    "application/vnd.powernode.erofs"
      #       }
      #     }
      #   }
      #
      # Three side effects on a successful publish:
      #   1. NodeModuleVersion row created with the artifacts payload.
      #   2. NodeModule + ModuleService rows re-synced from
      #      manifest_yaml_b64 via ManifestImportService — keeps
      #      DB columns aligned with the source-tree manifest that the
      #      Stage 2 rsync filter just used to carve this erofs blob.
      #   3. artifacts.erofs.oci_digest populated by HEAD-ing the OCI
      #      manifest at oci_ref — the CI workflow doesn't ship the
      #      layer digest itself (oras push only emits the artifact
      #      digest), but the agent needs the layer digest to address
      #      the blob during pull + verify.
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

          # Resolve the NodeModule the publish targets. Lookup chain:
          #   1. gitea_repo_full_name match (canonical OCI namespace)
          #   2. bare name match across any account (legacy)
          #   3. create a new NodeModule on the publisher account
          #      with stub defaults; ManifestImportService at apply
          #      time fills in details from manifest_yaml_b64.
          #
          # The auto-create path decouples CI publication cadence from
          # the platform's deploy state — when a module is renamed or
          # newly added to the system extension's manifests, CI can
          # publish it without an out-of-band ops-side seed/cutover.
          # Without this, every rename/new-module needs a manual
          # rails-runner step on ops (per the 2026-05-24 incident
          # where 9 renamed modules triggered notify 404s until
          # /tmp/ops-create-renamed-modules.rb was run by hand).
          gitea_repo = "powernode/#{module_name}"
          node_module = ::System::ModulePublishTargetResolver.new.find_or_create_publish_target(gitea_repo, module_name)
          unless node_module
            return render_error(
              "could not resolve or create NodeModule for gitea_repo=#{gitea_repo} (or name=#{module_name.inspect})",
              :unprocessable_content
            )
          end

          # Side effect 1 — apply the source-tree manifest BEFORE
          # creating the version row, so the version inherits the
          # current file_spec/mask/protected_spec from the NodeModule
          # (find_or_create_version snapshots from those columns).
          # Without this, every CI publish under a refactor would
          # snapshot stale specs and trip up the agent's reconcile.
          manifest_import_error = apply_manifest_yaml(node_module, params[:manifest_yaml_b64])

          # Fail loudly when the manifest can't be applied — most often
          # this is platform-side schema drift (e.g. ManifestImportService
          # expects a NodeModule#capabilities column that hasn't been
          # migrated on this platform yet). Without this gate the publish
          # used to return 200 with `manifest_applied: false` buried in
          # the body, CI didn't check that field, and the result was a
          # half-published module: the OCI artifact lands in the registry
          # but the platform-side services/file_spec/etc rows stay empty,
          # and the agent silently no-ops on assignments (no systemd unit
          # ever generated). 422 makes the CI notify step fail visibly so
          # operators see the schema drift at publish time rather than
          # discovering it weeks later when assigned modules don't start.
          # Discovered 2026-05-25 via the qemu-guest-agent dogfood
          # (capabilities migration unrun on ops).
          if manifest_import_error
            return render_error(
              "manifest apply failed: #{manifest_import_error}",
              status: :unprocessable_content
            )
          end

          version = find_or_create_version(node_module, tag)
          if artifacts.is_a?(Hash) && artifacts.any?
            normalized = artifacts.transform_values { |h| h.is_a?(Hash) ? h.stringify_keys : h }
            # Side effect 3 — fill in the OCI layer digest (the only
            # piece CI can't supply cheaply; oras push reports the
            # artifact digest, not the per-layer one). Best-effort:
            # failure here doesn't abort the publish — the digest can
            # be backfilled later, and the agent will simply refuse to
            # mount until it shows up.
            erofs_layer = ::System::OciLayerDigestFetcher.new.fetch_oci_layer_digest(node_module, normalized.dig("erofs", "oci_ref"))
            if erofs_layer && normalized["erofs"].is_a?(Hash)
              normalized["erofs"] = normalized["erofs"].merge(
                "oci_digest" => erofs_layer[:digest],
                "size"       => erofs_layer[:size],
                "media_type" => erofs_layer[:media_type]
              )
            end
            version.update_columns(artifacts: normalized)
          else
            Rails.logger.warn "[ModulePublicationsController] empty artifacts hash for #{module_name}@#{tag}"
          end

          # Auto-promote the freshly-built version so the agent's next
          # reconcile picks it up without a separate operator step.
          # Rationale: CI publishes that survive the build matrix AND
          # cosign signing AND server-side manifest application have
          # already cleared every gate the platform enforces — making
          # promotion a manual extra step buys nothing but drift between
          # what's signed-and-published vs what the fleet actually runs.
          # Operators who want gated rollout should pin via the rolling-
          # upgrade orchestrator (per-template canary windows), not by
          # withholding current_version_id at the module level.
          unless node_module.current_version_id == version.id
            node_module.update_columns(current_version_id: version.id, updated_at: Time.current)
          end

          emit_published_event(node_module, version, tag)

          render_success(
            node_module_version_id: version.id,
            version_number:         version.version_number,
            artifacts_keys:         Array(version.artifacts.keys),
            manifest_applied:       manifest_import_error.nil?,
            manifest_import_error:  manifest_import_error,
            oci_digest_resolved:    version.artifacts.dig("erofs", "oci_digest").present?,
            promoted_to_current:    node_module.reload.current_version_id == version.id
          )
        end

        private

        # Re-applies the manifest YAML carried in the payload via
        # ManifestImportService — keeps NodeModule + ModuleService rows
        # aligned with the source-tree manifest that CI just packaged.
        # Returns nil on success (or no-op when the field is absent),
        # otherwise a short human-readable error message that lands in
        # the response body so CI failures are diagnosable from the
        # workflow log without SSHing into the platform.
        def apply_manifest_yaml(node_module, encoded)
          return nil if encoded.blank?

          yaml = begin
            ::Base64.strict_decode64(encoded.to_s)
          rescue ArgumentError => e
            return "manifest_yaml_b64 not valid base64: #{e.message}"
          end

          result = ::System::ManifestImportService.import!(node_module: node_module, yaml: yaml)
          return nil if result.ok?

          msg = "ManifestImportService refused module=#{node_module.name}: #{result.error}"
          if Array(result.validation_errors).any?
            msg += " — validation: #{result.validation_errors.join('; ')}"
          end
          Rails.logger.warn "[ModulePublicationsController] #{msg}"
          msg
        rescue StandardError => e
          msg = "ManifestImportService crashed module=#{node_module.name}: #{e.class}: #{e.message}"
          Rails.logger.warn "[ModulePublicationsController] #{msg}"
          msg
        end

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

        # Bearer-token check via the Worker table. The token is hashed in
        # worker.token_digest at provision time (system_provision_ci_worker
        # / Worker.create_worker!) and SHA256-compared via Worker.authenticate.
        # Per-worker storage gives operators individual revocation, last_seen_at
        # auditing, and role-based scoping — all of which a shared ENV secret
        # could not provide.
        def valid_ci_bearer?
          provided = request.headers["Authorization"].to_s.sub(/\ABearer\s+/i, "")
          return false if provided.empty?

          worker = ::Worker.authenticate(provided)
          return false unless worker

          @current_ci_worker = worker
          Rails.logger.info(
            "[ModulePublicationsController] CI publish authenticated via Worker table " \
            "(worker_id=#{worker.id} name=#{worker.name})"
          )
          true
        end
      end
    end
  end
end
