# frozen_string_literal: true

module Api
  module V1
    module System
      module Webhooks
        # POST /api/v1/system/webhooks/gitea/module_sbom
        #
        # Receives a CycloneDX SBOM from a module's CI build pipeline and
        # caches the parsed package list on the matching ModuleArtifact row
        # so System::CveOps::ExposureCalculator can do SBOM-aware matching
        # without fetching from OCI on every CVE intake.
        #
        # Auth: HMAC-SHA256 over raw body using `node_module.webhook_secret`,
        # the same per-module secret already used by GiteaModuleController.
        # No new credential type is introduced — module repos already hold
        # this secret as `POWERNODE_WEBHOOK_SECRET`.
        #
        # Per platform webhook receiver rules: ALWAYS returns 200/202.
        # Never 500 — that would cause Gitea to retry indefinitely.
        #
        # Reference: comprehensive stabilization sweep Phase 10.2.
        class ModuleSbomController < ApplicationController
          include ::System::Webhooks::HmacVerification

          skip_before_action :authenticate_request, raise: false
          skip_before_action :verify_authenticity_token, raise: false

          def create
            payload = parse_payload
            return render_ok("Empty body") unless payload

            node_module = find_node_module(payload[:module_id])
            return render_ok("Module not found") unless node_module

            unless verify_signature(node_module)
              Rails.logger.warn "[ModuleSbom] Invalid signature for #{node_module.name}"
              return render_ok("Invalid signature")
            end

            artifact = locate_artifact(node_module, payload[:tag], payload[:architecture])
            return render_ok("Artifact not found for tag=#{payload[:tag]} arch=#{payload[:architecture]}") unless artifact

            result = ingest_sbom!(artifact, payload[:sbom])
            render_ok(
              "SBOM ingested: module=#{node_module.name} tag=#{payload[:tag]} " \
              "arch=#{payload[:architecture]} packages=#{result.package_count} truncated=#{result.truncated?}"
            )
          rescue StandardError => e
            Rails.logger.error "[ModuleSbom] Webhook processing error: #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            render_ok("Processing error")
          end

          private

          def parse_payload
            parse_json_request_body(log_tag: "[ModuleSbom]")
          end

          def find_node_module(module_id)
            return nil if module_id.blank?

            ::System::NodeModule.find_by(id: module_id)
          end

          # HMAC-SHA256 over raw body, hex-encoded. Mirrors
          # GiteaModuleController#verify_signature exactly — same two
          # policies selected by ModuleBuildDispatchService
          # .module_webhook_enforced? (POWERNODE_MODULE_WEBHOOK_ENFORCE):
          #
          #   * ENFORCED (fail-closed) — verify against the DERIVED per-module
          #     secret; reject when it's blank (prod root unset) or when the
          #     body is unsigned / mismatched. The unpopulated
          #     node_module.webhook_secret column is ignored.
          #   * LEGACY (default, fail-open) — verify against the column,
          #     accepting a blank column (historical dev/test opt-out).
          #
          # A malformed signature yields false (never a 500) via secure_match?.
          def verify_signature(node_module)
            if ::System::ModuleBuildDispatchService.module_webhook_enforced?
              secret = ::System::ModuleBuildDispatchService.module_webhook_secret_for(node_module.id)
              return false if secret.blank? # fail closed — never trust a default
            else
              secret = node_module.webhook_secret
              return true if secret.blank? # legacy opt-out for dev / testing
            end

            secure_match?(
              hmac_hex(secret, @raw_body),
              signature_from_headers("X-Gitea-Signature", "X-Hub-Signature-256")
            )
          end

          # Locates the ModuleArtifact row for (module, git tag, arch). Tag
          # may arrive as raw "v1.2.3" or as Gitea's "refs/tags/v1.2.3";
          # we strip the prefix and match against the version's stored git_tag
          # (NodeModuleVersion#version_number is an internal auto-increment;
          # the human-facing tag lives in `config['git_tag']`).
          def locate_artifact(node_module, tag, architecture)
            return nil if tag.blank? || architecture.blank?

            normalized_tag = tag.to_s.sub(%r{\Arefs/tags/}, "")
            version = node_module.versions.find_by("(config ->> 'git_tag') = ?", normalized_tag)
            return nil unless version

            version.module_artifacts.find_by(architecture: architecture)
          end

          # Updates the cached SBOM atomically. Idempotent on identical input
          # — synced_at advances but data/count stay the same.
          def ingest_sbom!(artifact, sbom_input)
            parser_result = ::System::Sbom::CycloneDxParser.parse(sbom_input)

            artifact.update!(
              sbom_packages_data: parser_result.packages,
              sbom_packages_count: parser_result.package_count,
              sbom_packages_synced_at: Time.current
            )
            parser_result
          end

          # render_ok is provided by System::Webhooks::HmacVerification.
        end
      end
    end
  end
end
