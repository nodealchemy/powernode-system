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

          # Extracts the relevant tag/version + OCI ref from the Gitea event
          # and triggers async ingest. Returns a short message string for
          # the response body. Currently handles two event shapes:
          # - Gitea push event with annotated tag → tag = ref_name
          # - Gitea release event → tag = release.tag_name
          # - Gitea package event → tag = package.tag (if present)
          def process_event(node_module, payload)
            tag = extract_tag(payload)
            return "No actionable tag in payload" if tag.blank?

            oci_ref = build_oci_ref(node_module, tag)
            version = find_or_create_version(node_module, tag)

            # Synchronous ingest for now — wrap in a worker job in a follow-up.
            result = ::System::ModuleOciIngestService.ingest!(
              node_module_version: version,
              oci_ref: oci_ref
            )

            if result.ok?
              "Ingested #{oci_ref} → version=#{version.version_number} arches=#{result.module_artifacts.map(&:architecture).join(',')}"
            else
              Rails.logger.warn "[GiteaModule] ingest failed: #{result.error}"
              "Ingest failed: #{result.error}"
            end
          end

          def extract_tag(payload)
            ref = payload[:ref] || payload.dig(:release, :tag_name) || payload.dig(:package, :tag)
            return nil if ref.blank?

            ref.sub(%r{\Arefs/tags/}, "")
          end

          def build_oci_ref(node_module, tag)
            registry = ENV.fetch("POWERNODE_OCI_REGISTRY", "git.ipnode.org")
            "#{registry}/#{node_module.gitea_repo_full_name}:#{tag}"
          end

          # Idempotent: if a version already exists for this tag, return it.
          # Gitea retries are routine (network blips, slow ack), and prior
          # to this guard the receiver would mint a fresh version on every
          # delivery — exploding version_number monotonically and creating
          # ghost versions with no real content delta.
          #
          # Spec arrays inherited from the module's current state so the
          # snapshot captures something useful. A future enhancement
          # (#3 in the audit notes) is to re-parse manifest.yaml from
          # the OCI artifact and replace these with the published values.
          def find_or_create_version(node_module, tag)
            existing = ::System::NodeModuleVersion
                         .where(node_module: node_module)
                         .where("config->>'git_tag' = ?", tag)
                         .order(version_number: :desc)
                         .first
            return existing if existing

            ::System::NodeModuleVersion.create!(
              node_module: node_module,
              changelog: "Auto-ingested from Gitea tag #{tag}",
              mask:           Array(node_module.mask),
              file_spec:      Array(node_module.file_spec),
              package_spec:   Array(node_module.package_spec),
              protected_spec: Array(node_module.protected_spec),
              config: { "git_tag" => tag }
            )
          end

          def render_ok(message = "OK")
            render json: { status: "ok", message: message }, status: :ok
          end
        end
      end
    end
  end
end
