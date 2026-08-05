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

            # GUARD BEFORE MUTATE. This check used to run AFTER
            # upsert_publication!, which ends in save! — so a second delivery
            # for an already-published git_sha overwrote sha256, oci_ref and
            # the whole uki_* trio on a LIVE row, then returned
            # "idempotent_hit" and returned before dispatch_or_run, so nothing
            # ever verified the replacement. status was the only conditionally
            # guarded field; published_at, verified_at and file_object_id were
            # left describing the PREVIOUS build, so every downstream reader
            # (boot_image_controller's git_sha branch, UpgradeDispatcher
            # .preflight) still reported the row published and verified while
            # serving an artifact no verification step had approved. Proven end
            # to end through this action. Resolving first and deciding before
            # writing is the whole fix.
            #
            # ONE WRITE, TWO DIFFERENT FAILURES — and PINNING IS NOT A
            # MITIGATION, it only changes which way you lose:
            #   git_sha branch (boot_image_controller ~:154) — an unpinned node
            #     asks "what should I boot for this platform" and is silently
            #     handed the REPLACED digest, which nobody approved.
            #   digest branch (~:129) — a node that pinned the APPROVED digest
            #     now resolves NOTHING, because the column it matches on was
            #     overwritten. The careful nodes get a denial of service.
            #
            # Why this survived review: the :47 guard only fires once a row is
            # published WITH a file_object, so on a fresh platform the endpoint
            # behaves correctly and every early test passes. The more
            # established the platform, the more reliably the guard fires and
            # the LESS verification happens — a trust control that weakens the
            # longer the system runs correctly.
            #
            # Preconditions, so this is not read as worse than it is: a valid
            # HMAC signature is required, so it is NOT reachable by an
            # unauthenticated caller. It is a trust-integrity failure under
            # LEGITIMATE credentials — triggered by an ordinary CI re-run of the
            # same git_sha that produces different bytes (rebuild, re-tag,
            # retried job, non-reproducible build), or by a replayed delivery.
            existing = ::System::DiskImagePublication
                         .find_by(node_platform: platform, git_sha: payload["git_sha"])

            if existing&.published? && existing.file_object_id.present?
              # A delivery that DISAGREES with the published artifact is not an
              # idempotent hit and must not be reported as one — silently
              # discarding a genuinely different build is its own hazard, and
              # the old response actively misled anyone reading it. Surface it
              # with both digests so an operator can tell which build won.
              if (mismatch = published_artifact_mismatch(existing, payload))
                Rails.logger.warn(
                  "[DiskImageBuilt] conflict: delivery for already-published git_sha=" \
                  "#{existing.git_sha} disagrees with the published artifact " \
                  "(#{mismatch}); discarding delivery, publication=#{existing.id} " \
                  "platform=#{platform.name}"
                )
                return render_ok_with_status(
                  "conflict",
                  reason: "published_artifact_mismatch",
                  publication_id: existing.id,
                  note: "git_sha #{existing.git_sha} is already published with a DIFFERENT " \
                        "artifact; this delivery was discarded and NOT verified"
                )
              end

              return render_ok_with_status("idempotent_hit",
                                            publication_id: existing.id,
                                            note: "already published with this git_sha")
            end

            publication = upsert_publication!(webhook, platform, payload)

            dispatch_or_run(publication)
            render_ok_with_status("queued", publication_id: publication.id)
          rescue StandardError => e
            Rails.logger.error "[DiskImageBuilt] processing error: #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            render_ok_with_status("error", reason: "processing_error", error_class: e.class.to_s, error_message: e.message)
          end

          private

          # Content identity of a delivery vs what is already published.
          #
          # DIGESTS ONLY — sha256 (the disk image) and uki_sha256 (the UKI that
          # boot_image_controller serves by digest). oci_ref and uki_oci_ref
          # are deliberately NOT compared even though they name the artifact:
          # they are LOCATORS, not identity. The same bytes can legitimately be
          # reachable at a different registry path after a re-tag, and flagging
          # that as a conflict is a false positive — the existing
          # "is idempotent on re-receive of the same git_sha" example is
          # exactly that shape (identical sha256, different oci_ref) and it
          # caught this. A locator change is safe here by construction: this
          # branch writes nothing, so the published row keeps the ref that was
          # actually verified.
          #
          # Metadata that legitimately varies between deliveries of one build
          # (firmware_ref, arch, payload) is likewise not compared.
          #
          # A blank incoming value is treated as "not asserted" rather than as
          # a mismatch, so a partial redelivery from an older CI that omits
          # uki_* does not read as a conflict.
          #
          # Returns a human-readable description of the disagreement, or nil.
          def published_artifact_mismatch(existing, payload)
            {
              "sha256"      => payload["sha256"],
              "uki_sha256"  => payload["uki_sha256"]
            }.filter_map do |column, delivered|
              next if delivered.blank?

              published = existing.public_send(column)
              next if published.blank? || published == delivered

              "#{column}: published=#{published} delivered=#{delivered}"
            end.presence&.join("; ")
          end

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
              # Standalone UKI artifact for in-place upgrades (campaign 019f505f
              # inc 2). Absent from pre-inc-2 CI payloads → nil (allow_nil).
              uki_oci_ref:   payload["uki_oci_ref"],
              uki_sha256:    payload["uki_sha256"],
              uki_cosign_bundle: payload["uki_cosign_bundle"],
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
            # System owns this worker job; enqueue it through the core client's slug-agnostic
            # queue_job primitive so core never names a System::*Job.
            ::WorkerApiClient.new.queue_job(
              "System::ProcessDiskImagePublicationJob", [ publication.id ], queue: "services"
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
