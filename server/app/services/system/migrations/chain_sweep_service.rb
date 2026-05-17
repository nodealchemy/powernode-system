# frozen_string_literal: true

module System
  module Migrations
    # P9.5 — Per-tick sweep of active MigrationChain rows.
    #
    # The worker (MigrationChainAdvanceJob, cron every 60s) POSTs to
    # /worker_api/migration_chains/advance which invokes this service.
    # For each chain in `planned` or `in_flight` state, advance the
    # next pending hop one position. Idempotent: chains whose final
    # hop has already landed transition to `completed` on the next
    # advance call rather than queueing another hop.
    #
    # Per-chain failures are caught + recorded as a sweep `failure`;
    # one stuck chain doesn't poison the rest of the tick. Chains that
    # have been in `in_flight` for longer than STALL_THRESHOLD without
    # any audit-log activity are skipped (the governance scan surfaces
    # them separately as migration_chain_stalled findings).
    #
    # Plan reference: P9.5 multi-hop migration chains + §F.
    class ChainSweepService
      Result = ::Struct.new(:swept, :advanced, :completed, :failed, :failures, keyword_init: true)

      # A chain is considered stalled if it's been in_flight without
      # progress for this long. The sweep skips it so the operator
      # gets a clean governance signal before we keep retrying.
      STALL_THRESHOLD = 1.hour

      class << self
        def run!(account: nil)
          new(account: account).run!
        end
      end

      def initialize(account:)
        @account = account
      end

      def run!
        swept     = 0
        advanced  = 0
        completed = 0
        failed    = 0
        failures  = []

        chain_scope.find_each do |chain|
          swept += 1
          next if stalled?(chain)

          begin
            outcome = ::System::Migrations::ChainExecutor.advance!(chain: chain)
            chain.reload
            if outcome.ok?
              advanced += 1
              completed += 1 if chain.status == "completed"
            else
              failed += 1
              failures << { chain_id: chain.id, error: outcome.error.to_s }
            end
          rescue ::StandardError => e
            failed += 1
            failures << { chain_id: chain.id, error: "#{e.class}: #{e.message}" }
            ::Rails.logger.warn("[ChainSweepService] chain=#{chain.id} #{e.class}: #{e.message}")
          end
        end

        Result.new(
          swept:     swept,
          advanced:  advanced,
          completed: completed,
          failed:    failed,
          failures:  failures
        )
      end

      private

      def chain_scope
        scope = ::System::MigrationChain.active
        scope = scope.where(account: @account) if @account
        scope
      end

      # Don't keep retrying a chain that's gone past STALL_THRESHOLD
      # without making progress — governance will surface it; operator
      # decides whether to cancel or hand-advance.
      def stalled?(chain)
        return false unless chain.status == "in_flight"
        return false unless chain.started_at

        last_activity = chain.audit_log
                          .filter_map { |e| ::Time.zone.parse(e["at"].to_s) rescue nil }
                          .max
        anchor = last_activity || chain.started_at
        anchor < (::Time.current - STALL_THRESHOLD)
      end
    end
  end
end
