# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-issued, single-use enrolment keys bound to ONE NodeInstance
      # (IMP-5c6a03c3b335, design step D4). The operator pre-configures a node
      # and its instance, mints a key here, and hands it to a generic image.
      #
      #   POST   /api/v1/system/nodes/:node_id/node_instances/:node_instance_id/bootstrap_tokens
      #   GET    /api/v1/system/nodes/:node_id/node_instances/:node_instance_id/bootstrap_tokens
      #   DELETE /api/v1/system/nodes/:node_id/node_instances/:node_instance_id/bootstrap_tokens/:id
      #
      # Permission: system.instances.control (permission-based only, never roles).
      #
      # CRYPTO-MATERIAL RULES. The plaintext is generated server-side by
      # System::BootstrapToken.issue!, returned ONCE in the create response body
      # and nowhere else on this surface: list and revoke serialize through
      # System::BootstrapTokenSerializer, an allowlist with no token, digest or
      # sealed-copy field. It is never logged here; the key operation's audit
      # row is written inside the model's transaction and fails closed.
      class BootstrapTokensController < BaseController
        before_action :set_account
        before_action -> { require_permission("system.instances.control") }
        before_action :set_node
        before_action :set_instance
        before_action :set_token, only: :destroy

        # The operator-key TTL window: 1h minimum (operator ruling), 7d maximum
        # (System::BootstrapToken::MAX_TTLS["operator_key"]).
        MIN_TTL = 1.hour
        MAX_TTL = ::System::BootstrapToken::MAX_TTLS.fetch("operator_key")

        def index
          tokens = instance_tokens.includes(:created_by).order(created_at: :desc)
          render_success(bootstrap_tokens: tokens.map { |t| serialize(t) })
        end

        def create
          # Same spirit as NodeInstancesController#boot_config: once a device has
          # claimed, enrolled as, or is running (or finished as) this instance, a
          # fresh key would only invite a second device to try to bind it.
          if (why = ::System::BootstrapToken.instance_refusal(@instance))
            return render_error("A bootstrap key cannot be issued: #{why}.", status: :conflict)
          end

          ttl = requested_ttl
          return if performed?

          want_document = ActiveModel::Type::Boolean.new.cast(params[:include_provisioning_document])
          # Fail closed BEFORE minting: a dry render with a placeholder key proves
          # the CA/server configuration can produce a document, so no key is
          # minted that the operator could then not package.
          return if want_document && !document_renderable?

          document = nil
          token, plaintext = ::System::BootstrapToken.issue!(
            node: @node,
            node_instance: @instance,
            intended_subject: @instance.id,
            purpose: "operator_key",
            ttl: ttl,
            created_by: current_user
          ) do |minted, key|
            # Rendered INSIDE the mint transaction: a RenderError rolls back the
            # key and its audit row together. One-shot; never stored or logged.
            if want_document
              document = ::System::ProvisioningDocument.render(
                instance: @instance, key: key, purpose: "operator_key", expires_at: minted.expires_at
              )
            end
          end
          payload = { bootstrap_token: serialize(token), token: plaintext }
          payload[:provisioning_document] = document if document
          render_success(data: payload, status: :created)
        rescue ::System::BootstrapToken::InstanceNotAvailable => e
          render_error("A bootstrap key cannot be issued: #{e.message}.", status: :conflict)
        rescue ::System::ProvisioningDocument::RenderError
          # Not reachable after the pre-flight unless config changed mid-request;
          # the mint transaction rolled back, so no key exists.
          render_error("Provisioning document could not be rendered; no key was issued.",
                       status: :unprocessable_content)
        rescue ::System::BootstrapToken::AuditFailure
          render_error("Bootstrap key was not issued: the audit record could not be written.",
                       status: :service_unavailable)
        end

        def destroy
          @token.revoke!(by: current_user)
          render_success(bootstrap_token: serialize(@token.reload))
        rescue ::System::BootstrapToken::InvalidConsumption => e
          render_error(e.message, status: :conflict)
        rescue ::System::BootstrapToken::AuditFailure
          render_error("Bootstrap key was not revoked: the audit record could not be written.",
                       status: :service_unavailable)
        end

        private

        def set_node
          @node = @account.system_nodes.find(params[:node_id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node")
        end

        def set_instance
          @instance = @node.node_instances.find(params[:node_instance_id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Instance")
        end

        def instance_tokens
          ::System::BootstrapToken.where(node_id: @node.id, node_instance_id: @instance.id, purpose: "operator_key")
        end

        def set_token
          @token = instance_tokens.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Bootstrap token")
        end

        def document_renderable?
          ::System::ProvisioningDocument.render(
            instance: @instance, key: "not-a-real-enrol-key", purpose: "operator_key"
          )
          true
        rescue ::System::ProvisioningDocument::RenderError => e
          # RenderError messages never carry a key.
          render_error("Provisioning document cannot be generated: #{e.message}.", status: :unprocessable_content)
          false
        end

        # nil ttl_seconds takes the model's 24h operator default. Anything that
        # is not an integer inside [MIN_TTL, MAX_TTL] is refused, not clamped.
        def requested_ttl
          raw = params[:ttl_seconds]
          return nil if raw.nil?

          seconds = Integer(raw.to_s, 10, exception: false)
          if seconds.nil? || seconds < MIN_TTL.to_i || seconds > MAX_TTL.to_i
            render_error(
              "ttl_seconds must be an integer between #{MIN_TTL.to_i} (1 hour) and #{MAX_TTL.to_i} (7 days)",
              status: :unprocessable_content
            )
            return nil
          end
          seconds.seconds
        end

        def serialize(token)
          ::System::BootstrapTokenSerializer.new(token).as_json
        end
      end
    end
  end
end
