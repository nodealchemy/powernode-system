# frozen_string_literal: true

module Api
  module V1
    module System
      module Webhooks
        # POST /api/v1/system/webhooks/disk_image/built/:webhook_id
        #
        # Receives disk-image build notifications from CI runners. The
        # :webhook_id segment is the row's UUID and scopes the request
        # to a specific account's DiskImageWebhook (account is derived
        # from webhook.account_id, never trusted from the request body).
        # HMAC over the raw body authenticates against webhook.secret.
        #
        # Per platform webhook receiver discipline: ALWAYS returns 200.
        # Never 500 — that would cause CI to retry indefinitely.
        # Failures surface as `{success: true, status: "error", reason: ...}`
        # response bodies.
        #
        # Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 2).
        class DiskImageBuiltController < ApplicationController
          skip_before_action :authenticate_request, raise: false
          skip_before_action :verify_authenticity_token, raise: false

          def handle
            webhook = ::System::DiskImageWebhook.active.find_by(id: params[:webhook_id])
            return render_ok_with_status("error", reason: "unknown_webhook") unless webhook

            raw_body = request.raw_post
            signature = request.headers["X-Powernode-Signature"]
            unless webhook.verify_signature(raw_body, signature)
              Rails.logger.warn "[DiskImageBuilt] bad signature for webhook=#{webhook.id} label=#{webhook.label}"
              return render_ok_with_status("error", reason: "bad_signature")
            end

            webhook.record_received!

            payload = parse_payload(raw_body)
            return render_ok_with_status("error", reason: "invalid_payload") unless payload

            platform = webhook.account.system_node_platforms.find_by(name: payload["platform_name"])
            return render_ok_with_status("error", reason: "unknown_platform",
                                         hint: "platform_name='#{payload['platform_name']}' not found in account") unless platform

            publication = upsert_publication!(webhook, platform, payload)

            if publication.published? && publication.file_object_id.present?
              return render_ok_with_status("idempotent_hit",
                                            publication_id: publication.id,
                                            note: "already published with this git_sha")
            end

            dispatch_or_run(publication)
            render_ok_with_status("queued", publication_id: publication.id)
          rescue StandardError => e
            Rails.logger.error "[DiskImageBuilt] processing error: #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            render_ok_with_status("error", reason: "processing_error", error_class: e.class.to_s, error_message: e.message)
          end

          private

          def parse_payload(raw_body)
            return nil if raw_body.blank?

            JSON.parse(raw_body)
          rescue JSON::ParserError => e
            Rails.logger.warn "[DiskImageBuilt] invalid JSON: #{e.message}"
            nil
          end

          # Idempotent: re-received webhooks for the same git_sha hit the
          # same row (uniq index), upsert just refreshes payload + bumps
          # attempt_count when it transitions back through processing.
          def upsert_publication!(webhook, platform, payload)
            publication = ::System::DiskImagePublication.find_or_initialize_by(
              node_platform: platform,
              git_sha: payload["git_sha"]
            )

            publication.assign_attributes(
              account: webhook.account,
              webhook: webhook,
              sha256:        payload["sha256"],
              size_bytes:    payload["size_bytes"].to_i,
              oci_ref:       payload["oci_ref"],
              firmware_ref: payload["firmware_ref"],
              arch:          payload["arch"] || "arm64",
              payload:       payload,
              status:        publication.persisted? ? publication.status : "queued"
            )
            publication.save!
            publication
          end

          # Production: enqueue System::ProcessDiskImagePublicationJob on
          # the worker. Worker calls back to the worker_api endpoint to
          # actually run cosign verify + OCI pull + storage upload.
          # Webhook acks CI immediately.
          #
          # Inline fallback for dev (no worker) and when worker dispatch
          # fails (so the publication still lands; the whole point of
          # async dispatch is webhook latency, not correctness).
          def dispatch_or_run(publication)
            mode = ENV.fetch("POWERNODE_WEBHOOK_INGEST_MODE", default_ingest_mode)
            case mode
            when "async"
              dispatch_async(publication)
            when "inline"
              run_inline(publication)
            else
              Rails.logger.warn "[DiskImageBuilt] unknown POWERNODE_WEBHOOK_INGEST_MODE=#{mode.inspect}, falling back to inline"
              run_inline(publication)
            end
          end

          def default_ingest_mode
            Rails.env.production? ? "async" : "inline"
          end

          def dispatch_async(publication)
            ::WorkerApiClient.new.queue_disk_image_publication_processing(
              publication_id: publication.id
            )
          rescue ::WorkerApiClient::ApiError => e
            Rails.logger.warn "[DiskImageBuilt] worker dispatch failed (#{e.message}); falling back to inline"
            run_inline(publication)
          end

          def run_inline(publication)
            ::System::DiskImagePublicationProcessor.process!(publication: publication)
          end

          def render_ok_with_status(status, **extras)
            render json: { success: true, status: status, **extras }, status: :ok
          end
        end
      end
    end
  end
end
