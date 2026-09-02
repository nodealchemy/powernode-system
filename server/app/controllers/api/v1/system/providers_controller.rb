# frozen_string_literal: true

module Api
  module V1
    module System
      class ProvidersController < BaseController
        before_action :set_account
        before_action :set_provider, only: [ :show, :update, :destroy ]

        def index
          require_permission("system.providers.read")
          providers = @account.system_providers
          providers = apply_filters(providers)
          providers = paginate(providers)
          render_success(providers: serialize_collection(providers), meta: pagination_meta)
        end

        def show
          require_permission("system.providers.read")
          render_success(provider: serialize_provider(@provider))
        end

        def create
          require_permission("system.providers.create")
          # APO-7 SDK guard (IMP-0ddfd8a60032) — refuse BEFORE the build, so
          # the inoperable row is never written. `return` (not a bare render):
          # a render from an action body does not halt the body.
          return if refuse_inoperable_provider_type(provider_params[:provider_type])

          provider = @account.system_providers.build(provider_params)

          if provider.save
            render_success(provider: serialize_provider(provider), status: :created)
          else
            render_validation_error(provider)
          end
        end

        def update
          require_permission("system.providers.update")
          # The second spelling of the same hazard: #create mints an
          # inoperable row, #update CONVERTS an operable one into it. Guarded
          # only on an actual type CHANGE — an existing row of an inoperable
          # type stays editable (renaming, disabling), exactly as the
          # credential-POST door leaves such a row untouched.
          return if provider_type_changing? &&
                    refuse_inoperable_provider_type(provider_params[:provider_type])

          if @provider.update(provider_params)
            render_success(provider: serialize_provider(@provider))
          else
            render_validation_error(@provider)
          end
        end

        def destroy
          require_permission("system.providers.delete")

          if @provider.destroy
            render_success(message: "Provider deleted successfully")
          else
            render_error("Failed to delete provider", status: :unprocessable_content)
          end
        end

        # Provider connection testing lives on ProviderConnectionsController
        # (POST /api/v1/system/provider_connections/:id/test). A stub `#test`
        # action used to live here unrouted; removed in audit P0.1 wave 1
        # cleanup since it was orphan code with no callers after the
        # ProviderConnections refactor.

        private

        def set_provider
          @provider = @account.system_providers.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Provider")
        end

        # APO-7 (4c04e50f) and its credential-POST follow-up (35b7ab3e) refuse
        # a provider type whose adapter SDK gem is not bundled in this build at
        # the MCP and credential writers. This controller had no predicate at
        # all, so an operator — or an agent over REST — could still obtain
        # exactly the row those writers refuse. The authoritative, executable
        # enumeration of every writer and the guard it applies is
        # spec/lint/provider_type_writer_census_spec.rb — a prose count of the
        # doors has been wrong three times running, so this comment does not
        # carry one.
        #
        # `supported?` gates the predicate: types with no registry adapter at
        # all (digitalocean/linode/vultr/custom) are outside it by design, as
        # at every other door.
        #
        # @param provider_type [String, nil] the type the request asks for
        # @return [Boolean] true when a refusal was rendered and the caller
        #   must return without writing
        def refuse_inoperable_provider_type(provider_type)
          type = provider_type.to_s
          return false if type.blank?

          registry = ::System::Providers::Registry
          return false unless registry.supported?(type)
          return false if registry.sdk_available?(type)

          render_error(registry.sdk_missing_message(type),
                       status: :unprocessable_content,
                       code: "PROVIDER_SDK_MISSING")
          true
        end

        # @return [Boolean] true when the request asks to move provider_type
        #   to a DIFFERENT value than the row currently holds
        def provider_type_changing?
          requested = provider_params[:provider_type].to_s
          requested.present? && requested != @provider.provider_type.to_s
        end

        def provider_params
          params.require(:provider).permit(
            :name, :description, :provider_type, :enabled, :public,
            config: {}, capabilities: {}
          )
        end

        def apply_filters(scope)
          scope = scope.enabled if params[:enabled] == "true"
          scope = scope.disabled if params[:enabled] == "false"
          scope = scope.by_type(params[:provider_type]) if params[:provider_type].present?
          scope.ordered
        end

        def serialize_provider(provider)
          ::System::ProviderSerializer.new(provider).as_json
        end

        def serialize_collection(providers)
          providers.map { |p| serialize_provider(p) }
        end
      end
    end
  end
end
