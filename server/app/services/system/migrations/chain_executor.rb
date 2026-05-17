# frozen_string_literal: true

module System
  module Migrations
    # P9.5 — Execute a MigrationChain hop-by-hop.
    #
    # Two callsite shapes:
    #   1. `advance!(chain:)` — runs the next pending hop, transitions
    #      the chain accordingly. Idempotent: re-running on a chain
    #      whose current hop is still applying is a no-op.
    #   2. `run_to_completion!(chain:)` — walks all hops in sequence
    #      until one fails or all succeed. Synchronous; used by the
    #      operator-driven CLI / smoke test.
    #
    # The actual single-hop work is delegated to the existing
    # `ApplyExecutor` (P5.7); this orchestrator is just the chain
    # state machine + per-hop dispatch.
    #
    # Per Locked Decision #14, at no point does the chain's UUID
    # live on multiple peers — each hop is a P5 migrate where source
    # deletes after dest acks.
    class ChainExecutor
      Result = ::Struct.new(:ok?, :chain, :advanced_to, :error, keyword_init: true)

      class << self
        def advance!(chain:)
          new(chain: chain).advance!
        end

        def run_to_completion!(chain:)
          new(chain: chain).run_to_completion!
        end
      end

      def initialize(chain:)
        @chain = chain
      end

      def advance!
        return Result.new(ok?: false, chain: @chain, error: "chain is #{@chain.status}") if @chain.terminal?

        if @chain.current_hop_index >= @chain.total_hops
          return finish_chain!
        end

        unless @chain.status == "in_flight"
          @chain.transition_to!("in_flight",
                                 audit_entry: { "event" => "chain_started" })
        end

        hop = @chain.current_hop_migration
        unless hop
          fail_chain!("hop at position #{@chain.current_hop_index} is missing — chain composition damaged")
          return Result.new(ok?: false, chain: @chain.reload, error: "missing hop")
        end

        outcome = apply_hop!(hop)
        if outcome.respond_to?(:ok?) && outcome.ok?
          new_index = @chain.current_hop_index + 1
          @chain.update!(current_hop_index: new_index)
          @chain.append_audit!(
            "event"          => "hop_applied",
            "position"       => @chain.current_hop_index - 1,
            "destination"    => hop.destination_peer_id,
            "applied_count"  => outcome.applied_count
          )
          return finish_chain! if new_index >= @chain.total_hops
          Result.new(ok?: true, chain: @chain.reload, advanced_to: new_index)
        else
          err = outcome.respond_to?(:error) ? outcome.error : "hop apply failed"
          fail_chain!(err, position: @chain.current_hop_index)
          Result.new(ok?: false, chain: @chain.reload, error: err)
        end
      end

      def run_to_completion!
        loop do
          result = advance!
          return result unless result.ok?
          return result if @chain.reload.terminal?
        end
      end

      private

      def apply_hop!(hop_migration)
        ::System::Migrations::ApplyExecutor.apply!(migration: hop_migration)
      rescue ::StandardError => e
        ::Struct.new(:ok?, :error, keyword_init: true).new(ok?: false, error: "#{e.class}: #{e.message}")
      end

      def finish_chain!
        @chain.transition_to!("completed",
                              audit_entry: { "event" => "chain_completed", "hops" => @chain.total_hops })
        Result.new(ok?: true, chain: @chain.reload, advanced_to: @chain.total_hops)
      end

      def fail_chain!(reason, position: nil)
        @chain.update!(error_message: reason.to_s[0, 1000])
        @chain.transition_to!("failed",
                              audit_entry: {
                                "event"    => "chain_failed",
                                "position" => position || @chain.current_hop_index,
                                "reason"   => reason
                              })
      end
    end
  end
end
