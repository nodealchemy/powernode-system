# frozen_string_literal: true

module Api
  module V1
    module System
      class ProviderConnectionsController < BaseController
        before_action :set_account
        before_action :set_connection, only: [ :show, :update, :destroy, :test, :sync_catalog ]

        def index
          require_permission("system.connections.read")
          connections = @account.system_provider_connections.includes(:provider)
          connections = apply_filters(connections)
          connections = paginate(connections)
          render_success(provider_connections: serialize_collection(connections), meta: pagination_meta)
        end

        def show
          require_permission("system.connections.read")
          render_success(provider_connection: serialize_connection(@connection))
        end

        def create
          require_permission("system.connections.create")
          connection = @account.system_provider_connections.build(connection_params)

          # APO-7: a connection to a provider whose adapter cannot run here
          # is unusable — #test and every provisioning call would raise a bare
          # NameError from inside the adapter. Refuse in front of the operator
          # with the gem name. `return` is load-bearing: rendering from an
          # action body does not halt, and the save below would still land.
          if (refusal = provider_sdk_refusal(connection.provider))
            return render_error(refusal, status: :unprocessable_content)
          end

          if connection.save
            render_success(provider_connection: serialize_connection(connection), status: :created)
          else
            render_validation_error(connection)
          end
        end

        def update
          require_permission("system.connections.update")

          # APO-7: connection_params permits :provider_id, so a guard that
          # lived only in #create would be undone by one PATCH. The invariant
          # is a property of the CONNECTION — its provider's adapter must be
          # able to run here — so it is re-checked against the provider the
          # update is aiming at (falling back to the current one).
          target_provider = ::System::Provider.find_by(id: connection_params[:provider_id]) || @connection.provider
          if (refusal = provider_sdk_refusal(target_provider))
            return render_error(refusal, status: :unprocessable_content)
          end

          if @connection.update(connection_params)
            render_success(provider_connection: serialize_connection(@connection))
          else
            render_validation_error(@connection)
          end
        end

        def destroy
          require_permission("system.connections.delete")

          if @connection.destroy
            render_success(message: "Connection deleted successfully")
          else
            render_error("Failed to delete connection", status: :unprocessable_content)
          end
        end

        # POST /api/v1/system/provider_connections/:id/test
        # Live credential check. Resolves the provider adapter, calls its
        # `test_connection`, persists the outcome on the connection, and
        # returns the result so the operator UI can render pass/fail.
        def test
          require_permission("system.connections.test")
          result = @connection.test_connection!

          payload = {
            provider_connection: serialize_connection(@connection.reload),
            test_result: result
          }

          if result[:success]
            render_success(payload)
          else
            render_error(result[:error] || "Connection test failed", status: :unprocessable_content, data: payload)
          end
        end

        # POST /api/v1/system/provider_connections/:id/sync_catalog
        # Imports the cloud's catalog (regions, AZs, instance types, volume
        # types) into the platform's catalog tables. Idempotent.
        def sync_catalog
          require_permission("system.connections.update")
          result = ::System::Providers::CatalogSyncService.sync_for(@connection)

          if result.success?
            render_success(
              provider_connection: serialize_connection(@connection.reload),
              catalog: result.data
            )
          else
            render_error(result.error, status: :unprocessable_content, data: { catalog: result.data })
          end
        end

        private

        def set_connection
          @connection = @account.system_provider_connections.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Provider Connection")
        end

        # @param provider [System::Provider, nil]
        # @return [String, nil] refusal text naming the missing gem, or nil
        def provider_sdk_refusal(provider)
          provider_type = provider&.provider_type
          return nil if provider_type.blank?

          registry = ::System::Providers::Registry
          return nil unless registry.supported?(provider_type)
          return nil if registry.sdk_available?(provider_type)

          registry.sdk_missing_message(provider_type)
        end

        def connection_params
          params.require(:provider_connection).permit(
            :name, :description, :provider_id, :endpoint_url, :enabled,
            :access_key, :secret_key, :tenant,
            config: {}
          )
        end

        def apply_filters(scope)
          scope = scope.enabled if params[:enabled] == "true"
          scope = scope.disabled if params[:enabled] == "false"
          scope = scope.where(status: params[:status]) if params[:status].present?
          scope = scope.for_provider(params[:provider_id]) if params[:provider_id].present?
          scope
        end

        def serialize_connection(connection)
          ::System::ProviderConnectionSerializer.new(connection).as_json
        end

        def serialize_collection(connections)
          connections.map { |c| serialize_connection(c) }
        end
      end
    end
  end
end
