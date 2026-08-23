# frozen_string_literal: true

module Api
  module V1
    module System
      module Webhooks
        # POST /api/v1/system/webhooks/gitea/platform_push
        #
        # Campaign 019f5885 inc10 — the trigger inc11 will make the SOLE path
        # for module builds. Receives Gitea's push event for the platform
        # source repo (System::ModuleBuildPlannerService's
        # ci_build_source_repo, default "powernode/powernode-system") and
        # hands base_sha/head_sha to System::ModuleBuildTriggerService, which
        # branches on System::ModuleBuildModeResolver.current:
        #
        #   gitea  — no-op (default; nothing native happens)
        #   dual   — shadow native batch alongside the Gitea-authoritative build
        #   native — authoritative native batch (inc11 default)
        #
        # Auth mirrors GiteaModuleController: HMAC-SHA256 over the raw body
        # via System::Webhooks::HmacVerification, secret derived by
        # System::ModuleBuildDispatchService.platform_push_webhook_secret_for
        # (domain-separated from every other webhook secret this service
        # derives). Unlike GiteaModuleController there is no legacy
        # fail-open path — this is a brand-new endpoint, so it fails CLOSED
        # whenever no server secret is configured (never trusts an unsigned
        # or mismatched payload).
        #
        # Per platform webhook receiver rules: ALWAYS returns 200/202. Never
        # 500 — that would cause Gitea to retry indefinitely.
        class PlatformPushController < ApplicationController
          include ::System::Webhooks::HmacVerification

          skip_before_action :authenticate_request, raise: false
          skip_before_action :verify_authenticity_token, raise: false

          def handle
            payload = parse_payload
            return render_ok unless payload

            repo_full_name = payload.dig(:repository, :full_name)
            return render_ok("repository not recognized") unless repo_full_name == ci_build_source_repo

            unless verify_signature(repo_full_name)
              Rails.logger.warn "[PlatformPush] Invalid signature for #{repo_full_name}"
              return render_ok("Invalid signature")
            end

            unless push_to_target_ref?(payload)
              return render_ok("ignored ref #{payload[:ref]}")
            end

            render_ok(process_push(payload))
          rescue StandardError => e
            Rails.logger.error "[PlatformPush] Webhook processing error: #{e.class}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
            render_ok("Processing error")
          end

          private

          def parse_payload
            parse_json_request_body(log_tag: "[PlatformPush]")
          end

          # Fail-closed: no legacy opt-out. A blank secret (server_secret
          # unset in prod) means "reject", never "accept unsigned" — see
          # ModuleBuildDispatchService.platform_push_webhook_secret_for.
          def verify_signature(repo_full_name)
            secret = ::System::ModuleBuildDispatchService.platform_push_webhook_secret_for(repo_full_name)
            return false if secret.blank?

            secure_match?(
              hmac_hex(secret, @raw_body),
              signature_from_headers("X-Gitea-Signature", "X-Hub-Signature-256")
            )
          end

          def push_to_target_ref?(payload)
            ref = payload[:ref].to_s
            return false if ref.blank?
            return false unless ref == target_ref

            after_sha = payload[:after].to_s
            before_sha = payload[:before].to_s
            # Branch delete (after == all-zero) or initial branch creation
            # (before == all-zero, no diff base to compute a plan from) —
            # neither carries a usable base_sha..head_sha range.
            return false if after_sha.blank? || after_sha =~ /\A0+\z/
            return false if before_sha.blank? || before_sha =~ /\A0+\z/

            true
          end

          def process_push(payload)
            result = ::System::ModuleBuildTriggerService.trigger!(
              base_sha: payload[:before].to_s, head_sha: payload[:after].to_s
            )

            unless result.ok?
              return "trigger failed (mode=#{result.mode}): #{result.error}"
            end

            if result.dispatched
              summary = "mode=#{result.mode} shadow=#{result.shadow} batch=#{result.batch&.id}"
              # A batch the orchestrator refused at dispatch (core-mirror
              # divergence) still reaches here with dispatched=true — some of
              # its modules may have gone out. Say so, or an automated push
              # reports a refusal as a clean build.
              result.error.present? ? "#{summary} REFUSED: #{result.error}" : summary
            else
              "mode=#{result.mode} no-op"
            end
          end

          # Same SiteSetting -> ENV -> default chain as
          # System::ModuleBuildPlannerService#ci_build_source_repo (a private
          # method there, not reusable directly) and
          # Api::V1::System::NodeApi::ConfigController — duplicated
          # intentionally, per the existing precedent in those two files
          # (flagged there as a follow-up consolidation candidate; this is
          # now a third copy of the same acknowledged gap).
          def ci_build_source_repo
            ::SiteSetting.get("ci_build_source_repo").presence ||
              ENV["POWERNODE_CI_BUILD_SOURCE_REPO"].presence ||
              "powernode/powernode-system"
          end

          # SiteSetting-overridable so an operator can point this at a
          # different branch without a deploy; defaults to "develop" per
          # platform branch convention (CLAUDE.md: develop -> feature/* ->
          # release/* -> master).
          def target_ref
            ::SiteSetting.get("system.module_builds.trigger_ref").presence || "refs/heads/develop"
          end

          # render_ok is provided by System::Webhooks::HmacVerification.
        end
      end
    end
  end
end
