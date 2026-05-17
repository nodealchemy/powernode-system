# frozen_string_literal: true

module Api
  module V1
    module System
      module FederationApi
        # Receives a serialized Migration plan from a federated peer
        # and applies it transactionally to the local DB. The
        # destination side of the cross-peer migration handshake.
        #
        # Auth chain (delegated to BaseController):
        #   mTLS cert      → System::FederationPeer  (peer-level identity)
        #   Bearer fg-<id> → System::FederationGrant
        #     - grant.federation_peer == peer
        #     - grant.active?
        #     - grant.resource_kind == root_resource_kind
        #       (or grant is kind-wide: resource_id nil)
        #     - grant.has_scope?(:migrate)
        #     - pessimistic checks: instance / network / source_cidrs
        #
        # POST /api/v1/system/federation_api/migrations
        # Body (JSON):
        #   {
        #     operation:           "duplicate" | "migrate",
        #     root_resource_kind:  "module_service",
        #     root_resource_id:    "<uuid>",
        #     plan_summary:        { ... },
        #     steps: [
        #       { step_order, resource_kind, resource_id, action,
        #         conflict_policy, payload, metadata }
        #     ]
        #   }
        #
        # Responses:
        #   201 Created:           { data: { migration_id, status: "completed",
        #                                     applied_count, skipped_count } }
        #   422 Unprocessable:     { error, migration_id, status: "failed" }
        #     (plan accepted + applied, but ApplyExecutor rolled back
        #      on a conflict / link_local miss / save failure)
        #   400 Bad Request:       malformed payload (missing required fields,
        #                          empty steps array, invalid step shape)
        #   401 Unauthorized:      mTLS / Bearer-grant auth failure
        #   403 Forbidden:         grant scope / pessimistic-scope mismatch
        #
        # Migration ownership semantics: the destination-side Migration
        # row records the SOURCE peer id in metadata.source_peer_id
        # (the destination_peer column is nil — we ARE the destination,
        # so there's no further destination beyond us). The grant id is
        # recorded too so audit can correlate the migration with the
        # authorization context.
        #
        # Plan reference: Decentralized Federation §F + P5.7 + P5.8.
        class MigrationsController < BaseController
          # `steps` is checked separately (must be non-empty + each step
          # valid), so it lives outside this list — otherwise an
          # `steps: []` body would fall through the "missing fields"
          # branch instead of the dedicated "at least one step" message.
          REQUIRED_TOP_FIELDS = %w[operation root_resource_kind root_resource_id].freeze
          REQUIRED_STEP_FIELDS = %w[step_order resource_kind resource_id action conflict_policy].freeze

          def create
            return unless validate_payload!

            grant = authorize_grant!(
              resource_kind: params[:root_resource_kind].to_s,
              resource_id: params[:root_resource_id].to_s,
              scope: :migrate
            )
            return unless grant

            unless ::System::Federation::InventoryRegistry.kind_known?(params[:root_resource_kind])
              return render json: {
                error: "Resource kind #{params[:root_resource_kind].inspect} not declared in federation_inventory.yaml"
              }, status: :unprocessable_entity
            end

            migration = build_migration!(grant)
            build_plan_steps!(migration)

            result = ::System::Migrations::ApplyExecutor.apply!(migration: migration)

            if result.ok?
              render json: {
                data: {
                  migration_id: migration.id,
                  status: migration.reload.status,
                  applied_count: result.applied_count,
                  skipped_count: result.skipped_count
                }
              }, status: :created
            else
              render json: {
                error: result.error,
                migration_id: migration.id,
                status: migration.reload.status
              }, status: :unprocessable_entity
            end
          rescue ActiveRecord::RecordInvalid => e
            render json: { error: "Invalid payload: #{e.message}" }, status: :bad_request
          end

          private

          def validate_payload!
            missing = REQUIRED_TOP_FIELDS.reject { |f| params[f].present? }
            if missing.any?
              render json: { error: "Missing required fields: #{missing.join(', ')}" },
                     status: :bad_request
              return false
            end

            unless ::System::Migration::OPERATIONS.include?(params[:operation].to_s)
              render json: { error: "operation must be one of #{::System::Migration::OPERATIONS.inspect}" },
                     status: :bad_request
              return false
            end

            steps = Array(params[:steps])
            if steps.empty?
              render json: { error: "Plan must contain at least one step" },
                     status: :bad_request
              return false
            end

            bad_indexes = steps.each_with_index.filter_map do |s, i|
              i if REQUIRED_STEP_FIELDS.any? { |f| s[f].nil? && s[f.to_sym].nil? }
            end
            if bad_indexes.any?
              render json: { error: "Steps missing required fields: indexes=#{bad_indexes.inspect}" },
                     status: :bad_request
              return false
            end

            true
          end

          def build_migration!(grant)
            ::System::Migration.create!(
              account: current_federation_peer.account,
              destination_peer: nil,
              operation: params[:operation].to_s,
              root_resource_kind: params[:root_resource_kind].to_s,
              root_resource_id: params[:root_resource_id].to_s,
              status: "transferring",
              dry_run: false,
              plan_summary: (params[:plan_summary] || {}).to_unsafe_h,
              metadata: {
                "source_peer_id" => current_federation_peer.id,
                "source_account_id" => current_federation_peer.account_id,
                "grant_id" => grant.id,
                "received_at" => Time.current.iso8601
              }
            )
          end

          def build_plan_steps!(migration)
            Array(params[:steps]).each do |step_data|
              ::System::MigrationPlanStep.create!(
                migration: migration,
                step_order: step_data["step_order"].to_i,
                resource_kind: step_data["resource_kind"].to_s,
                resource_id: step_data["resource_id"].to_s,
                action: step_data["action"].to_s,
                conflict_policy: step_data["conflict_policy"].to_s,
                payload: deep_to_h(step_data["payload"]) || {},
                metadata: deep_to_h(step_data["metadata"]) || {}
              )
            end
          end

          # ActionController params come in as ActionController::Parameters
          # objects; nested values need `to_unsafe_h` to flatten back to
          # plain hashes for storage in JSONB columns.
          def deep_to_h(value)
            case value
            when ActionController::Parameters then value.to_unsafe_h
            when Hash then value
            else value
            end
          end
        end
      end
    end
  end
end
