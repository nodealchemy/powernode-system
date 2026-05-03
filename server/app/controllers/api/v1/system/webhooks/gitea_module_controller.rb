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
          skip_before_action :authenticate_request, raise: false
          skip_before_action :verify_authenticity_token, raise: false

          def handle
            payload = parse_payload
            return render_ok unless payload

            node_module = find_node_module(payload)
            return render_ok("Module not found") unless node_module

            unless verify_signature(node_module.webhook_secret)
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
            body = request.body.read
            return nil if body.blank?

            @raw_body = body
            JSON.parse(body).with_indifferent_access
          rescue JSON::ParserError => e
            Rails.logger.warn "[GiteaModule] Invalid JSON payload: #{e.message}"
            nil
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
          def verify_signature(secret)
            return true if secret.blank? # opt-out for dev / testing

            signature = request.headers["X-Gitea-Signature"] ||
                        request.headers["X-Hub-Signature-256"]
            return false if signature.blank?

            signature = signature.sub(/\Asha256=/, "")
            expected = OpenSSL::HMAC.hexdigest("sha256", secret, @raw_body)
            Rack::Utils.secure_compare(expected, signature)
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
            registry = ENV.fetch("POWERNODE_OCI_REGISTRY", "git.ipnode.org")
            "#{registry}/#{node_module.gitea_repo_full_name}:#{tag}"
          end

          # find_or_create_version was extracted to
          # System::ModulePublicationProcessor#find_or_create_version
          # so that both the inline and async paths get the same
          # ordering: refresh manifest first, snapshot version with
          # the imported state, then ingest OCI artifact.

          def render_ok(message = "OK")
            render json: { status: "ok", message: message }, status: :ok
          end
        end
      end
    end
  end
end
