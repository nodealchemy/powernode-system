# frozen_string_literal: true

module Api
  module V1
    module System
      module Platform
        # Operator-side admin endpoints for the "Scaling" panel in the
        # /app/system/compute/platform dashboard. Reads PlatformDeployment
        # rows (which map service roles → NodeTemplate + VIP) and
        # computes the actual_replica_count by joining through Node →
        # NodeInstance for the deployment's template.
        #
        # Endpoints:
        #   GET    /api/v1/system/platform/deployments
        #     Lists deployments with computed actual_replicas.
        #
        #   PATCH  /api/v1/system/platform/deployments/:id
        #     Updates target_replicas and/or public_dns_hostname. Does
        #     NOT trigger provisioning — that orchestration is queued
        #     for a follow-up slice. For now the panel records intent,
        #     emits a FleetEvent, and the operator follows up manually
        #     via the existing provisioning surfaces.
        #
        # Permissions:
        #   system.platform.read  — index
        #   system.platform.scale — update
        #
        # Plan reference: Decentralized Federation §G + §I + P7.3.
        class DeploymentsController < ApplicationController
          before_action :authenticate_request
          before_action :set_deployment, only: %i[show update]

          # D4.1 — Wizard payload. Same shape the platform_deploy skill
          # emits in its no-args branch; chat card AND the standalone
          # /app/system/compute/platform/deploy page consume this one
          # source of truth. Permission: system.platform.read (the
          # payload is descriptive only, no mutations).
          def wizard
            return forbidden unless current_user&.has_permission?("system.platform.read")

            executor = ::System::Ai::Skills::PlatformDeployExecutor.new(
              account: current_account, user: current_user
            )
            result = executor.execute # no-args branch returns wizard payload
            if result[:success]
              render_success(result[:data])
            else
              render_error("Wizard payload failed: #{result[:error]}",
                          status: :internal_server_error)
            end
          end

          # POST — orchestrates a new platform deployment (standalone OR
          # federated). Distinct from `update` which only mutates
          # target_replicas on an existing row. Plan ref: D1.2.
          def create
            return forbidden unless current_user&.has_permission?("system.platform.deploy")

            mode = params[:mode].to_s.strip
            unless ::System::PlatformDeploymentOrchestrator::MODES.include?(mode)
              return render_error(
                "invalid mode (allowed: #{::System::PlatformDeploymentOrchestrator::MODES.inspect})",
                status: :bad_request
              )
            end

            deploy_params = sanitized_deploy_params

            result = ::System::PlatformDeploymentOrchestrator.deploy!(
              account: current_account,
              mode: mode,
              params: deploy_params,
              initiated_by_user: current_user
            )

            if result.ok?
              status_code = mode == "federated" ? :created : :accepted
              render_success(
                {
                  deployment: deployment_envelope(result),
                  # Acceptance token shown ONCE — operator must capture
                  # before navigating away (federated mode only).
                  acceptance_token: result.acceptance_token,
                  spawn_payload: result.spawn_payload
                }.compact,
                status: status_code
              )
            else
              render_error("Deploy failed: #{result.error}", status: :unprocessable_entity)
            end
          end

          def index
            return forbidden unless current_user&.has_permission?("system.platform.read")

            deployments = ::System::PlatformDeployment.where(account: current_account)
                                                       .includes(:node_template, :virtual_ip)
                                                       .order(:service_role, :name)

            render_success(
              deployments: deployments.map { |d| serialize(d) },
              count: deployments.size
            )
          end

          def show
            return forbidden unless current_user&.has_permission?("system.platform.read")
            render_success(deployment: serialize(@deployment))
          end

          def update
            return forbidden unless current_user&.has_permission?("system.platform.scale")

            new_target = params[:target_replicas]
            new_dns    = params[:public_dns_hostname]

            attrs = {}
            if new_target.present?
              t = new_target.to_i
              if t.negative?
                return render_error("target_replicas must be >= 0", status: :bad_request)
              end
              attrs[:target_replicas] = t
            end
            attrs[:public_dns_hostname] = new_dns if params.key?(:public_dns_hostname)

            if attrs.empty?
              return render_error("No mutable fields supplied (target_replicas or public_dns_hostname)",
                                  status: :bad_request)
            end

            previous_target = @deployment.target_replicas
            if @deployment.update(attrs)
              emit_scale_event!(@deployment, previous_target: previous_target)
              render_success(deployment: serialize(@deployment.reload))
            else
              render_error("Update failed: #{@deployment.errors.full_messages.join(', ')}",
                          status: :unprocessable_entity)
            end
          end

          private

          def forbidden
            render_error("Forbidden", status: :forbidden)
          end

          def sanitized_deploy_params
            permitted = %i[
              name template_slug node_id provider_region_id provider_instance_type_id
              region instance_size service_role public_dns_hostname
              parent_url spawn_mode token_ttl_seconds record_deployment
              volume_id skip_volume volume_attach
            ]
            params.permit(*permitted).to_h.symbolize_keys
          end

          def deployment_envelope(result)
            envelope = {
              mode: result.mode,
              node_instance_id: result.node_instance_id,
              federation_peer_id: result.federation_peer_id,
              platform_deployment_id: result.platform_deployment_id
            }
            if result.platform_deployment_id.present?
              row = ::System::PlatformDeployment.find_by(id: result.platform_deployment_id)
              envelope[:deployment] = serialize(row) if row
            end
            envelope
          end

          def set_deployment
            @deployment = ::System::PlatformDeployment.find_by(id: params[:id], account: current_account)
            render_error("Deployment not found", status: :not_found) unless @deployment
          end

          def serialize(deployment)
            actual, by_status = compute_actual_replicas(deployment)
            {
              id: deployment.id,
              name: deployment.name,
              service_role: deployment.service_role,
              target_replicas: deployment.target_replicas,
              actual_replicas: actual,
              actual_by_status: by_status,
              public_dns_hostname: deployment.public_dns_hostname,
              satellite_extension_slug: deployment.satellite_extension_slug,
              node_template: deployment.node_template && {
                id: deployment.node_template.id,
                name: deployment.node_template.name,
                slug: deployment.node_template.respond_to?(:slug) ? deployment.node_template.slug : nil
              },
              virtual_ip: deployment.virtual_ip && {
                id: deployment.virtual_ip.id,
                cidr: deployment.virtual_ip.cidr,
                preferred_endpoint: deployment.preferred_endpoint
              },
              metadata: deployment.metadata,
              created_at: deployment.created_at.iso8601,
              updated_at: deployment.updated_at.iso8601
            }
          end

          # Counts active NodeInstance rows whose Node references the
          # deployment's template. "active" = pending|provisioning|running|stopped
          # (anything not terminated/errored). The Node model overrides
          # table_name to "system_nodes" so the WHERE clause references
          # the actual table name, not the association name.
          def compute_actual_replicas(deployment)
            return [ 0, {} ] unless deployment.node_template_id

            instance_scope = ::System::NodeInstance
                               .joins(:node)
                               .where(system_nodes: { node_template_id: deployment.node_template_id,
                                                       account_id: current_account.id })
            [ instance_scope.active.count, instance_scope.group(:status).count ]
          rescue StandardError
            [ 0, {} ]
          end

          def emit_scale_event!(deployment, previous_target:)
            return unless defined?(::FleetEvent)
            return if previous_target == deployment.target_replicas

            ::FleetEvent.create!(
              account_id: current_account.id,
              kind: "platform.scale.intent",
              severity: "info",
              payload: {
                deployment_id: deployment.id,
                service_role: deployment.service_role,
                previous_target: previous_target,
                new_target: deployment.target_replicas
              },
              correlation_id: deployment.id
            )
          rescue StandardError
            # Event emission is opportunistic — never block the response
          end
        end
      end
    end
  end
end
