# frozen_string_literal: true

module System
  module Federation
    # FederationAcceptanceService — the orchestration spine behind the
    # bootstrap-token federation handshake. Extracted verbatim from
    # Api::V1::System::FederationApi::AcceptController#create (P3.3/P6.3)
    # so the same logic is reachable from three callers without
    # duplication:
    #
    #   1. AcceptController#create          — the HTTP handshake endpoint
    #   2. FederationAcceptanceExecutor     — the approval-gated skill
    #   3. (future) any internal re-accept / re-enroll flow
    #
    # The service owns the FULL accept chain. The original controller
    # logic was:
    #
    #   locate_peer_by_token → peer.accept! → peer.enroll! (platform peers)
    #     → auto_issue_managed_child_grant! → issue_node_enrollment_for!
    #
    # Phase 3a EXTENDS that with the post-accept topology chain (SDWAN-first
    # directive — isolation + discovery ride the SDWAN overlay):
    #
    #   → SDWAN attach    via Sdwan::PeerEnroller.call (+ bridge activate!)
    #   → cert-verify+health via Sdwan::FederationGovernance.scan (peer-scoped)
    #   → ensure          System::FederationGrant (managed_child operator grant)
    #
    # The post-accept chain steps are SOFT: a failure there is collected
    # as a warning and the accept still succeeds with the peer enrolled +
    # node_enrollment issued (an operator can re-run topology independently).
    # The accept / enroll / node-enrollment steps are HARD: a token or
    # transition failure aborts the whole call.
    #
    # This inline attach (attach_to_sdwan_overlay! → PeerEnroller creates the
    # Sdwan::Peer) is the only post-accept topology step; convergence onto the
    # fabric then rides the agent's next node_api poll, which serves the
    # recomputed topology. There is no out-of-band reconciliation job — the
    # accepted peer is immediately usable when this service returns.
    #
    # Plan reference: Decentralized Federation §C + P3.3 + P6.3 + Phase 3a.
    class FederationAcceptanceService
      # The platform's contract version this build can honor. Mismatch
      # with the caller's claimed version aborts with a clear error
      # (Social Contract commitment #12). Kept as the canonical home so
      # the controller, executor, and any future caller share one list.
      SUPPORTED_CONTRACT_VERSIONS = [ 1 ].freeze

      # Managed-child auto-grant constants. The grant is operator-scope
      # (read/write/admin) and long-lived (365d) because the parent's
      # stewardship of a managed child should outlast the v1 grant default.
      MANAGED_CHILD_GRANT_KIND = "managed_child_operator"
      MANAGED_CHILD_GRANT_TTL  = 365.days

      # Result wraps the outcome so callers (controller / executor) can
      # render or fail uniformly. `ok?` false carries `error` + `status`
      # (HTTP-ish code) so the controller can map it back to render_error.
      Result = Struct.new(
        :ok?, :peer, :payload, :error, :status, :warnings, keyword_init: true
      )

      class << self
        # @param token [String] the single-use acceptance_token plaintext
        # @param contract_version [Integer] caller's claimed contract version
        # @param capabilities [Hash] forward-compat capability advertisement
        # @param extension_slugs [Array<String>] extensions the peer carries
        # @param endpoints [Array<Hash>] { url, scope, priority, cidr_hint? }
        # @param platform_url [String, nil] the externally-visible URL the
        #        child reached this platform at (request.base_url in the
        #        controller). Used to build the node_enrollment redemption
        #        URL. nil when called from a non-HTTP context (the executor
        #        falls back to the install's configured platform_url).
        # @return [Result]
        def call(token:, contract_version:, capabilities: {}, extension_slugs: [],
                 endpoints: [], platform_url: nil)
          new(
            token: token,
            contract_version: contract_version,
            capabilities: capabilities,
            extension_slugs: extension_slugs,
            endpoints: endpoints,
            platform_url: platform_url
          ).call
        end
      end

      def initialize(token:, contract_version:, capabilities: {}, extension_slugs: [],
                     endpoints: [], platform_url: nil)
        @token            = token
        @contract_version = contract_version.to_i
        @capabilities     = normalize_capabilities(capabilities)
        @extension_slugs  = Array(extension_slugs).map(&:to_s).reject(&:blank?)
        @endpoints        = normalize_endpoints(endpoints)
        @platform_url     = platform_url
        @warnings         = []
      end

      def call
        if @token.blank?
          return failure("acceptance_token required", status: 422)
        end

        unless SUPPORTED_CONTRACT_VERSIONS.include?(@contract_version)
          return failure(
            "Unsupported contract_version #{@contract_version.inspect}; " \
            "supported: #{SUPPORTED_CONTRACT_VERSIONS.inspect}",
            status: 422
          )
        end

        peer = locate_peer_by_token(@token)
        return failure("acceptance_token not recognized or expired", status: 401) unless peer

        # ── HARD step: accept transition (verifies the token round-trip) ──
        unless peer.accept!(acceptance_token: @token)
          return failure(
            "accept transition failed: #{peer.errors.full_messages.join('; ')}",
            status: 422
          )
        end

        peer.update!(contract_version_agreed: @contract_version)

        # ── HARD step: enroll platform peers (issue outbound client cert) ─
        if peer.platform_peer?
          peer.enroll!(
            node_certificate: issue_peer_client_certificate!(peer),
            capabilities: @capabilities,
            extension_slugs: @extension_slugs,
            endpoints: @endpoints
          )
        end

        # ── ensure grant: managed_child operator FederationGrant ─────────
        # Idempotent — reuses a live grant if one already exists.
        auto_issue_managed_child_grant!(peer)

        # ── HARD step: node_enrollment bootstrap token (managed_child) ───
        node_enrollment = issue_node_enrollment_for!(peer)

        # ── SOFT post-accept topology chain (SDWAN-first) ────────────────
        #   1. SDWAN attach   (Sdwan::PeerEnroller.call + bridge activate!)
        #   2. cert-verify + health (Sdwan::FederationGovernance.scan_peer)
        sdwan_attach = attach_to_sdwan_overlay!(peer)
        governance   = scan_federation_governance!(peer)

        emit_event!(peer, action: "accepted")

        payload = build_payload(peer)
        payload[:node_enrollment] = node_enrollment if node_enrollment
        payload[:sdwan_attach]    = sdwan_attach if sdwan_attach
        payload[:governance]      = governance if governance
        payload[:warnings]        = @warnings if @warnings.any?

        Result.new(ok?: true, peer: peer, payload: payload, warnings: @warnings)
      end

      private

      # 90 days, matching the InternalCaService default TTL.
      FEDERATION_CLIENT_CERT_TTL_SECONDS = 90 * 24 * 60 * 60

      # Federation mTLS Phase 1 — issue THIS account's outbound client cert for
      # the peer so PeerClient presents a client identity instead of falling back
      # to plaintext. Mirrors DockerDaemonProvisionerService#issue_client_tls_pair!
      # (Ed25519 key + CSR signed by InternalCaService); the cert + key land in
      # the Vault-backed NodeCertificate.credentials that PeerClient reads.
      #
      # Cross-account CA trust (so the remote ACCEPTS this cert) is Phase 2 —
      # until then a strict remote still rejects, which is the correct fail-closed
      # behavior. Best-effort: a PKI hiccup must not abort acceptance (returns
      # nil, the prior behavior).
      def issue_peer_client_certificate!(peer)
        common_name = "federation-peer-#{peer.id}"
        key = OpenSSL::PKey.generate_key("ED25519")
        csr = OpenSSL::X509::Request.new
        csr.version = 0
        csr.subject = OpenSSL::X509::Name.parse("/CN=#{common_name}")
        csr.public_key = key
        csr.sign(key, nil) # Ed25519 — digest must be nil

        issued = ::System::InternalCaService.issue_certificate(
          csr_pem: csr.to_pem,
          ttl_seconds: FEDERATION_CLIENT_CERT_TTL_SECONDS,
          common_name: common_name
        )

        cert = ::System::NodeCertificate.new(
          account_id: peer.account_id,
          subject_kind: "federation_peer",
          serial: issued[:serial],
          subject: issued[:subject] || "CN=#{common_name}",
          not_before: issued[:not_before] || Time.current,
          not_after: issued[:not_after] || (Time.current + FEDERATION_CLIENT_CERT_TTL_SECONDS)
        )
        cert.credentials = {
          "cert_pem" => issued[:cert_pem],
          "private_key_pem" => key.private_to_pem,
          "ca_chain_pem" => issued[:ca_chain_pem]
        }
        cert.save!
        cert
      rescue StandardError => e
        Rails.logger.warn("[FederationAcceptanceService] peer client cert issuance failed for peer #{peer.id}: #{e.class}: #{e.message}")
        nil
      end

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

      # Managed-child auto-grant. Fires only when the peer row represents
      # the parent's view of a managed_child spawn (spawn_role=parent AND
      # spawn_mode=managed_child). Idempotent — if a live row already
      # exists for this peer + resource_kind, skip. Empty pessimistic-scope
      # allowlists keep this grant permissive within the bounded
      # parent↔child relationship.
      def auto_issue_managed_child_grant!(peer)
        return nil unless peer.spawn_role == "parent"
        return nil unless peer.spawn_mode == "managed_child"

        existing = ::System::FederationGrant
          .where(federation_peer_id: peer.id, resource_kind: MANAGED_CHILD_GRANT_KIND, revoked_at: nil)
          .where("expires_at > ?", Time.current)
          .exists?
        return nil if existing

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
          "[FederationAcceptanceService] managed_child auto-grant failed for peer #{peer.id}: #{e.message}"
        )
        nil
      end

      # Bootstrap-token issuance for the federation-spawned child's
      # node_api enrollment. Only fires for managed_child spawns (parent
      # side) where SpawnProvisioner stamped node_id + node_instance_id
      # into peer.metadata. Returns a hash suitable for the response, or
      # nil when the lookup data is absent (out-of-band-invited peers).
      #
      # The token is single-use, scoped to the child's Node, and carries
      # the child's NodeInstance UUID as intended_subject — the agent
      # presents it on /node_api/enroll and receives an mTLS cert whose CN
      # is that UUID. node.name (the shared Node hostname) is the degraded
      # fallback only when no instance is bound.
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
        subject = instance&.id || node.name

        token, plaintext = ::System::BootstrapToken.issue!(
          node: node,
          node_instance: instance,
          intended_subject: subject,
          ttl: 1.hour,
          single_use: true,
          purpose: "federation_managed_child_accept"
        )

        {
          bootstrap_token:   plaintext,
          # The redemption endpoint (/node_api/enroll) lives on the PARENT
          # (this platform). The controller passes request.base_url so the
          # URL the child reached us at is what we hand back — robust to
          # multi-tier proxy setups. When @platform_url is nil (non-HTTP
          # caller), fall back to the install's configured platform_url.
          platform_url:      @platform_url.presence || resolved_platform_url,
          intended_subject:  subject,
          expires_at:        token.expires_at.iso8601
        }
      rescue StandardError => e
        ::Rails.logger.warn(
          "[FederationAcceptanceService] node_enrollment issuance failed for peer #{peer.id}: #{e.class}: #{e.message}"
        )
        nil
      end

      # ── Post-accept SDWAN attach (SDWAN-first directive) ───────────────
      #
      # Seats the child's bound NodeInstance into the federation overlay
      # network and flips the FederationNetworkBridge to `active` so the
      # federation_api auth chain (FederationGrant#applies_to_network?)
      # accepts subsequent calls arriving over that network.
      #
      # Resolution: the target network comes from an existing
      # FederationNetworkBridge for this peer, falling back to
      # peer.metadata["sdwan_network_id"]. The instance comes from
      # peer.metadata["node_instance_id"]. When neither resolves (e.g. an
      # out-of-band peer with no overlay binding), the step is cleanly
      # SKIPPED — not an error, the overlay is simply not part of this
      # peering.
      #
      # Idempotent: an existing Sdwan::Peer for the instance in the network
      # is reused rather than re-enrolled.
      def attach_to_sdwan_overlay!(peer)
        return { status: "skipped", reason: "sdwan_unavailable" } unless defined?(::Sdwan)

        network = resolve_overlay_network(peer)
        return { status: "skipped", reason: "no_overlay_network" } unless network

        instance = resolve_bound_instance(peer)
        return { status: "skipped", reason: "no_bound_instance" } unless instance

        if instance.account_id != network.account_id
          @warnings << "sdwan_attach: instance #{instance.id} account mismatch with network #{network.id}"
          return { status: "skipped", reason: "account_mismatch" }
        end

        existing_peer = ::Sdwan::Peer.find_by(
          account_id: network.account_id,
          sdwan_network_id: network.id,
          node_instance_id: instance.id
        )

        sdwan_peer =
          if existing_peer
            existing_peer
          else
            ::Sdwan::PeerEnroller.call(network: network, node_instance: instance)
          end

        bridge = ensure_active_bridge!(peer: peer, network: network)

        {
          status: existing_peer ? "reused" : "attached",
          sdwan_network_id: network.id,
          sdwan_peer_id: sdwan_peer.id,
          node_instance_id: instance.id,
          bridge_id: bridge&.id,
          bridge_state: bridge&.state
        }
      rescue StandardError => e
        @warnings << "sdwan_attach failed: #{e.message}"
        Rails.logger.warn(
          "[FederationAcceptanceService] SDWAN attach failed for peer #{peer.id}: #{e.class}: #{e.message}"
        )
        { status: "error", error: e.message }
      end

      # cert-verify + health: run the federation governance scanner scoped
      # to just this peer. The scan is the canonical cert-expiry /
      # capability-drift / prefix-overlap checker — reusing it (rather than
      # re-implementing health here) keeps one source of truth. Findings are
      # advisory; any critical/high finding is also appended to @warnings so
      # the caller sees it inline. scan_peer avoids walking the whole account
      # fleet (and its migration-chain sweep) on every accept.
      def scan_federation_governance!(peer)
        return { status: "skipped", reason: "sdwan_unavailable" } unless defined?(::Sdwan::FederationGovernance)

        peer_findings = Array(::Sdwan::FederationGovernance.scan_peer(peer: peer))

        peer_findings.each do |f|
          next unless %i[critical high].include?(f[:severity])
          @warnings << "governance[#{f[:kind]}]: #{f[:message]}"
        end

        {
          status: "scanned",
          peer_finding_count: peer_findings.size,
          peer_findings: peer_findings
        }
      rescue StandardError => e
        @warnings << "governance scan failed: #{e.message}"
        Rails.logger.warn(
          "[FederationAcceptanceService] governance scan failed for peer #{peer.id}: #{e.class}: #{e.message}"
        )
        { status: "error", error: e.message }
      end

      # The target overlay network for this peer: an existing bridge wins
      # (it's the link the auth chain already knows about); otherwise
      # peer.metadata["sdwan_network_id"] (stamped at spawn time).
      def resolve_overlay_network(peer)
        bridge = ::System::FederationNetworkBridge
          .where(federation_peer_id: peer.id)
          .live
          .first
        if bridge
          return ::Sdwan::Network.find_by(id: bridge.sdwan_network_id, account_id: peer.account_id)
        end

        network_id = peer.metadata&.dig("sdwan_network_id")
        return nil if network_id.blank?

        ::Sdwan::Network.find_by(id: network_id, account_id: peer.account_id)
      end

      def resolve_bound_instance(peer)
        instance_id = peer.metadata&.dig("node_instance_id")
        return nil if instance_id.blank?

        ::System::NodeInstance.joins(:node)
                              .where(system_nodes: { account_id: peer.account_id })
                              .find_by(id: instance_id)
      end

      # Ensure a FederationNetworkBridge(peer ⇄ network) exists and is
      # `active`. Reuses an existing row (the model enforces uniqueness on
      # federation_peer_id + sdwan_network_id) and transitions proposed →
      # active when allowed.
      def ensure_active_bridge!(peer:, network:)
        bridge = ::System::FederationNetworkBridge.find_or_create_by!(
          account_id: peer.account_id,
          federation_peer_id: peer.id,
          sdwan_network_id: network.id
        ) do |b|
          b.state = "proposed"
        end

        bridge.activate! if bridge.can_transition_to?("active")
        bridge
      rescue StandardError => e
        @warnings << "bridge activation failed: #{e.message}"
        Rails.logger.warn(
          "[FederationAcceptanceService] bridge ensure failed for peer #{peer.id}: #{e.message}"
        )
        nil
      end

      def build_payload(peer)
        {
          peer_id: peer.id,
          status: peer.status,
          peer_kind: peer.peer_kind,
          contract_version_agreed: peer.contract_version_agreed,
          accepted_at: peer.signed_at&.iso8601,
          handshake_at: peer.last_handshake_at&.iso8601
        }
      end

      def emit_event!(peer, action:)
        return unless defined?(::System::Fleet::EventBroadcaster)

        ::System::Fleet::EventBroadcaster.emit!(
          account: peer.account,
          kind: "federation.peer.#{action}",
          severity: "low",
          source: "federation_acceptance_service",
          payload: {
            peer_id: peer.id,
            peer_kind: peer.peer_kind,
            spawn_role: peer.spawn_role,
            spawn_mode: peer.spawn_mode,
            contract_version: peer.contract_version_agreed
          }
        )
      rescue StandardError => e
        Rails.logger.warn("[FederationAcceptanceService] event emit failed: #{e.message}")
      end

      # Best-effort install platform_url for non-HTTP callers (the executor
      # path, which has no request.base_url). Reads POWERNODE_PLATFORM_URL;
      # nil when unset. node_enrollment is only issued for managed_child
      # spawns, which always arrive via the HTTP AcceptController (where
      # @platform_url = request.base_url is present), so this is a
      # belt-and-braces guard for the rare operator-driven managed_child
      # accept, not a hot path.
      def resolved_platform_url
        ENV["POWERNODE_PLATFORM_URL"].presence
      end

      def normalize_capabilities(value)
        if value.is_a?(ActionController::Parameters)
          value.to_unsafe_h
        elsif value.is_a?(Hash)
          value
        else
          {}
        end
      end

      def normalize_endpoints(value)
        Array(value).map do |entry|
          if entry.is_a?(ActionController::Parameters)
            entry.to_unsafe_h
          elsif entry.respond_to?(:to_h)
            entry.to_h
          else
            entry
          end
        end
      end

      def failure(message, status:)
        Result.new(ok?: false, error: message, status: status, warnings: @warnings)
      end
    end
  end
end
