# frozen_string_literal: true

module System
  module Ai
    module Skills
      # FederationManager — surveys federation peer + grant + cert health
      # for an account and produces a structured findings list. Designed
      # to be run weekly (operator-burden ownership per Architectural Fix
      # 2 of the Decentralized Federation plan).
      #
      # v1 checks:
      #   - cert_rotation_candidates: federation_peer certs past 75% of lifetime
      #   - grants_approaching_expiry: grants expiring within 7 days
      #   - grants_overdue_for_review: active grants issued >90 days ago
      #   - broad_scope_grants: grants carrying admin or migrate scope
      #   - capability_drift: peers advertising extensions without matching
      #     granted capabilities
      #
      # Plan reference: Decentralized Federation §"Fix 2" + P4.8.
      class FederationManagerExecutor < BaseSkillExecutor
        CERT_ROTATION_THRESHOLD_RATIO = 0.75
        GRANT_EXPIRY_WARN_WINDOW      = 7.days
        GRANT_REVIEW_THRESHOLD        = 90.days
        BROAD_SCOPES                  = %w[admin migrate].freeze

        skill_descriptor(
          name: "federation_manager",
          description: "Survey federation peer + grant + cert health for an account and surface findings the operator (or a future autonomy loop) should action.",
          category: "federation",
          inputs: {},
          outputs: {
            account_id: :string,
            ran_at: :string,
            cert_rotation_candidates: :array,
            grants_approaching_expiry: :array,
            grants_overdue_for_review: :array,
            broad_scope_grants: :array,
            capability_drift: :array,
            finding_count: :integer
          }
        )

        binds_to "SDWAN Manager"

        protected

        def perform(**_args)
          cert_rotation     = cert_rotation_candidates
          expiring_grants   = grants_approaching_expiry
          stale_grants      = grants_overdue_for_review
          broad_grants      = broad_scope_grants
          drifted_peers     = capability_drift

          findings_total = cert_rotation.size + expiring_grants.size + stale_grants.size +
                           broad_grants.size + drifted_peers.size

          emit_findings_summary!(findings_total)

          success(
            account_id: @account.id,
            ran_at: Time.current.iso8601,
            cert_rotation_candidates: cert_rotation,
            grants_approaching_expiry: expiring_grants,
            grants_overdue_for_review: stale_grants,
            broad_scope_grants: broad_grants,
            capability_drift: drifted_peers,
            finding_count: findings_total
          )
        end

        private

        # Federation-peer certs past 75% of their lifetime. The actual
        # rotation is operator-driven for v1; here we just surface the
        # candidate set.
        def cert_rotation_candidates
          ::System::FederationPeer
            .where(account_id: @account.id, peer_kind: "platform")
            .where.not(node_certificate_id: nil)
            .includes(:node_certificate)
            .filter_map do |peer|
              cert = peer.node_certificate
              next unless cert&.not_after && cert.not_before
              lifetime = cert.not_after - cert.not_before
              elapsed  = Time.current - cert.not_before
              next unless lifetime.positive? && elapsed.positive?
              ratio = elapsed / lifetime
              next unless ratio >= CERT_ROTATION_THRESHOLD_RATIO
              {
                peer_id: peer.id,
                certificate_id: cert.id,
                lifetime_ratio_elapsed: ratio.round(3),
                not_after: cert.not_after.utc.iso8601,
                days_remaining: ((cert.not_after - Time.current) / 1.day).to_i
              }
            end
        end

        def grants_approaching_expiry
          horizon = GRANT_EXPIRY_WARN_WINDOW.from_now
          ::System::FederationGrant.active
            .where(account_id: @account.id)
            .where("expires_at <= ?", horizon)
            .order(:expires_at)
            .limit(200)
            .map { |g| serialize_grant(g, extra: { expires_in_days: ((g.expires_at - Time.current) / 1.day).to_i }) }
        end

        def grants_overdue_for_review
          cutoff = GRANT_REVIEW_THRESHOLD.ago
          ::System::FederationGrant.active
            .where(account_id: @account.id)
            .where("issued_at <= ?", cutoff)
            .order(:issued_at)
            .limit(200)
            .map { |g| serialize_grant(g, extra: { age_days: ((Time.current - g.issued_at) / 1.day).to_i }) }
        end

        def broad_scope_grants
          ::System::FederationGrant.active
            .where(account_id: @account.id)
            .select { |g| (g.permission_scopes & BROAD_SCOPES).any? }
            .map { |g| serialize_grant(g, extra: { broad_scopes: g.permission_scopes & BROAD_SCOPES }) }
        end

        # A platform peer with non-empty extension_slugs but no
        # corresponding rows in system_federation_capabilities suggests
        # the capability handshake declared kinds but the operator
        # never opted them in.
        def capability_drift
          ::System::FederationPeer
            .where(account_id: @account.id, peer_kind: "platform")
            .where.not(status: "revoked")
            .filter_map do |peer|
              next unless peer.extension_slugs.any?
              cap_count = ::System::FederationCapability.where(federation_peer_id: peer.id).count
              next if cap_count > 0
              {
                peer_id: peer.id,
                extension_slugs: peer.extension_slugs,
                capability_count: cap_count
              }
            end
        end

        def serialize_grant(grant, extra: {})
          {
            grant_id: grant.id,
            federation_peer_id: grant.federation_peer_id,
            remote_subject: grant.remote_subject,
            resource_kind: grant.resource_kind,
            resource_id: grant.resource_id,
            permission_scopes: grant.permission_scopes,
            issued_at: grant.issued_at.utc.iso8601,
            expires_at: grant.expires_at.utc.iso8601
          }.merge(extra)
        end

        def emit_findings_summary!(count)
          return unless defined?(::System::Fleet::EventBroadcaster)
          return if count.zero?

          ::System::Fleet::EventBroadcaster.emit!(
            account: @account,
            kind: "federation.manager.review_completed",
            severity: count > 10 ? "high" : "medium",
            source: "federation_manager_skill",
            payload: { finding_count: count }
          )
        rescue StandardError => e
          Rails.logger.warn("[FederationManagerExecutor] event emit failed: #{e.message}")
        end
      end
    end
  end
end
