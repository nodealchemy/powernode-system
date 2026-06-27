# frozen_string_literal: true

module Api
  module V1
    module System
      module Webhooks
        # POST /api/v1/system/webhooks/gitea/module
        #
        # Receives Gitea push / package events from module source repositories.
        # Locates the NodeModule by repo full_name, verifies the webhook HMAC
        # against the module's webhook_secret, and (on success) triggers
        # ModuleOciIngestService for the resulting OCI artifact.
        #
        # Per platform webhook receiver rules: ALWAYS returns 200/202.
        # Never 500 — that would cause Gitea to retry indefinitely.
        class GiteaModuleController < ApplicationController
          include ::System::Webhooks::HmacVerification

          skip_before_action :authenticate_request, raise: false
          skip_before_action :verify_authenticity_token, raise: false

          def handle
            payload = parse_payload
            return render_ok unless payload

            node_module = find_node_module(payload)
            return render_ok("Module not found") unless node_module

            unless verify_signature(node_module)
              Rails.logger.warn "[GiteaModule] Invalid signature for #{node_module.name}"
              return render_ok("Invalid signature")
            end

            result = process_event(node_module, payload)
            render_ok(result)
          rescue StandardError => e
            Rails.logger.error "[GiteaModule] Webhook processing error: #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            render_ok("Processing error")
          end

          private

          def parse_payload
            parse_json_request_body(log_tag: "[GiteaModule]")
          end

          # Routes events by Gitea repo full_name (e.g., "account/nginx-mod").
          # Module source repos must be registered up-front by setting
          # NodeModule#gitea_repo_full_name (operator UX provides this).
          def find_node_module(payload)
            repo_name = payload.dig(:repository, :full_name) || payload[:repo]
            return nil if repo_name.blank?

            ::System::NodeModule.find_by(gitea_repo_full_name: repo_name)
          end

          # HMAC-SHA256 over the raw body, hex-encoded. Gitea sends as
          # X-Gitea-Signature; GitHub-style senders send X-Hub-Signature-256
          # with optional `sha256=` prefix.
          #
          # Two policies, selected by ModuleBuildDispatchService
          # .module_webhook_enforced? (POWERNODE_MODULE_WEBHOOK_ENFORCE):
          #
          #   * ENFORCED (fail-closed) — verify against the DERIVED per-module
          #     secret (module_webhook_secret_for, domain-separated, rotatable
          #     via the server root secret). When that secret is blank (prod
          #     with the root unset) we REJECT rather than trust a default —
          #     and when the body is unsigned / mismatched we also reject. The
          #     never-populated node_module.webhook_secret column is ignored.
          #
          #   * LEGACY (default, fail-open) — preserved verbatim so flipping
          #     the flag is the only behavior change: verify against the
          #     node_module.webhook_secret column, accepting when it's blank
          #     (the historical dev/test opt-out).
          #
          # Either way a malformed signature yields false (never a 500) via
          # the shared concern's secure_match?.
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

          # Extracts the relevant tag/version + OCI ref from the Gitea event,
          # synchronously creates a version snapshot (so we have a stable
          # ID to track), then dispatches the long-pole work to the worker
          # service. Falls back to inline processing only when worker
          # dispatch is explicitly disabled (POWERNODE_WEBHOOK_INGEST_MODE=inline)
          # — useful for dev environments without a running worker.
          #
          # Returns a short message string for the response body (Gitea
          # ignores it; humans use logs + the FleetEvents the processor emits).
          def process_event(node_module, payload)
            tag = extract_tag(payload)
            return "No actionable tag in payload" if tag.blank?

            mode = ENV.fetch("POWERNODE_WEBHOOK_INGEST_MODE", default_ingest_mode)
            case mode
            when "async"
              dispatch_async(node_module, tag)
            when "inline"
              run_inline(node_module, tag)
            else
              Rails.logger.warn "[GiteaModule] unknown POWERNODE_WEBHOOK_INGEST_MODE=#{mode.inspect}, falling back to inline"
              run_inline(node_module, tag)
            end
          end

          def default_ingest_mode
            Rails.env.production? ? "async" : "inline"
          end

          # Production path: enqueue System::ProcessModulePublicationJob on
          # the worker. Worker calls back to the worker_api endpoint to
          # actually run the manifest fetch + version snapshot + OCI ingest.
          # Webhook acks Gitea immediately.
          def dispatch_async(node_module, tag)
            response = ::WorkerApiClient.new.queue_module_publication_processing(
              node_module.id, tag
            )
            "Queued module=#{node_module.name} tag=#{tag} job=#{response&.dig(:job_id) || response&.dig('job_id') || 'unknown'}"
          rescue ::WorkerApiClient::ApiError => e
            # Worker unreachable — fall back to inline so the publication
            # still lands. The whole point of the dispatch is webhook
            # latency, not correctness.
            Rails.logger.warn "[GiteaModule] worker dispatch failed (#{e.message}); falling back to inline"
            run_inline(node_module, tag)
          end

          # Inline path: call the processor directly in this request.
          # Used in dev (no worker) and as the fallback if dispatch fails.
          def run_inline(node_module, tag)
            result = ::System::ModulePublicationProcessor.process!(
              node_module: node_module,
              tag: tag
            )

            if result.ok?
              version = result.node_module_version
              "Ingested module=#{node_module.name} version=#{version.version_number} tag=#{tag} " \
                "arches=#{Array(result.artifacts).map(&:architecture).join(',')}"
            else
              "Ingest failed: #{result.error}"
            end
          end

          # All four post-version side effects (manifest re-import, OCI
          # ingest, skill registration, fleet event emission) live on
          # System::ModulePublicationProcessor — see that service for
          # the implementations. Inlined helpers were removed when the
          # async-dispatch refactor landed (2026-05-02).

          def extract_tag(payload)
            ref = payload[:ref] || payload.dig(:release, :tag_name) || payload.dig(:package, :tag)
            return nil if ref.blank?

            ref.sub(%r{\Arefs/tags/}, "")
          end

          def build_oci_ref(node_module, tag)
            registry = ENV.fetch("POWERNODE_OCI_REGISTRY", "registry.example.com")
            "#{registry}/#{node_module.gitea_repo_full_name}:#{tag}"
          end

          # find_or_create_version was extracted to
          # System::ModulePublicationProcessor#find_or_create_version
          # so that both the inline and async paths get the same
          # ordering: refresh manifest first, snapshot version with
          # the imported state, then ingest OCI artifact.

          # render_ok is provided by System::Webhooks::HmacVerification.
        end
      end
    end
  end
end
