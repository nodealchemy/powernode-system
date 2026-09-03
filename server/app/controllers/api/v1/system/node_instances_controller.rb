# frozen_string_literal: true

module Api
  module V1
    module System
      class NodeInstancesController < BaseController
        # Lifecycle gating (gate_or_execute / gate_ip_action / control_or_error +
        # local-hypervisor provider sync) and index-path provider reconciliation
        # are extracted into cohesive concerns to keep this controller focused on
        # action routing. See concerns/system/node_instance_*.rb.
        include ::System::NodeInstanceGating
        include ::System::NodeInstanceReconciliation

        before_action :set_account
        before_action :set_node
        before_action :set_instance, only: [
          :show, :update, :destroy, :boot_config,
          :start, :stop, :reboot, :terminate,
          :associate_public_ip, :disassociate_public_ip
        ]

        def index
          require_permission("system.instances.read")
          # Eager-load the platform chain so the serializer's boot-image drift
          # fields (promoted_image_git_sha / boot_image_drifted) stay N+1-free
          # across the collection (campaign 019f505f).
          instances = @node.node_instances.includes(node: { node_template: :node_platform })
          instances = apply_filters(instances)
          instances = paginate(instances)
          # Lazy reconcile: in-flight instances (status=pending/provisioning/starting/
          # stopping/rebooting) get a live status pull from their provider before we
          # serialize. Cheap on local_qemu (one virsh dominfo per instance, ~50ms);
          # cloud providers gate themselves on rate limits internally.
          instances = instances.to_a
          reconcile_in_flight_statuses!(instances)
          render_success(node_instances: serialize_collection(instances), meta: pagination_meta)
        end

        def show
          require_permission("system.instances.read")
          render_success(node_instance: serialize_instance(@instance))
        end

        # GET /api/v1/system/nodes/:node_id/node_instances/:id/boot_config
        #
        # Returns the per-instance identity.cfg for the claim-by-ID generic-image
        # fleet flow. The operator flashes many cards from one generic image, then
        # drops this file onto each card's BOOT partition as /boot/identity.cfg —
        # the device claims as THIS instance on first boot, no UI confirmation.
        #
        # Secret-free by design: only the platform URL + the instance ID (a
        # one-time binding capability gated by the instance's `claimable` state).
        # The bootstrap token is delivered to the device over TLS by the claim
        # poll, never written to this file. See
        # PhysicalEnrollmentService.auto_confirm_by_instance_id!.
        def boot_config
          require_permission("system.instances.read")
          # Once a device has claimed this instance it's bound (single-bind) —
          # re-issuing its boot config would only invite a second device to try
          # (and fail) to claim it. Don't offer it. The UI hides the action via
          # the serialized claim state; this is the server-side guard.
          if @instance.claimed?
            return render_error(
              "Boot config is unavailable: this instance has already been claimed by a device.",
              status: :conflict
            )
          end
          # Emit a PLACEHOLDER rather than a guess when no platform URL is
          # configured. This file gets flashed onto physical media: an invented
          # but plausible value (the previous code produced "https://platform.local"
          # in production) reads as correct, survives review, and then fails to
          # resolve on a device that has already been imaged and shipped —
          # discovered at the site rather than at the desk. A placeholder cannot
          # be mistaken for a working value.
          platform_url = ::System::PhysicalEnrollmentService.platform_url
          url_note =
            if platform_url.blank?
              "# !! ACTION REQUIRED — SERVER below is a PLACEHOLDER.\n" \
              "# !! This platform has no enrollment URL configured, so one could not\n" \
              "# !! be filled in. Either set the SiteSetting\n" \
              "# !! #{::System::PhysicalEnrollmentService::PLATFORM_URL_SETTING}\n" \
              "# !! and re-download, or replace the SERVER line by hand before\n" \
              "# !! flashing. A device will NOT enroll until it names a reachable\n" \
              "# !! platform.\n"
            else
              ""
            end

          # A private/self-signed chain is normal for a self-hosted plane, and
          # leaving CA_PEM_FILE commented out in that case is a silent TLS failure
          # on every device. Decide it from what the platform actually serves
          # rather than asking the reader to know which case they are in.
          ca_lines =
            if ::System::PhysicalEnrollmentService.private_ca?
              "# This platform serves a chain the stock image does NOT already trust,\n" \
              "# so the CA is REQUIRED. Drop it at /boot/powernode-ca.pem alongside\n" \
              "# this file; its contents are the SiteSetting\n" \
              "# #{::System::PhysicalEnrollmentService::ENROLL_CA_SETTING}.\n" \
              "# Without it the device reaches the platform and fails TLS silently.\n" \
              "CA_PEM_FILE=/boot/powernode-ca.pem\n"
            else
              "# This platform's chain is publicly trusted, so no CA file is needed\n" \
              "# (the generic image already trusts public roots). If that changes,\n" \
              "# drop the CA at /boot/powernode-ca.pem and uncomment the next line.\n" \
              "# CA_PEM_FILE=/boot/powernode-ca.pem\n"
            end

          config = <<~CFG
            # Powernode claim-by-ID identity for "#{@instance.name}" (#{@instance.id})
            # Copy to the device's BOOT partition as /boot/identity.cfg. On first
            # boot the device claims as this instance — no operator confirmation.
            # No secret here: the bootstrap token is delivered to the device over
            # TLS by the claim poll, never written to this file.
            #{url_note}SERVER=#{platform_url.presence || "<<REPLACE-WITH-PLATFORM-URL>>"}
            ID=#{@instance.id}
            #{ca_lines}
          CFG
          send_data config,
                    filename: "identity-#{@instance.name.parameterize}.cfg",
                    type: "text/plain",
                    disposition: "attachment"
        end

        def create
          require_permission("system.instances.create")
          document, refusal = config_document_or_refusal
          return render_error(refusal, status: :unprocessable_content) if refusal

          attrs = instance_params
          # Creation: there is no row behind this object yet, so assigning the
          # whole (already allow-listed) document clobbers nothing.
          attrs = attrs.merge(config: document) if document
          instance = @node.node_instances.build(attrs)

          if instance.save
            render_success(node_instance: serialize_instance(instance), status: :created)
          else
            render_validation_error(instance)
          end
        end

        def update
          require_permission("system.instances.update")
          document, refusal = config_document_or_refusal
          return render_error(refusal, status: :unprocessable_content) if refusal

          if @instance.update(instance_params)
            # The named keys only, merged in Postgres against the CURRENT row —
            # System::ConfigDocument. A whole-document assignment here would
            # erase whatever the node's telemetry lanes wrote since this request
            # was composed.
            @instance.merge_config!(document) if document.present?
            render_success(node_instance: serialize_instance(@instance))
          else
            render_validation_error(@instance)
          end
        end

        # DELETE /api/v1/system/nodes/:node_id/node_instances/:id
        # DELETE /api/v1/system/nodes/:node_id/node_instances/:id?force=true
        #
        # Default (force omitted/false): plain destroy. Will fail with
        # FOREIGN_KEY_VIOLATION if any child rows reference this instance
        # — but the error payload now includes a `blocking_refs` summary
        # so the operator knows exactly which dependents to clean up.
        #
        # With force=true: runs the dependent-cascade cleanup
        # (NodeInstance#cascade_destroy_dependents!) which nulls all
        # `optional: true` FK references (audit-style tables) and
        # destroys all hard-FK dependents (SDWAN peers, storage
        # assignments, etc.) in dependency-safe order before destroying
        # the instance itself. Intended for operator-driven cleanup of
        # stale or aborted spawns.
        def destroy
          require_permission("system.instances.delete")
          force = ActiveModel::Type::Boolean.new.cast(params[:force])

          if force
            cleanup_summary = @instance.cascade_destroy_dependents!
            if @instance.destroy
              render_success(
                message: "Instance deleted (cascade)",
                cascade_cleanup: cleanup_summary
              )
              return
            end
          elsif @instance.destroy
            render_success(message: "Instance deleted successfully")
            return
          end

          # Below: either the plain destroy failed OR the post-cascade
          # destroy still failed. In both cases surface blocking refs so
          # the operator can act.
          blocking = @instance.blocking_dependents
          if blocking.any?
            render_error(
              "Cannot delete this record because it is referenced by other records",
              status: :unprocessable_content,
              data: {
                blocking_refs: blocking,
                hint: "Retry with ?force=true to cascade-destroy these dependents."
              }
            )
          else
            render_error("Failed to delete instance", status: :unprocessable_content)
          end
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/start
        # All instance lifecycle actions flow through the autonomy gate for
        # uniform audit + chain-of-custody. Manual operation policies default
        # start/stop/reboot to auto_approve, so steady-state behavior is
        # identical for those — `restart` defaults to require_approval since
        # IMP-0c1a7dca5781, because its unit-scoped reading carries a
        # caller-chosen options["unit"] into systemctl on the node. Operators
        # can flip any of them either way from the System Settings → Manual
        # Operations tab; an install seeded before that change still holds the
        # older auto_approve row, since PolicyReconciler never rewrites an
        # existing verb.
        def start
          require_permission("system.instances.control")
          gate_or_execute(:start)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/stop
        def stop
          require_permission("system.instances.control")
          gate_or_execute(:stop)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/reboot
        def reboot
          require_permission("system.instances.control")
          gate_or_execute(:reboot)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/terminate
        # Unlike DELETE (which removes the row), terminate keeps the row and
        # the worker runtime brings the cloud resource down via an operation.
        #
        # Gated through Ai::AutonomyGate — system.task.terminate defaults to
        # require_approval in the manual operation policies seed. If the
        # operator's account has it set to auto_approve, terminate executes
        # immediately as before.
        def terminate
          require_permission("system.instances.control")
          gate_or_execute(:terminate)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/associate_public_ip
        # Allocates and associates a public/elastic IP. Cloud-only; physical
        # instances reject. The actual cloud-side allocation happens in the
        # worker runtime via the operation pipeline.
        def associate_public_ip
          require_permission("system.instances.control")

          unless @instance.cloud?
            return render_error(
              "Public IP association is only valid for cloud instances (variety: #{@instance.variety})",
              status: :unprocessable_content
            )
          end

          if (msg = local_hypervisor_rejection_message)
            return render_error(msg, status: :unprocessable_content)
          end

          gate_ip_action(:associate_public_ip)
        end

        # POST /api/v1/system/nodes/:node_id/node_instances/:id/disassociate_public_ip
        # Releases the currently-associated public IP back to the cloud pool.
        def disassociate_public_ip
          require_permission("system.instances.control")

          unless @instance.cloud?
            return render_error(
              "Public IP disassociation is only valid for cloud instances",
              status: :unprocessable_content
            )
          end

          if (msg = local_hypervisor_rejection_message)
            return render_error(msg, status: :unprocessable_content)
          end

          if @instance.public_ip_address.blank?
            return render_error(
              "No public IP currently associated with this instance",
              status: :unprocessable_content
            )
          end

          gate_ip_action(:disassociate_public_ip)
        end

        private

        def set_node
          @node = @account.system_nodes.find(params[:node_id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node")
        end

        def set_instance
          @instance = @node.node_instances.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Instance")
        end

        def instance_params
          require_object_root(:node_instance).permit(
            :name, :description, :variety, :status, :key,
            :private_ip_address, :public_ip_address, :vpn_ip_address
          )
        end

        # `params.require` hands back whatever NON-BLANK value sits under the
        # key, so a String / Array / scalar root came back as itself and the
        # `.permit` on it was a NoMethodError — a 500 through the StandardError
        # rescue (IMP-f9a184e832ac). Only an object can be permitted; any other
        # root is the same request defect as an absent one and is reported the
        # same way: ActionController::ParameterMissing, which the ApiResponse
        # base rescue renders as 400 PARAMETER_MISSING. Raising (not rendering)
        # matters — it unwinds the action before `update`/`build` runs.
        def require_object_root(key)
          root = params.require(key)
          return root if root.is_a?(ActionController::Parameters)

          raise ActionController::ParameterMissing.new(key, params.keys)
        end

        # `config` is handled OUTSIDE the permit list on purpose
        # (IMP-1b65222b8d5f). `permit(config: {})` admits an arbitrary
        # document, and strong parameters has no spelling for "these keys, with
        # any value" — a nested permit list would force every accepted key to a
        # scalar, and `gpu` (a {count,type,memory_mb} hash) is not. So the
        # document is read whole and checked against
        # System::NodeInstance::WRITABLE_CONFIG_KEYS.
        #
        # Returns [document_or_nil, refusal_message_or_nil]. A body with no
        # `config` at all yields [nil, nil] — silence is not a refusal.
        #
        # A malformed root (`node_instance` absent, or not an object) yields
        # [nil, nil] too, so #require_object_root (via #instance_params) stays
        # the one place that reports it, as a 400. Digging into a String root
        # here would raise NoMethodError and make it a 500 again.
        def config_document_or_refusal
          root = params[:node_instance]
          return [ nil, nil ] unless root.is_a?(ActionController::Parameters) || root.is_a?(Hash)

          raw = root[:config]
          return [ nil, nil ] if raw.nil?

          document = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
          return [ nil, "config must be an object of top-level keys" ] unless document.is_a?(Hash)

          document = document.deep_stringify_keys
          refused  = ::System::NodeInstance.unwritable_config_keys(document)
          return [ nil, ::System::NodeInstance.config_refusal_message(refused) ] if refused.any?

          [ document, nil ]
        end

        def apply_filters(scope)
          scope = scope.where(variety: params[:variety]) if params[:variety].present?
          scope = scope.where(status: params[:status]) if params[:status].present?
          scope
        end

        def serialize_instance(instance)
          ::System::NodeInstanceSerializer.new(instance).as_json
        end

        def serialize_collection(instances)
          instances.map { |i| serialize_instance(i) }
        end
      end
    end
  end
end
