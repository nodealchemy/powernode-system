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
          skip_before_action :authenticate_request, raise: false
          skip_before_action :verify_authenticity_token, raise: false

          def create
            payload = parse_payload
            return render_ok("Empty body") unless payload

            node_module = find_node_module(payload[:module_id])
            return render_ok("Module not found") unless node_module

            unless verify_signature(node_module.webhook_secret)
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
            body = request.body.read
            return nil if body.blank?

            @raw_body = body
            JSON.parse(body).with_indifferent_access
          rescue JSON::ParserError => e
            Rails.logger.warn "[ModuleSbom] Invalid JSON payload: #{e.message}"
            nil
          end

          def find_node_module(module_id)
            return nil if module_id.blank?

            ::System::NodeModule.find_by(id: module_id)
          end

          # HMAC-SHA256 over raw body, hex-encoded. Mirrors
          # GiteaModuleController#verify_signature: same secret column,
          # same headers, same comparison primitive.
          def verify_signature(secret)
            return true if secret.blank? # opt-out for dev / testing

            signature = request.headers["X-Gitea-Signature"] ||
                        request.headers["X-Hub-Signature-256"]
            return false if signature.blank?

            signature = signature.sub(/\Asha256=/, "")
            expected = OpenSSL::HMAC.hexdigest("sha256", secret, @raw_body)
            Rack::Utils.secure_compare(expected, signature)
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

          def render_ok(message = "OK")
            render json: { status: "ok", message: message }, status: :ok
          end
        end
      end
    end
  end
end
