# frozen_string_literal: true

# Cross-Powernode-instance peering record. Symmetric platform-level
# federation peer (the v1 SDWAN-only data-plane scaffold is the same
# model with peer_kind="sdwan_only").
#
# The `peer_kind` discriminator separates the two flavors:
#   - "sdwan_only"  — original data-plane peering (prefix advertisement only)
#   - "platform"    — full symmetric Rails-to-Rails federation peer
#
# Per Locked Decision #14, every federated record has exactly one home at
# any moment; FederationPeer rows themselves are local to their peer (no
# replication of the peer registry across the federation).
#
# Plan reference: Decentralized Federation §C + P3 + P3.9.
module System
  class FederationPeer < ApplicationRecord
    self.table_name = "system_federation_peers"

    include VaultCredential

    self.vault_credential_type = "federation_trust_jwt"

    # Discriminator: original v1 rows are "sdwan_only"; P3+ platform peers
    # are "platform". Some validations + the AASM-style transition map
    # only apply to platform peers (sdwan_only peers stop at accepted).
    PEER_KINDS = %w[sdwan_only platform].freeze

    SPAWN_MODES = %w[managed_child autonomous_peer cluster_member out_of_band].freeze
    SPAWN_ROLES = %w[parent child symmetric].freeze

    STATUSES = %w[proposed accepted enrolled active degraded suspended revoked].freeze

    # Expanded transition table (P3.3). sdwan_only peers stop at accepted
    # (data-plane peering is just intent; no enrollment ritual). Platform
    # peers progress through enrolled → active and may oscillate
    # active ⇄ degraded on heartbeat liveness.
    # V1_TRANSITIONS reflects the v1 federation peer state machine.
    # SdwanTool + FederationPeersController + this model all reference
    # this name directly when surfacing per-peer "allowed next transitions"
    # or gating status writes.
    V1_TRANSITIONS = {
      "proposed"  => %w[accepted revoked],
      "accepted"  => %w[enrolled suspended revoked],
      "enrolled"  => %w[active suspended revoked],
      "active"    => %w[degraded suspended revoked],
      "degraded"  => %w[active suspended revoked],
      "suspended" => %w[accepted revoked],
      "revoked"   => []
    }.freeze

    # Default per-platform heartbeat staleness threshold. Past this, the
    # heartbeat worker marks active peers as degraded. 5 minutes = 5 missed
    # 60-second heartbeats.
    HEARTBEAT_STALE_AFTER = 5.minutes

    belongs_to :account

    # Phase 3a — push every platform-peer status transition to the operator
    # dashboard the moment it commits. Acceptance, enrollment, activation,
    # degradation, suspension, and revocation all flow through here so the
    # live federation view reflects state changes without polling.
    # record_heartbeat! emits its own "heartbeat"-kind event separately for
    # liveness pings that don't change status.
    after_update :broadcast_status_transition!, if: :saved_change_to_status?

    # Self-FK: a spawned child peer links to the parent peer record on
    # this side that points at the parent platform.
    belongs_to :parent_peer, class_name: "System::FederationPeer",
                              foreign_key: :parent_peer_id, optional: true
    has_many :child_peers, class_name: "System::FederationPeer",
                            foreign_key: :parent_peer_id, dependent: :nullify

    # OUTBOUND identity: the cert WE present when calling this peer's
    # federation_api (our private key, Vault-backed). Read by
    # Federation::PeerClient. nil for sdwan_only peers and for platform
    # peers that haven't completed federation enrollment yet.
    #
    # Distinct from `inbound_subject` (the CN the peer presents to US, used
    # by FederationApi::BaseController to resolve the caller) and
    # `trusted_ca_pem` (the peer's CA anchor we accept on the federation
    # mTLS Traefik route). Federation mTLS Phase 2 split the old conflated
    # single node_certificate into these three concerns — see migration
    # 20260602120000.
    belongs_to :outbound_certificate, class_name: "System::NodeCertificate",
                                      foreign_key: :outbound_certificate_id, optional: true

    attribute :endpoints,       :jsonb, default: -> { [] }
    attribute :extension_slugs, :jsonb, default: -> { [] }
    attribute :capabilities,    :jsonb, default: -> { {} }
    attribute :sync_cursor,     :jsonb, default: -> { {} }

    validates :remote_instance_url, presence: true,
                                    format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]) }
    validates :status, inclusion: { in: STATUSES }
    validates :peer_kind, inclusion: { in: PEER_KINDS }
    validates :spawn_mode, inclusion: { in: SPAWN_MODES }, allow_nil: true
    validates :spawn_role, inclusion: { in: SPAWN_ROLES }, allow_nil: true
    validates :remote_prefix_advertisement, format: {
      with: %r{\Afd[0-9a-f:]+::/(?:48|56|64)\z}i,
      message: "must be a /48, /56, or /64 ULA prefix"
    }, allow_blank: true
    validates :remote_instance_id, uniqueness: { scope: :account_id }, allow_nil: true
    validate :spawn_role_present_when_platform_kind

    scope :proposed,        -> { where(status: "proposed") }
    scope :accepted,        -> { where(status: "accepted") }
    scope :enrolled,        -> { where(status: "enrolled") }
    scope :active_status,   -> { where(status: "active") }
    scope :degraded,        -> { where(status: "degraded") }
    scope :suspended,       -> { where(status: "suspended") }
    scope :revoked,         -> { where(status: "revoked") }
    scope :live,            -> { where(status: %w[accepted enrolled active degraded]) }
    scope :reachable,       -> { where(status: %w[enrolled active degraded]) }
    scope :sdwan_only_peers, -> { where(peer_kind: "sdwan_only") }
    scope :platform_peers,   -> { where(peer_kind: "platform") }
    scope :children_of,      ->(peer) { where(parent_peer_id: peer.id) }

    # Peers whose advertised remote prefix should enter the local SDWAN
    # data plane (WireGuard AllowedIPs + eBGP networks). Composed from the
    # existing liveness scopes so it can NEVER drift from the peer state
    # machine: platform peers contribute once `reachable` (enrolled →
    # active ⇄ degraded — the same window #reachable? gates inbound
    # federation_api calls on); sdwan_only peers contribute once `live`
    # (which adds `accepted`, since sdwan_only peers stop at accepted and
    # data-plane intent is live the moment they're accepted). Sdwan::
    # FederationPrefixResolver is the consumer — see that service for the
    # full selection rationale. Suspended/revoked peers are excluded by
    # both scopes, so prefixes can't leak from a torn-down peer.
    scope :federation_prefix_contributing, lambda {
      where(id: platform_peers.reachable).or(where(id: sdwan_only_peers.live))
    }

    scope :heartbeat_stale,  ->(threshold = HEARTBEAT_STALE_AFTER.ago) {
      where(peer_kind: "platform")
        .where(status: %w[enrolled active])
        .where("last_heartbeat_at IS NULL OR last_heartbeat_at < ?", threshold)
    }

    # The set of peer CA anchors (PEM) the federation mTLS Traefik route
    # must trust so we accept inbound client certs that SYMMETRIC peers
    # signed with their OWN CA. Hierarchical children we issued to off our
    # own CA leave trusted_ca_pem nil (our CA is already in the bundle).
    # Only reachable platform peers contribute, so a suspended/revoked
    # peer's anchor drops out of the bundle on the next write — trust can't
    # leak from a torn-down peer. Consumed by
    # Acme::TraefikConfigWriter#write_federation_ca!.
    def self.trusted_ca_pems
      platform_peers.reachable
                    .where.not(trusted_ca_pem: [ nil, "" ])
                    .pluck(:trusted_ca_pem)
                    .uniq
    end

    # Returns true if the proposed transition is permitted. The
    # controller / MCP tool consults this before mutating to avoid
    # partial-state rows.
    def can_transition_to?(new_status)
      V1_TRANSITIONS.fetch(status, []).include?(new_status.to_s)
    end

    def platform_peer?
      peer_kind == "platform"
    end

    def sdwan_only_peer?
      peer_kind == "sdwan_only"
    end

    # Status values that permit incoming federation_api calls. Degraded
    # is included so a peer recovering from a heartbeat outage can still
    # call /heartbeat and self-recover via record_heartbeat!.
    def reachable?
      %w[enrolled active degraded].include?(status)
    end

    def heartbeat_stale?(threshold: HEARTBEAT_STALE_AFTER.ago)
      return false unless platform_peer?
      last_heartbeat_at.nil? || last_heartbeat_at < threshold
    end

    # Transitions accepted → enrolled and records the capability/endpoint
    # handshake artifacts. The mTLS material is set separately by the
    # acceptance service: `inbound_subject` (how we resolve this peer's
    # inbound calls) and, for the calling side, `outbound_certificate`
    # (what we present back). Keeping cert wiring out of the transition
    # keeps this method a pure state move.
    def enroll!(capabilities: {}, extension_slugs: [], endpoints: [])
      return false unless can_transition_to?("enrolled")

      update!(
        status: "enrolled",
        capabilities: capabilities,
        extension_slugs: Array(extension_slugs),
        endpoints: Array(endpoints),
        last_handshake_at: Time.current
      )
      true
    end

    # Transitions enrolled → active OR degraded → active. Called when a
    # heartbeat lands successfully. Updates last_heartbeat_at as a side-
    # effect so heartbeat_stale? becomes false.
    def record_heartbeat!(capabilities: nil, endpoints: nil, sync_cursor: nil)
      attrs = { last_heartbeat_at: Time.current }
      attrs[:capabilities] = capabilities if capabilities
      attrs[:endpoints]    = endpoints    if endpoints
      attrs[:sync_cursor]  = sync_cursor  if sync_cursor

      next_status =
        case status
        when "enrolled", "degraded" then "active"
        when "active"                then nil # already active
        else                              nil # not eligible for activation
        end

      attrs[:status] = next_status if next_status
      update!(attrs)
      # Phase 3a — real-time peer-state push. Emit on every heartbeat so
      # the operator dashboard sees liveness + any enrolled/degraded →
      # active recovery the moment it lands.
      broadcast_peer_state!(kind: "heartbeat", previous_status: status_before_last_save)
      true
    end

    # Marks active → degraded when heartbeat is stale. Called by
    # FederationHeartbeatJob on every 60s tick for any active platform
    # peer whose last_heartbeat_at is older than HEARTBEAT_STALE_AFTER.
    def mark_degraded!(reason: nil)
      return false unless can_transition_to?("degraded")

      update!(
        status: "degraded",
        metadata: metadata.merge("degraded_reason" => reason.to_s.presence)
      )
      # The active → degraded push is handled by broadcast_status_transition!
      # (after_update, severity "medium"). No explicit broadcast needed here.
      true
    end

    def suspend!(reason: nil)
      return false unless can_transition_to?("suspended")

      update!(
        status: "suspended",
        metadata: metadata.merge("suspension_reason" => reason.to_s.presence)
      )
      true
    end

    def revoke!(reason: nil)
      return if status == "revoked"

      update!(
        status: "revoked",
        metadata: metadata.merge("revocation_reason" => reason.to_s.presence)
      )
    end

    # Transitions a proposed peer to accepted. Phase 11b adds token
    # round-trip verification: when acceptance_token_digest is set on
    # this peer, accept! requires the plaintext token to match.
    #
    # Phase 11a (drill mode) — peers without acceptance_token_digest
    # accept any caller (no cross-account auth).
    # Phase 11b (this) — peers with digest require matching token.
    # Phase 11c (future) — cross-CA bridging for production federation.
    #
    # Sets signed_at to now (so FederationGovernance's
    # stale_accepted_without_handshake check passes).
    def accept!(accepted_by_user: nil, acceptance_token: nil)
      return false unless can_transition_to?("accepted")

      # Phase 11b: token verification when digest is set
      if (token_error = acceptance_token_error(acceptance_token))
        errors.add(:base, token_error)
        return false
      end

      update!(
        status: "accepted",
        signed_at: Time.current,
        # Clear the digest after successful use — tokens are single-use
        acceptance_token_digest: nil,
        acceptance_token_expires_at: nil,
        metadata: metadata.merge(
          "accepted_by_user_id" => accepted_by_user&.id,
          "acceptance_token_used" => acceptance_token.present?
        )
      )
      true
    end

    # Verification-only counterpart to the Phase 11b token leg of accept!.
    # Returns nil when the token is acceptable — including when this peer
    # carries no digest at all (Phase 11a drill mode) — or the human-readable
    # reason it is not. Consumes nothing.
    #
    # Acceptance is approval-gated (sdwan.federation_peer_accept), so callers
    # check this BEFORE evaluating the gate: a request that can only ever fail
    # should not park an approval request an operator has to dispose of. That
    # is fail-fast, not enforcement — accept! re-runs the same check when the
    # deferred operation finally executes, which is the check that counts.
    def acceptance_token_error(acceptance_token)
      return nil if acceptance_token_digest.blank?
      return "acceptance_token required (peer has acceptance_token_digest set)" if acceptance_token.blank?

      if acceptance_token_expires_at.present? && acceptance_token_expires_at < Time.current
        return "acceptance_token has expired (expired_at #{acceptance_token_expires_at.iso8601})"
      end

      provided_digest = ::Digest::SHA256.hexdigest(acceptance_token.to_s)
      return nil if ::ActiveSupport::SecurityUtils.secure_compare(provided_digest, acceptance_token_digest)

      "acceptance_token does not match stored digest"
    end

    # Phase 11b — generates a high-entropy single-use acceptance token.
    # Returns the plaintext token (must be shown to the operator EXACTLY
    # ONCE — not recoverable). Stores only the digest + expiry.
    def generate_acceptance_token!(ttl_seconds: 7.days.to_i)
      plaintext = ::SecureRandom.urlsafe_base64(32)
      update!(
        acceptance_token_digest: ::Digest::SHA256.hexdigest(plaintext),
        acceptance_token_expires_at: Time.current + ttl_seconds.seconds
      )
      plaintext
    end

    # Returns the /48 portion of remote_prefix_advertisement (or nil if
    # the prefix is wider). Used by FederationGovernance#scan to detect
    # overlap with the install's own prefix.
    def remote_prefix_48
      return nil if remote_prefix_advertisement.blank?

      head, mask = remote_prefix_advertisement.split("/")
      mask = mask.to_i
      return nil if mask < 48 || mask > 64

      groups = head.split(":").reject(&:empty?)
      return nil if groups.size < 3

      "#{groups[0, 3].join(':')}::/48"
    end

    private

    # after_update hook (gated on saved_change_to_status?) that pushes any
    # status transition to the operator dashboard. Maps status → severity:
    # degraded/suspended → "medium", revoked → "high", everything else
    # (accepted, enrolled, active) → "low". Emits kind
    # "federation.peer.<status>". platform_peer? gating + best-effort rescue
    # live in broadcast_peer_state!.
    def broadcast_status_transition!
      severity =
        case status
        when "degraded", "suspended" then "medium"
        when "revoked"               then "high"
        else                              "low"
        end

      broadcast_peer_state!(
        kind: status,
        severity: severity,
        previous_status: status_before_last_save,
        # Revocation is the one transition an operator opens the event for to
        # ask "why is this peer gone". revoke! writes status and metadata in a
        # single update!, so this after_update callback reads the cause it just
        # recorded. Keyed on the NEW status rather than on the key's presence:
        # metadata is operator-writable (PATCH permits `metadata: {}`), so a
        # stray revocation_reason must not ride along on a suspend. Scoped to
        # "revoked" deliberately — degraded/suspended record their own reasons
        # under different keys, and feeding those is a separate change.
        reason: (metadata["revocation_reason"] if status == "revoked")
      )
    end

    # Persist a FleetEvent + push it on SystemFleetChannel so the operator
    # dashboard reflects peer liveness in real time. Best-effort — an
    # observability hiccup never blocks the heartbeat / degrade flow
    # (EventBroadcaster swallows its own errors; this rescue is belt-and-
    # braces for the `defined?` guard miss).
    def broadcast_peer_state!(kind:, severity: "low", previous_status: nil, reason: nil)
      return unless platform_peer?
      return unless defined?(::System::Fleet::EventBroadcaster)

      ::System::Fleet::EventBroadcaster.emit!(
        account: account,
        kind: "federation.peer.#{kind}",
        severity: severity,
        source: "federation_peer",
        payload: {
          peer_id: id,
          peer_kind: peer_kind,
          status: status,
          previous_status: previous_status,
          last_heartbeat_at: last_heartbeat_at&.iso8601,
          reason: reason.to_s.presence
        }.compact
      )
    rescue StandardError => e
      Rails.logger.debug("[System::FederationPeer##{id}] peer-state broadcast skipped: #{e.message}")
    end

    # spawn_role is only meaningful for platform peers. Sdwan-only rows
    # leave it nil. Platform peers must declare parent | child | symmetric
    # (out_of_band peers use symmetric).
    def spawn_role_present_when_platform_kind
      return unless platform_peer?
      return if spawn_role.present?

      errors.add(:spawn_role, "is required for platform peers")
    end
  end
end
