# frozen_string_literal: true

module System
  # A2A (agent-to-agent) capability discovery + authorization — the platform-side
  # POLICY layer for instance↔instance MCP calls (AI/MCP workload substrate L2.5).
  #
  # The on-node MCP transport (Go agent) that actually carries an A->B call is
  # deferred; this is what it (and operators/missions) consult:
  #   - discoverable_for: who can I see + what skills do they offer?
  #   - authorize:        may caller invoke skill S on target peer B?
  #
  # Authorization is three-gate (mirrors the federation "trust != authorization"
  # model at the instance layer): caller grant -> target enabled/online -> target
  # actually offers the skill. Default-deny.
  class PeerCapabilityService
    Decision = ::Struct.new(:authorized, :reason, keyword_init: true)

    ONLINE_STATUSES = %w[active degraded].freeze

    def self.discoverable_for(account:, caller_peer: nil)
      new(account: account).discoverable_for(caller_peer: caller_peer)
    end

    def self.authorize(caller_peer:, target_peer:, skill:)
      new(account: caller_peer&.account).authorize(caller_peer: caller_peer, target_peer: target_peer, skill: skill)
    end

    def initialize(account:)
      @account = account
    end

    # Online, operator-enabled peers in the account (excluding the caller), with
    # their offered skills + addresses. Discovery is read-only; the call itself is
    # gated by #authorize, so listing a peer here does NOT imply call permission.
    def discoverable_for(caller_peer: nil)
      scope = ::System::NodeInstancePeer.where(account_id: @account&.id).enabled.online
      scope = scope.where.not(id: caller_peer.id) if caller_peer

      scope.map do |p|
        {
          peer_id: p.id,
          instance_id: p.node_instance_id,
          handle: p.handle,
          trust_score: p.trust_score,
          addresses: p.addresses_array,
          offered_skills: p.offered_skill_names
        }
      end
    end

    # May caller_peer invoke `skill` on target_peer? Three gates, default-deny.
    def authorize(caller_peer:, target_peer:, skill:)
      skill = skill.to_s
      return deny("caller not granted skill '#{skill}'") unless caller_peer&.may_invoke_peer_skill?(skill)
      return deny("target peer not enabled/online")     unless target_peer&.enabled? && ONLINE_STATUSES.include?(target_peer.status)
      return deny("target does not offer skill '#{skill}'") unless target_peer.offered_skill_names.include?(skill)
      return deny("cross-account A2A is not permitted")  unless caller_peer.account_id == target_peer.account_id

      Decision.new(authorized: true, reason: "ok")
    end

    private

    def deny(reason)
      Decision.new(authorized: false, reason: reason)
    end
  end
end
