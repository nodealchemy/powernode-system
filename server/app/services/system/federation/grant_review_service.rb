# frozen_string_literal: true

module System
  module Federation
    # Periodic federation review — invokes FederationManagerExecutor
    # for each account, aggregates findings, and emits high-severity
    # FleetEvents for the operator dashboard. Designed to run weekly.
    #
    # Plan reference: Decentralized Federation §"Fix 2" + P4.10.
    class GrantReviewService
      Result = Struct.new(:accounts_reviewed, :total_findings, :findings_by_account,
                          :ran_at, keyword_init: true)

      class << self
        def run!(account: nil)
          new.run!(account: account)
        end
      end

      def run!(account: nil)
        accounts = account ? [ account ] : federated_accounts
        findings_by_account = {}
        total = 0

        accounts.each do |acct|
          result = ::System::Ai::Skills::FederationManagerExecutor.new(account: acct).execute
          next unless result[:success]

          data = result[:data]
          count = data[:finding_count]
          findings_by_account[acct.id] = {
            cert_rotation_candidates: data[:cert_rotation_candidates].size,
            grants_approaching_expiry: data[:grants_approaching_expiry].size,
            grants_overdue_for_review: data[:grants_overdue_for_review].size,
            broad_scope_grants: data[:broad_scope_grants].size,
            capability_drift: data[:capability_drift].size,
            total: count
          }
          total += count

          emit_per_category_events!(acct, data) if count.positive?
        end

        Result.new(
          accounts_reviewed: accounts.size,
          total_findings: total,
          findings_by_account: findings_by_account,
          ran_at: Time.current
        )
      end

      private

      # Only accounts with at least one federation peer of any kind get
      # reviewed. Scanning every account would waste cycles when most
      # haven't opted in to federation.
      def federated_accounts
        account_ids = ::System::FederationPeer.distinct.pluck(:account_id).compact
        ::Account.where(id: account_ids)
      end

      # Emit a FleetEvent per category that has findings, so the operator's
      # dashboard can surface "you have 3 grants expiring soon" separately
      # from "you have 2 broad-scope grants." Per-category visibility beats
      # one giant aggregate notification.
      def emit_per_category_events!(account, data)
        return unless defined?(::System::Fleet::EventBroadcaster)

        category_severities = {
          cert_rotation_candidates: :medium,
          grants_approaching_expiry: :medium,
          grants_overdue_for_review: :low,
          broad_scope_grants: :medium,
          capability_drift: :medium
        }

        category_severities.each do |key, severity|
          rows = data[key]
          next if rows.blank?

          ::System::Fleet::EventBroadcaster.emit!(
            account: account,
            kind: "federation.review.#{key}",
            severity: severity,
            source: "federation_grant_review",
            payload: {
              count: rows.size,
              sample: rows.first(3)
            }
          )
        end
      rescue StandardError => e
        Rails.logger.warn("[GrantReviewService] event emit failed: #{e.message}")
      end
    end
  end
end
