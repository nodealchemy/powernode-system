# frozen_string_literal: true

module System
  module Federation
    # Archives revoked FederationGrant rows past the 90-day retention
    # window (per Architectural Fix 3 of the Decentralized Federation
    # plan). Designed to run daily; idempotent — re-runs are no-ops once
    # eligible rows are processed.
    #
    # When invoked from a Sidekiq tick, the worker calls a worker_api
    # endpoint that delegates here. Direct call (`account: nil`) sweeps
    # every account; `account:` scopes to one.
    #
    # Plan reference: Decentralized Federation §"Fix 3" + P4.9.
    class GrantArchivalService
      Result = Struct.new(:archived, :archived_ids, :ran_at, :scope, keyword_init: true)

      class << self
        def run!(account: nil)
          new.run!(account: account)
        end
      end

      def run!(account: nil)
        scope_label = account ? "account:#{account.id}" : "all_accounts"
        relation = ::System::FederationGrant.ready_for_archival
        relation = relation.where(account_id: account.id) if account

        archived_ids = []

        relation.find_each(batch_size: 200) do |grant|
          next unless grant.archive!
          archived_ids << grant.id
          emit_event!(grant)
        end

        Result.new(
          archived: archived_ids.size,
          archived_ids: archived_ids,
          ran_at: Time.current,
          scope: scope_label
        )
      end

      private

      def emit_event!(grant)
        return unless defined?(::System::Fleet::EventBroadcaster)

        ::System::Fleet::EventBroadcaster.emit!(
          account: grant.account,
          kind: "federation.grant.archived",
          severity: "low",
          source: "federation_grant_archival",
          payload: {
            grant_id: grant.id,
            federation_peer_id: grant.federation_peer_id,
            remote_subject: grant.remote_subject,
            resource_kind: grant.resource_kind,
            revoked_at: grant.revoked_at&.iso8601,
            revocation_reason: grant.revocation_reason
          }
        )
      rescue StandardError => e
        Rails.logger.warn("[GrantArchivalService] event emit failed: #{e.message}")
      end
    end
  end
end
