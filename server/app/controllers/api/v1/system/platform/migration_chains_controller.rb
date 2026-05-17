# frozen_string_literal: true

module Api
  module V1
    module System
      module Platform
        # P9.5 — Operator-facing endpoints for multi-hop migration chains.
        #
        # A chain envelopes N-1 normal Migration rows (one per hop). The
        # composer creates the envelope + hop rows in `planned`; the
        # worker (MigrationChainAdvanceJob) sweeps active chains every
        # 60s and advances them one hop at a time. Operators can also
        # advance / run-to-completion / cancel on demand from here.
        #
        # Endpoints:
        #   GET    /api/v1/system/platform/migration_chains
        #     List with summary fields. Filterable by status (comma-sep).
        #
        #   GET    /api/v1/system/platform/migration_chains/:id
        #     Full detail with hops + audit_log.
        #
        #   POST   /api/v1/system/platform/migration_chains
        #     Compose a new chain. Body:
        #       { hop_peer_ids: ["<peer-b>", "<peer-c>", ...],
        #         root_resource_kind: "skill",
        #         root_resource_id: "<uuid>",
        #         operation: "migrate" | "duplicate" }
        #     Note: `hop_peer_ids` carries only the *destination* peers
        #     in hop order. The implicit origin (this platform, "self")
        #     is prepended server-side. Callers MUST NOT send a leading
        #     `null` — ActionDispatch deep_munges it out.
        #
        #   POST   /api/v1/system/platform/migration_chains/:id/advance
        #     Advance the chain by exactly one hop.
        #
        #   POST   /api/v1/system/platform/migration_chains/:id/run
        #     Walk to completion (or first failure). Synchronous; expects
        #     short chains. For long chains, prefer letting the worker
        #     tick advance them.
        #
        #   POST   /api/v1/system/platform/migration_chains/:id/cancel
        #     Transition planned/in_flight → cancelled (terminal).
        #
        # Permissions:
        #   system.platform.read     — index + show
        #   system.migrations.apply  — create + advance + run
        #   system.migrations.cancel — cancel
        #
        # Plan reference: §F + P9.5 multi-hop migration chains.
        class MigrationChainsController < ApplicationController
          before_action :authenticate_request
          before_action :set_chain, only: %i[show advance run cancel]

          def index
            return forbidden unless current_user&.has_permission?("system.platform.read")

            chains = ::System::MigrationChain.where(account: current_account).order(created_at: :desc)
            chains = chains.where(status: params[:status].split(",")) if params[:status].present?
            chains = chains.where(operation: params[:operation]) if params[:operation].present?

            render_success(
              migration_chains: chains.map { |c| serialize_summary(c) },
              count: chains.size
            )
          end

          def show
            return forbidden unless current_user&.has_permission?("system.platform.read")
            render_success(migration_chain: serialize_full(@chain))
          end

          def create
            return forbidden unless current_user&.has_permission?("system.migrations.apply")

            # Prepend the implicit "self" origin (position 0) to whatever
            # the caller supplied. The composer treats position 0 as the
            # origin and reads destinations from position 1 onward.
            destinations = Array(params[:hop_peer_ids]).reject(&:blank?)
            hop_peer_ids = [ nil ] + destinations

            result = ::System::Migrations::ChainComposer.compose!(
              account:            current_account,
              hop_peer_ids:       hop_peer_ids,
              root_resource_kind: params[:root_resource_kind],
              root_resource_id:   params[:root_resource_id],
              operation:          params[:operation].presence || "migrate",
              initiated_by_user:  current_user
            )

            if result.ok?
              render_success(migration_chain: serialize_full(result.chain), status: :created)
            else
              render_error(result.error, status: :unprocessable_entity)
            end
          end

          def advance
            return forbidden unless current_user&.has_permission?("system.migrations.apply")

            result = ::System::Migrations::ChainExecutor.advance!(chain: @chain)
            if result.ok?
              render_success(
                migration_chain: serialize_full(@chain.reload),
                advanced_to:     result.advanced_to
              )
            else
              render_error(result.error, status: :unprocessable_entity)
            end
          end

          def run
            return forbidden unless current_user&.has_permission?("system.migrations.apply")

            result = ::System::Migrations::ChainExecutor.run_to_completion!(chain: @chain)
            if result.ok?
              render_success(
                migration_chain: serialize_full(@chain.reload),
                advanced_to:     result.advanced_to
              )
            else
              render_error(result.error, status: :unprocessable_entity)
            end
          end

          def cancel
            return forbidden unless current_user&.has_permission?("system.migrations.cancel")

            unless @chain.can_transition_to?("cancelled")
              return render_error(
                "Chain is #{@chain.status} and cannot be cancelled",
                status: :unprocessable_entity
              )
            end

            @chain.transition_to!("cancelled", audit_entry: {
              "event" => "chain_cancelled",
              "by_user_id" => current_user.id
            })
            render_success(migration_chain: serialize_full(@chain.reload))
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          def set_chain
            @chain = ::System::MigrationChain.find_by(id: params[:id], account: current_account)
            render_error("Migration chain not found", status: :not_found) unless @chain
          end

          def serialize_summary(chain)
            {
              id:                 chain.id,
              operation:          chain.operation,
              status:             chain.status,
              root_resource_kind: chain.root_resource_kind,
              root_resource_id:   chain.root_resource_id,
              current_hop_index:  chain.current_hop_index,
              total_hops:         chain.total_hops,
              terminal:           chain.terminal?,
              error_message:      chain.error_message,
              created_at:         chain.created_at&.iso8601,
              started_at:         chain.started_at&.iso8601,
              completed_at:       chain.completed_at&.iso8601,
              failed_at:          chain.failed_at&.iso8601
            }
          end

          def serialize_full(chain)
            serialize_summary(chain).merge(
              hop_peer_ids: chain.hop_peer_ids,
              hops:         chain.migrations.order(:chain_position).map { |m| serialize_hop(m) },
              audit_log:    Array(chain.audit_log),
              metadata:     chain.metadata || {},
              initiated_by_user_id: chain.initiated_by_user_id
            )
          end

          def serialize_hop(migration)
            {
              id:                  migration.id,
              chain_position:      migration.chain_position,
              status:              migration.status,
              destination_peer_id: migration.destination_peer_id,
              started_at:          migration.started_at&.iso8601,
              completed_at:        migration.completed_at&.iso8601,
              failed_at:           migration.failed_at&.iso8601,
              error_message:       migration.error_message
            }
          end
        end
      end
    end
  end
end
