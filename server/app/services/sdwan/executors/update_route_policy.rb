# frozen_string_literal: true

module Sdwan
  module Executors
    class UpdateRoutePolicy < ::System::Executors::Base
      # Single source of this action's autonomy category (IMP-249e01a804e5).
      # Every gate site — the REST controller and Ai::Tools::SdwanTool — reads
      # it from here rather than carrying its own copy, and
      # spec/services/sdwan/executors/action_category_coherence_spec.rb pins the
      # seeded policy row and the engine registration to it.
      ACTION_CATEGORY = "sdwan.route_policy_update"

      protected

      # IMP-c9798d9d5671 — scope_resource_id is a caller-suppliable
      # re-parent (the IMP-bf996c7abcb4 ruling): the model validates only
      # presence/consistency, never ownership. RoutePolicy#applicable_to
      # filters by account at compile today, so a foreign id is inert
      # downstream — the anchor prevents persisting a silent dangling
      # foreign reference. The kind is the EFFECTIVE scope: the incoming
      # attrs[:scope] when this update changes it, else the row's own;
      # "account" names no resource, and anchor_reparent! no-ops on a
      # blank/absent id.
      def perform
        policy = resolve_scoped(::Sdwan::RoutePolicy, params[:policy_id])
        case (attrs[:scope] || policy.scope).to_s
        when "network" then anchor_reparent!(:scope_resource_id, ::Sdwan::Network)
        when "peer"    then anchor_reparent!(:scope_resource_id, ::Sdwan::Peer)
        end
        policy.update!(attrs)
        { policy_id: policy.id }
      end

      def summarize = "Update route policy #{params[:policy_id]}"
    end
  end
end
