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
        #     Updates target_replicas and/or public_dns_hostname, and
        #     RECONCILES the live replica count to the new target through
        #     System::Platform::ReplicaReconciler — the same actuator the
        #     platform_resilience skill's `scale` branch drives. The
        #     reconcile outcome rides back in the response so the panel can
        #     say what actually converged. (IMP-f4fe1ed1ec1e.)
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
              render_error("Deploy failed: #{result.error}", status: :unprocessable_content)
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

          # IMP-f4fe1ed1ec1e. This was the last OPERATOR-FACING
          # target_replicas writer with no actuator behind it (the GitOps
          # bridge, System::Gitops::ApplyService, still writes the column
          # without converging anything — filed separately). APO-3b built
          # System::Platform::ReplicaReconciler and wired the skill door
          # (platform_resilience `scale`) to it; the Scaling panel kept moving
          # the column and telling the operator nothing, so the number on the
          # panel and the fleet behind it were free to disagree indefinitely.
          #
          # RECONCILE IS UNCONDITIONAL on a patch that names target_replicas —
          # it is NOT gated on the value CHANGING, and the skill door says why
          # in the same words (platform_resilience_executor.rb, `scale`):
          # target == stored is the state every deployment last written by the
          # Scaling panel or the GitOps bridge is already in, and the state the
          # reconciler's own per-pass clamp leaves behind. Skipping the actuator
          # there would report a matching COLUMN as a matching FLEET — this
          # task's defect, one layer up. Only the WRITE and the scale-intent
          # event are conditional on a real change; the convergence never is.
          #
          # Two things are deliberately asymmetric here:
          #
          #   HUB REFUSAL is checked BEFORE the write. The reconciler refuses
          #   the deployment that hosts this control plane outright (INV-1 —
          #   management authority must come from the consensus group, never
          #   the node being managed), so accepting the write would leave a
          #   target_replicas nothing will EVER converge: the exact defect this
          #   endpoint is being fixed for, one row over. The skill door
          #   pre-checks it for the same reason.
          #
          #   EVERY OTHER OUTCOME writes the intent and reports what happened.
          #   A clamped pass, a policy that will not auto-execute a scale-in, a
          #   caller holding system.platform.scale but not system.instances
          #   .create — all of those are legitimate states in which the operator
          #   IS allowed to declare the target and the convergence is partial or
          #   deferred. Those are reported in `reconciled` (ok / refused_reason
          #   / message / actual_before / actual_after / the id lists), not
          #   hidden behind a bare 200 carrying only the new column. The panel
          #   surfaces a non-ok or short reconcile rather than reporting the
          #   save as a scale.
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
            target_requested = attrs.key?(:target_replicas)

            if target_requested && replica_reconciler.hub_deployment?(@deployment)
              return render_error(
                format(::System::Platform::ReplicaReconciler::HUB_REFUSAL_MESSAGE,
                       name: @deployment.name),
                status: :unprocessable_content,
                code: "control_plane_self_remediation"
              )
            end

            unless @deployment.update(attrs)
              return render_error("Update failed: #{@deployment.errors.full_messages.join(', ')}",
                                  status: :unprocessable_content)
            end

            emit_scale_event!(@deployment, previous_target: previous_target)

            payload = { deployment: serialize(@deployment.reload) }
            if target_requested
              payload[:reconciled] = serialize_reconcile(replica_reconciler.reconcile!(@deployment))
            end
            render_success(payload)
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
            actual, by_status, cordoned = compute_actual_replicas(deployment)
            {
              id: deployment.id,
              name: deployment.name,
              service_role: deployment.service_role,
              target_replicas: deployment.target_replicas,
              actual_replicas: actual,
              actual_by_status: by_status,
              cordoned_count: cordoned,
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

          # Returns [actual, by_status, cordoned] for the NodeInstance rows
          # whose Node references the deployment's template.
          #
          # `actual` is the SAME number System::Platform::ReplicaReconciler
          # #live_scope converges toward: rows in `active` status MINUS the
          # cordoned ones (IMP-3d4058389afa). Both readers go through the one
          # scope pair System::InstanceCordonService owns (NodeInstance
          # .not_cordoned / .cordoned), so they cannot disagree on a row. Before
          # this the panel counted `active` alone, and a cordon followed by its
          # reconciled replacement rendered target+1 with nothing saying why —
          # a standing "drift" that pressing reconcile could never clear.
          #
          # `cordoned` is the count the subtraction removed — active rows an
          # operator cordoned (system_cordon_instance). It is returned as its
          # own labelled number rather than folded away: the replicas are still
          # running, still cost money, and are the first scale-in victims.
          #
          # "active" = pending|provisioning|running|stopped — NOT "anything not
          # terminated/errored", as this comment used to claim: the scope also
          # drops starting/stopping/rebooting. That is narrower than
          # System::NodeInstance::LIVE_REPLICA_STATUSES, which mission capacity
          # metrics use, and the two are deliberately different. This panel
          # reports what an operator can act on right now and pairs the number
          # with a per-status breakdown (`by_status` below, over EVERY row,
          # cordoned included), so a transitional row is shown rather than
          # hidden; a capacity metric has no such breakdown and must not read a
          # routine reboot as lost capacity. The Node model overrides table_name
          # to "system_nodes" so the WHERE clause references the actual table
          # name, not the association name.
          def compute_actual_replicas(deployment)
            return [ 0, {}, 0 ] unless deployment.node_template_id

            instance_scope = ::System::NodeInstance
                               .joins(:node)
                               .where(system_nodes: { node_template_id: deployment.node_template_id,
                                                       account_id: current_account.id })
            active = instance_scope.active
            [ active.not_cordoned.count, instance_scope.group(:status).count, active.cordoned.count ]
          rescue StandardError
            [ 0, {}, 0 ]
          end

          # `internal:` is FALSE by construction here: this is an operator
          # request with a real User, and the reconciler checks
          # system.instances.create / .control against that user. Handing it
          # `internal: true` would turn the panel into a way to provision and
          # terminate on the strength of system.platform.scale alone.
          def replica_reconciler
            @replica_reconciler ||= ::System::Platform::ReplicaReconciler.new(
              account: current_account, user: current_user
            )
          end

          def serialize_reconcile(outcome)
            {
              ok: outcome.ok?,
              refused_reason: outcome.refused_reason,
              message: outcome.message,
              actual_before: outcome.actual_before,
              actual_after: outcome.actual_after,
              target_replicas: outcome.target_replicas,
              provisioned_instance_ids: Array(outcome.provisioned_instance_ids),
              terminated_instance_ids: Array(outcome.terminated_instance_ids),
              pending_removal_instance_ids: Array(outcome.pending_removal_instance_ids),
              failures: Array(outcome.failures)
            }
          end

          # IMP-f4fe1ed1ec1e: this guarded on `::FleetEvent` — a constant that
          # does not exist (the model is System::FleetEvent) — and named
          # severity "info", which is not in System::FleetEvent::SEVERITIES.
          # Either alone made the emit a no-op, the second one silently via the
          # rescue below, so the endpoint's own docstring claim to "emit a
          # FleetEvent" had been false for as long as it had been made.
          def emit_scale_event!(deployment, previous_target:)
            return if previous_target.to_i == deployment.target_replicas.to_i

            ::System::FleetEvent.create!(
              account_id: current_account.id,
              kind: "platform.scale.intent",
              severity: "low",
              payload: {
                deployment_id: deployment.id,
                service_role: deployment.service_role,
                previous_target: previous_target,
                new_target: deployment.target_replicas
              },
              correlation_id: deployment.id
            )
          rescue StandardError => e
            # Event emission is opportunistic — never block the response. It is
            # LOGGED, though: the previous silent rescue is how two dead
            # arguments survived in a method whose whole job is to be observed.
            Rails.logger.warn(
              "[Platform::DeploymentsController] scale-intent event emit failed: #{e.class}: #{e.message}"
            )
          end
        end
      end
    end
  end
end
