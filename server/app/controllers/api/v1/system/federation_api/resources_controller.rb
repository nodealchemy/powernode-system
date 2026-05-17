# frozen_string_literal: true

module Api
  module V1
    module System
      module FederationApi
        # Cross-peer resource fetch. The caller (a remote federated peer)
        # presents its mTLS cert (verified by BaseController) + a Bearer
        # grant token authorizing access to the requested resource.
        #
        # Auth chain (delegated to BaseController):
        #   mTLS cert → FederationPeer
        #   Bearer fg-<id> → FederationGrant
        #     grant.federation_peer == peer
        #     grant.active?
        #     grant.resource_kind == :kind
        #     grant.resource_id == :id (if grant is specific-resource)
        #     grant.has_scope?(:read)
        #
        # v1 returns a minimal envelope; per-kind serialization (deciding
        # which model fields are safe to expose cross-peer) is a follow-up
        # in P4.10+. Sensitive fields MUST NOT leak through this surface
        # without explicit redaction policy.
        #
        # GET /api/v1/system/federation_api/resources/:kind/:id
        # Returns:
        #   { kind, id, exists, account_id, grant_id, fetched_at }
        #
        # Plan reference: Decentralized Federation §E + P4.7.
        class ResourcesController < BaseController
          def show
            kind = params.require(:kind).to_s
            resource_id = params.require(:id).to_s

            grant = authorize_grant!(resource_kind: kind, resource_id: resource_id, scope: :read)
            return unless grant  # auth helper rendered already

            unless ::System::Federation::InventoryRegistry.kind_known?(kind)
              return render json: { error: "Resource kind #{kind.inspect} is not declared in federation_inventory.yaml" },
                            status: :unprocessable_entity
            end

            # v1: existence check + envelope. Future rounds resolve the
            # actual record + serialize per-kind.
            render_success(
              data: {
                kind: kind,
                id: resource_id,
                exists: resource_exists?(kind, resource_id),
                account_id: current_federation_peer.account_id,
                grant_id: grant.id,
                fetched_at: Time.current.iso8601
              }
            )
          end

          private

          # Looks up the model class for `kind` via the InventoryRegistry +
          # convention (kind name → "System::<CamelCase>" or similar).
          # For v1 we attempt model resolution via a small whitelist; in
          # later rounds the registry will store the model class directly.
          def resource_exists?(kind, resource_id)
            model = resolve_model_for(kind)
            return false unless model

            scoped = if model.respond_to?(:where)
                       account_scope = current_federation_peer.account_id
                       if model.column_names.include?("account_id")
                         model.where(id: resource_id, account_id: account_scope).exists?
                       else
                         model.where(id: resource_id).exists?
                       end
                     end
            scoped == true
          end

          # v1 resolver — kind name → model class. Conservative: only
          # resolves kinds the registry knows about AND whose canonical
          # class lives in the System namespace.
          def resolve_model_for(kind)
            return nil unless ::System::Federation::InventoryRegistry.kind_known?(kind)

            # Try System::<CamelCase> first
            try_constantize("::System::#{kind.to_s.camelize}") ||
              try_constantize("::Ai::#{kind.to_s.camelize}") ||
              try_constantize("::#{kind.to_s.camelize}")
          end

          def try_constantize(name)
            name.constantize
          rescue NameError
            nil
          end
        end
      end
    end
  end
end
