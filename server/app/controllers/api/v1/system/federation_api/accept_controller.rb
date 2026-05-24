# frozen_string_literal: true

module Api
  module V1
    module System
      module FederationApi
        # Bootstrap-token-authenticated handshake. A newly-spawned child
        # platform (or an out-of-band-invited peer) presents its
        # acceptance_token to claim its FederationPeer row and complete
        # the initial capability + endpoint exchange.
        #
        # NOT mTLS-authenticated — the peer has no cert yet. The
        # acceptance_token is the bootstrap secret.
        #
        # POST /api/v1/system/federation_api/accept
        # Body:
        #   acceptance_token:    string (single-use, time-limited)
        #   contract_version:    integer (must be a supported version)
        #   extension_slugs:     array of strings (e.g., ["trading"])
        #   endpoints:           array of { url, scope, priority, cidr_hint? }
        #   capabilities:        object (forward-compat for P4)
        # Returns:
        #   { peer_id, status, contract_version_agreed, accepted_at }
        #
        # Side effects:
        #   - peer.accept!(acceptance_token: ...) verifies the token
        #   - if peer.platform_peer?, also transitions to enrolled via
        #     enroll!(node_certificate: nil) — the cert wire-up lands in P2.5
        class AcceptController < ApplicationController
          skip_before_action :authenticate_request, raise: false

          # The platform's contract version this build can honor. Mismatch
          # with the caller's claimed version aborts with a clear error
          # (Social Contract commitment #12).
          SUPPORTED_CONTRACT_VERSIONS = [ 1 ].freeze

          def create
            token = params[:acceptance_token]
            return render_error("acceptance_token required", 422) if token.blank?

            contract_version = params[:contract_version].to_i
            unless SUPPORTED_CONTRACT_VERSIONS.include?(contract_version)
              return render_error(
                "Unsupported contract_version #{contract_version.inspect}; supported: #{SUPPORTED_CONTRACT_VERSIONS.inspect}",
                422
              )
            end

            peer = locate_peer_by_token(token)
            return render_error("acceptance_token not recognized or expired", 401) unless peer

            unless peer.accept!(acceptance_token: token)
              return render_error("accept transition failed: #{peer.errors.full_messages.join('; ')}", 422)
            end

            peer.update!(contract_version_agreed: contract_version)

            # For platform peers, also advance to enrolled — the cert
            # is nil for now (P2.5 will wire ACME-issued certs in here).
            if peer.platform_peer?
              peer.enroll!(
                node_certificate: nil,
                capabilities: capabilities_param,
                extension_slugs: extension_slugs_param,
                endpoints: endpoints_param
              )
            end

            # P6.3 — managed_child auto-grant cascade. When the parent
            # accepts a managed_child spawn handshake, record an
            # operator-scope FederationGrant on the parent's side
            # representing the parent's persistent control over this
            # child. The symmetric child-side grant lands in P6.5 via
            # the powernode-hub first-run handler.
            auto_issue_managed_child_grant!(peer)

            # Issue a single-use bootstrap_token so the child agent can
            # immediately enroll against /node_api/enroll and pick up its
            # mTLS cert. Without this the agent has no auth to fetch
            # module assignments — federation accept alone establishes
            # peer trust but not node-api access.
            node_enrollment = issue_node_enrollment_for!(peer)

            emit_event!(peer, action: "accepted")

            payload = {
              peer_id: peer.id,
              status: peer.status,
              peer_kind: peer.peer_kind,
              contract_version_agreed: peer.contract_version_agreed,
              accepted_at: peer.signed_at&.iso8601,
              handshake_at: peer.last_handshake_at&.iso8601
            }
            payload[:node_enrollment] = node_enrollment if node_enrollment
            render_success(data: payload)
          end

          private

          # The acceptance_token plaintext maps to ONE peer via its digest.
          # We scan candidates whose digest matches; since digest is sha256
          # and the keyspace is 32 bytes random, conflicts are astronomical.
          def locate_peer_by_token(plaintext)
            digest = ::Digest::SHA256.hexdigest(plaintext)
            ::System::FederationPeer.where(acceptance_token_digest: digest).find do |peer|
              peer.acceptance_token_expires_at.nil? ||
                peer.acceptance_token_expires_at > Time.current
            end
          end

          def capabilities_param
            value = params[:capabilities]
            value.is_a?(Hash) || value.is_a?(ActionController::Parameters) ? value.to_unsafe_h : {}
          end

          def extension_slugs_param
            Array(params[:extension_slugs]).map(&:to_s).reject(&:blank?)
          end

          def endpoints_param
            Array(params[:endpoints]).map do |entry|
              if entry.is_a?(ActionController::Parameters)
                entry.to_unsafe_h
              else
                entry.to_h
              end
            end
          end

          # Managed-child auto-grant. Fires only when the peer row
          # represents the parent's view of a managed_child spawn
          # (spawn_role=parent AND spawn_mode=managed_child). Idempotent
          # — if a row already exists for this peer + resource_kind,
          # skip. The grant is operator-scope (read/write/admin) and
          # long-lived (365d) because the parent's stewardship of a
          # managed child should outlast the v1 grant default. Empty
          # pessimistic-scope allowlists keep this grant permissive
          # within the bounded parent↔child relationship.
          MANAGED_CHILD_GRANT_KIND = "managed_child_operator"
          MANAGED_CHILD_GRANT_TTL  = 365.days

          def auto_issue_managed_child_grant!(peer)
            return unless peer.spawn_role == "parent"
            return unless peer.spawn_mode == "managed_child"

            existing = ::System::FederationGrant
              .where(federation_peer_id: peer.id, resource_kind: MANAGED_CHILD_GRANT_KIND, revoked_at: nil)
              .where("expires_at > ?", Time.current)
              .exists?
            return if existing

            ::System::FederationGrant.create!(
              account: peer.account,
              federation_peer: peer,
              grantor_user: nil,
              remote_subject: "parent-operator@#{peer.id}",
              resource_kind: MANAGED_CHILD_GRANT_KIND,
              permission_scopes: %w[read write admin],
              issued_at: Time.current,
              expires_at: Time.current + MANAGED_CHILD_GRANT_TTL,
              metadata: {
                "auto_issued_by" => "managed_child_accept_cascade",
                "spawn_mode" => peer.spawn_mode,
                "spawn_role" => peer.spawn_role
              }
            )
          rescue StandardError => e
            Rails.logger.warn(
              "[FederationApi::AcceptController] managed_child auto-grant failed for peer #{peer.id}: #{e.message}"
            )
          end

          # Bootstrap-token issuance for the federation-spawned child's
          # node_api enrollment. Only fires for managed_child spawns
          # (parent side) where SpawnProvisioner stamped node_id +
          # node_instance_id into peer.metadata. Returns a hash suitable
          # for inclusion in the accept response, or nil when the lookup
          # data is absent (out-of-band-invited peers etc.).
          #
          # The token is single-use, scoped to the child's Node, and
          # carries the node's name as intended_subject — the agent
          # presents it on /node_api/enroll and receives an mTLS cert
          # bound to that Node's identity.
          def issue_node_enrollment_for!(peer)
            return nil unless peer.spawn_role == "parent"
            return nil unless peer.spawn_mode == "managed_child"

            node_id = peer.metadata&.dig("node_id")
            node_instance_id = peer.metadata&.dig("node_instance_id")
            return nil if node_id.blank?

            node = ::System::Node.find_by(id: node_id, account_id: peer.account_id)
            return nil unless node

            instance = node_instance_id.present? ?
                       ::System::NodeInstance.find_by(id: node_instance_id) : nil

            token, plaintext = ::System::BootstrapToken.issue!(
              node: node,
              node_instance: instance,
              intended_subject: node.name,
              ttl: 1.hour,
              single_use: true,
              purpose: "federation_managed_child_accept"
            )

            {
              bootstrap_token:   plaintext,
              # platform_url is where the child agent POSTs /node_api/enroll
              # to redeem the bootstrap_token for an mTLS cert. That endpoint
              # lives on the PARENT (this platform), not on the child. Using
              # request.base_url derives the parent's externally-visible URL
              # from the URL the child reached us at — robust to multi-tier
              # proxy setups and avoids hardcoding. peer.remote_instance_url
              # is the child's URL (where the parent could reach the child),
              # which is the opposite direction and was a bug previously.
              platform_url:      request.base_url,
              intended_subject:  node.name,
              expires_at:        token.expires_at.iso8601
            }
          rescue StandardError => e
            ::Rails.logger.warn(
              "[FederationApi::AcceptController] node_enrollment issuance failed for peer #{peer.id}: #{e.class}: #{e.message}"
            )
            nil
          end

          def emit_event!(peer, action:)
            return unless defined?(::System::Fleet::EventBroadcaster)

            ::System::Fleet::EventBroadcaster.emit!(
              account: peer.account,
              kind: "federation.peer.#{action}",
              severity: "low",
              source: "federation_api_accept",
              payload: {
                peer_id: peer.id,
                peer_kind: peer.peer_kind,
                spawn_role: peer.spawn_role,
                spawn_mode: peer.spawn_mode,
                contract_version: peer.contract_version_agreed
              }
            )
          rescue StandardError => e
            Rails.logger.warn("[FederationApi::AcceptController] event emit failed: #{e.message}")
          end
        end
      end
    end
  end
end
