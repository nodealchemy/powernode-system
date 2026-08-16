# frozen_string_literal: true

# CRUD for Sdwan::RoutePolicy. Account-scoped — every policy is keyed
# to the caller's account; the resolver inside the model checks
# scope_resource_id consistency at validation time.
#
# Slice 9e of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class RoutePoliciesController < ::Api::V1::System::BaseController
          include ::System::GatedActions

          before_action :set_account
          before_action :set_policy, only: %i[show update destroy compile]

          def index
            require_permission("system.sdwan.route_policies.read")
            scope = ::Sdwan::RoutePolicy.where(account_id: @account.id)
            scope = scope.where(scope: params[:scope]) if params[:scope].present?
            scope = scope.where(direction: params[:direction]) if params[:direction].present?
            scope = scope.where(scope_resource_id: params[:scope_resource_id]) if params[:scope_resource_id].present?

            policies = scope.order(:scope, :name)
            render_success(route_policies: policies.map { |p| serialize(p) }, count: policies.size)
          end

          def show
            require_permission("system.sdwan.route_policies.read")
            render_success(route_policy: serialize_full(@policy))
          end

          # IMP-3173b0441be2: both writes route through Ai::AutonomyGate.
          # Sdwan::Executors::{Create,Update}RoutePolicy existed but had no
          # caller, so the seeded sdwan.route_policy_{create,update} policies
          # matched nothing — while DELETE below has been gated since slice 9e.
          # A policy that rewrites a peer's iBGP advertisements is at least as
          # consequential as removing one.
          #
          # Response contract mirrors DELETE: an operator carries no agent, the
          # seeded sdwan.route_policy_* policies are ai_agent_id-scoped to the
          # SDWAN Manager, so Ai::InterventionPolicy#agent_matches? rejects them
          # for an agent-less request and InterventionPolicyService falls through
          # to require_approval — 202, the row appearing at approval time. The
          # executor performs the write, since gate! never calls on_proceed on
          # its :pending branch. 201/200 with the row is the :proceed branch.
          def create
            require_permission("system.sdwan.route_policies.manage")
            attrs = policy_params.to_h
            # Never saved — CreateRoutePolicy's create! stays the only writer,
            # and it takes the account from the operation. gate_create!
            # validates this candidate BEFORE the gate, so an unsaveable
            # payload keeps its field-level 422 and opens no audit row for an
            # operation that could never run (Ai::GatedActions#gate_create!).
            candidate = ::Sdwan::RoutePolicy.new(attrs.merge(account_id: @account.id))

            gate_create!(
              candidate: candidate,
              # RoutePolicy belongs directly to the account, so unlike the
              # network-nested creates there is no parent association to
              # re-find through — the model itself is the scope, exactly as
              # the inline on_proceed used it. `scope:` is duck-typed on #find,
              # so a relation and a model class both satisfy it.
              scope: ::Sdwan::RoutePolicy,
              result_key: :policy_id,
              response_key: :route_policy,
              serializer: ->(p) { serialize_full(p) },
              action_category: ::Sdwan::Executors::CreateRoutePolicy::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::CreateRoutePolicy",
              params: { attributes: attrs },
              # Provenance only: RoutePolicy belongs directly to the account, so
              # there is no parent row to anchor. PHASE 0 no-ops on Account (it
              # carries no account_id); the executor's `account` is the anchor.
              source_type: "Account",
              source_id: @account.id,
              description: "Create SDWAN route policy #{candidate.name}"
            )
          end

          def update
            require_permission("system.sdwan.route_policies.manage")
            attrs = policy_params.to_h
            @policy.assign_attributes(attrs)
            return render_validation_error(@policy) unless @policy.valid?

            # Discard the un-gated in-memory changes: nothing may reach the row
            # except through the executor.
            @policy.reload

            gate!(
              action_category: ::Sdwan::Executors::UpdateRoutePolicy::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::UpdateRoutePolicy",
              params: { policy_id: @policy.id, attributes: attrs },
              source_type: "Sdwan::RoutePolicy",
              source_id: @policy.id,
              description: "Update SDWAN route policy #{@policy.name}",
              on_proceed: ->(_r) { render_success(route_policy: serialize_full(@policy.reload)) }
            )
          end

          def destroy
            require_permission("system.sdwan.route_policies.manage")
            id = @policy.id
            name = @policy.name
            gate!(
              action_category: ::Sdwan::Executors::DeleteRoutePolicy::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::DeleteRoutePolicy",
              params: { policy_id: id },
              source_type: "Sdwan::RoutePolicy",
              source_id: id,
              description: "Delete route policy '#{name}'",
              on_proceed: ->(_r) { render_success(deleted: true, id: id) }
            )
          end

          # GET /route_policies/:id/compile?peer_id=<uuid>
          # Returns the FRR fragment this policy compiles to in the
          # context of a specific peer. Useful for "what does my policy
          # look like in production?" debugging.
          def compile
            require_permission("system.sdwan.route_policies.read")
            peer_id = params[:peer_id]
            return render_error("peer_id required", status: :bad_request) if peer_id.blank?

            peer = ::Sdwan::Peer.joins(:network)
                                .where(system_sdwan_networks: { account_id: @account.id })
                                .find_by(id: peer_id)
            return render_not_found("Peer") unless peer

            output = ::Sdwan::Bgp::RoutePolicyCompiler.compile_for_peer(peer)
            render_success(
              policy_id: @policy.id,
              peer_id: peer.id,
              compiled: output,
              note: "compile is per-peer; output reflects ALL applicable policies, not just this one"
            )
          end

          private

          def set_policy
            @policy = ::Sdwan::RoutePolicy.where(account_id: @account.id).find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("Route Policy")
          end

          def policy_params
            params.require(:route_policy).permit(
              :name, :description, :scope, :scope_resource_id, :direction, :enabled,
              statements: [
                {
                  match:  [ :as_path_regex, prefix_in: [], community_in: [], tag_in: [], peer_in: [] ],
                  action: [ :type, :set_local_pref, :set_med, :prepend_as_path, :add_community ]
                }
              ],
              metadata: {}
            )
          end

          def serialize(p)
            {
              id: p.id,
              name: p.name,
              description: p.description,
              scope: p.scope,
              scope_resource_id: p.scope_resource_id,
              direction: p.direction,
              enabled: p.enabled,
              statement_count: Array(p.statements).size,
              slug: p.slug,
              created_at: p.created_at&.iso8601,
              updated_at: p.updated_at&.iso8601
            }
          end

          def serialize_full(p)
            serialize(p).merge(
              statements: p.statements,
              metadata: p.metadata
            )
          end
        end
      end
    end
  end
end
