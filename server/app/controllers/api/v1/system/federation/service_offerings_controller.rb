# frozen_string_literal: true

module Api
  module V1
    module System
      module Federation
        # Operator-side admin endpoints for managing the platform's
        # own ServiceOffering catalog. Distinct from federation_api/
        # service_catalog (which exposes the catalog to remote peers
        # via mTLS); this lives under operator JWT auth and is what
        # the offerings-editor frontend talks to.
        #
        # Routes:
        #   GET    /api/v1/system/federation/service_offerings
        #   GET    /api/v1/system/federation/service_offerings/:id
        #   POST   /api/v1/system/federation/service_offerings
        #   PATCH  /api/v1/system/federation/service_offerings/:id
        #   DELETE /api/v1/system/federation/service_offerings/:id
        #   POST   /api/v1/system/federation/service_offerings/:id/activate
        #   POST   /api/v1/system/federation/service_offerings/:id/deprecate
        #   POST   /api/v1/system/federation/service_offerings/:id/retire
        #
        # Permissions:
        #   system.service_offerings.read  — list + show
        #   system.service_offerings.manage — create + update + delete + state transitions
        #
        # Plan reference: Decentralized Federation §L.7 + P4.6.8.
        class ServiceOfferingsController < ApplicationController
          before_action :set_offering, only: %i[show update destroy activate deprecate retire]

          def index
            authorize_read!
            offerings = ::System::Federation::ServiceOffering
                          .where(account: current_account)
                          .order(:name)
            offerings = offerings.where(status: params[:status].split(",")) if params[:status].present?
            render_success(
              offerings: offerings.map { |o| serialize(o) },
              count: offerings.count
            )
          end

          def show
            authorize_read!
            render_success(offering: serialize(@offering, full: true))
          end

          def create
            authorize_manage!
            offering = ::System::Federation::ServiceOffering.new(
              create_params.merge(account: current_account)
            )
            if offering.save
              render_success({ offering: serialize(offering, full: true) }, status: :created)
            else
              render_error(offering.errors.full_messages.join("; "), status: :unprocessable_entity)
            end
          end

          def update
            authorize_manage!
            if @offering.update(update_params)
              render_success(offering: serialize(@offering, full: true))
            else
              render_error(@offering.errors.full_messages.join("; "), status: :unprocessable_entity)
            end
          end

          def destroy
            authorize_manage!
            if @offering.terminal?
              return render_error("Offering already retired", status: :conflict)
            end

            if @offering.retire!(reason: params[:reason])
              render_success(offering: serialize(@offering.reload, full: true))
            else
              render_error("Could not retire offering (status=#{@offering.status})",
                           status: :unprocessable_entity)
            end
          end

          def activate
            authorize_manage!
            if @offering.activate!
              render_success(offering: serialize(@offering.reload, full: true))
            else
              render_error("Cannot activate from status=#{@offering.status}",
                           status: :unprocessable_entity)
            end
          end

          def deprecate
            authorize_manage!
            if @offering.deprecate!(reason: params[:reason])
              render_success(offering: serialize(@offering.reload, full: true))
            else
              render_error("Cannot deprecate from status=#{@offering.status}",
                           status: :unprocessable_entity)
            end
          end

          def retire
            authorize_manage!
            if @offering.retire!(reason: params[:reason])
              render_success(offering: serialize(@offering.reload, full: true))
            else
              render_error("Cannot retire from status=#{@offering.status}",
                           status: :unprocessable_entity)
            end
          end

          private

          def set_offering
            @offering = ::System::Federation::ServiceOffering.find_by(
              id: params[:id], account: current_account
            )
            render_error("Offering not found", status: :not_found) unless @offering
          end

          def authorize_read!
            return if current_user&.has_permission?("system.service_offerings.read")
            render_error("Forbidden", status: :forbidden)
          end

          def authorize_manage!
            return if current_user&.has_permission?("system.service_offerings.manage")
            render_error("Forbidden", status: :forbidden)
          end

          def create_params
            params.permit(:slug, :name, :description_markdown, :protocol,
                          :backend_vip_id, :backend_host, :backend_port,
                          :subscription_terms_markdown, :default_grant_ttl_days,
                          default_grant_scopes: [],
                          capacity_metadata: {}, latency_metadata: {}, metadata: {})
          end

          def update_params
            # Updates can change everything except slug (slug is the
            # stable identifier subscribers reference; renaming it
            # would orphan their subscriptions).
            params.permit(:name, :description_markdown, :protocol,
                          :backend_vip_id, :backend_host, :backend_port,
                          :subscription_terms_markdown, :default_grant_ttl_days,
                          default_grant_scopes: [],
                          capacity_metadata: {}, latency_metadata: {}, metadata: {})
          end

          def serialize(offering, full: false)
            base = {
              id: offering.id,
              slug: offering.slug,
              name: offering.name,
              protocol: offering.protocol,
              status: offering.status,
              backend_port: offering.backend_port,
              backend_host: offering.backend_host,
              backend_vip_id: offering.backend_vip_id,
              default_grant_ttl_days: offering.default_grant_ttl_days,
              default_grant_scopes: offering.default_grant_scopes,
              capacity_metadata: offering.capacity_metadata,
              latency_metadata: offering.latency_metadata,
              accepting_new_subscriptions: offering.accepting_subscriptions?,
              active_subscription_count: offering.active_subscription_count,
              created_at: offering.created_at&.iso8601,
              updated_at: offering.updated_at&.iso8601
            }
            return base unless full
            base.merge(
              description_markdown: offering.description_markdown,
              subscription_terms_markdown: offering.subscription_terms_markdown,
              deprecated_at: offering.deprecated_at&.iso8601,
              retired_at: offering.retired_at&.iso8601,
              metadata: offering.metadata
            )
          end
        end
      end
    end
  end
end
