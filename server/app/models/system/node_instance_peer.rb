# frozen_string_literal: true

module System
  # Peer record for a NodeInstance that has self-announced as an agent peer.
  # Stores declared capabilities, skills, addresses, and execution stats.
  # Operator-activation-gated: peers start `enabled: false` to prevent
  # accidental capability disclosure; operator activation is required
  # before remote-task delegation.
  #
  # Reference: comprehensive stabilization sweep P6; Golden Eclipse F-3.
  class NodeInstancePeer < BaseRecord
    include System::Base

    STATUSES = %w[registered active degraded disconnected].freeze

    belongs_to :node_instance, class_name: "System::NodeInstance"
    belongs_to :account

    delegate :node, to: :node_instance

    # AI/MCP workload substrate L2 — glob patterns this instance-agent is
    # authorized to invoke on the platform MCP (default-deny: empty = none).
    attribute :granted_mcp_tools, :jsonb, default: -> { [] }

    # AI/MCP workload substrate L2.5 (A2A) — glob patterns this instance-agent
    # may invoke on OTHER peers via agent-to-agent MCP (default-deny).
    attribute :granted_peer_skills, :jsonb, default: -> { [] }

    validates :handle, presence: true, length: { maximum: 64 },
                       uniqueness: { scope: :account_id }
    validates :status, inclusion: { in: STATUSES }
    validates :trust_score, numericality: { greater_than_or_equal_to: 0,
                                            less_than_or_equal_to: 1 }
    validates :daily_decision_budget,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    scope :enabled,    -> { where(enabled: true) }
    scope :active,     -> { where(status: "active") }
    scope :online,     -> { where(status: %w[active degraded]) }
    scope :for_handle, ->(handle) { where(handle: handle) }

    # F2-04 — capability tokens are verified OFFLINE by agents, so disabling
    # this peer or changing its grants must publish a revocation or the
    # outstanding tokens stay valid until exp. Runs in-transaction with no
    # rescue: if the revocation can't be published, the disable/grant change
    # rolls back rather than silently leaving tokens live (fail-closed).
    after_update :publish_capability_revocation!, if: :capability_revoking_change?

    # IMP-7f01dfcb13e0 — an MCP client caches tools/list at connect; the
    # protocol's only invalidation mechanism is
    # `notifications/tools/list_changed`. Rewriting this peer's grant changes
    # what the platform MCP will advertise to it, so every write of
    # granted_mcp_tools must fire that notification.
    #
    # Lives on the MODEL, not on the grant tool action, so that
    # #grant_mcp_tools!, a direct update!, and every service that rewrites the
    # column (pool recycling's revoke-to-empty, fleet-mission provisioning,
    # dev-cell bootstrap) are all covered by one rung. Verified: nothing writes
    # this COLUMN outside #grant_mcp_tools! — no update_all, upsert, raw UPDATE,
    # or mass-assignment path reaches it (the peers controller permits only
    # enabled/status).
    #
    # Deliberately NOT on :destroy. Two paths remove the whole peer ROW without
    # this callback — SystemFleetTool#destroy_instance's raw
    # `DELETE FROM system_node_instance_peers` (DESTROY_INSTANCE_FKS) and
    # NodeInstance#cascade_destroy_dependents!'s destroy_all. Both destroy the
    # peer only because the INSTANCE is going away, so the session whose catalog
    # would be stale is going away with it, and no surviving session's grant
    # changed. Adding :destroy here would broadcast on instance teardown for no
    # catalog that anyone still holds.
    #
    # Direction-agnostic on purpose: a NARROWED session that keeps a stale
    # catalog advertises tools it can no longer invoke. That is a wrong-failure-
    # mode / correctness problem, not an escalation — Mcp::Principal re-reads
    # the stored grant on every call, so the reduced grant is still enforced.
    #
    # after_commit, not after_update: a rolled-back grant must not tell clients
    # to re-list. That also keeps it strictly downstream of the fail-closed
    # after_update revocation publisher — if that one raises, the save rolls
    # back and this never runs.
    #
    # LATENT TRAP for a future caller: only ONE after_commit fires per
    # transaction, so a caller that wrapped grant_mcp_tools! and a second save
    # of this peer in one explicit transaction would drop the notification.
    # Not reachable today — none of the grant call sites sits inside a wrapping
    # transaction block.
    after_commit :notify_mcp_tool_catalog_changed, on: %i[create update],
                 if: :mcp_tool_grant_changed?

    # Atomically increment execution counters and last_executed_at.
    def record_execution!(success:)
      self.class.where(id: id).update_all([
        "execution_count = COALESCE(execution_count,0) + 1, " \
        "execution_failure_count = COALESCE(execution_failure_count,0) + ?, " \
        "last_executed_at = NOW(), updated_at = NOW(), " \
        "trust_score = LEAST(1.0, GREATEST(0.0, COALESCE(trust_score, 0.5) + ?))",
        success ? 0 : 1,
        success ? 0.005 : -0.02
      ])
      reload
    end

    # Atomically increment daily decision counter, rolling the window if needed.
    # Returns true if the increment fits in the budget; false if exceeded.
    def reserve_decision!
      transaction do
        lock!
        rollover_window if window_stale?

        if daily_decision_used >= daily_decision_budget
          return false
        end

        update!(daily_decision_used: daily_decision_used + 1)
        true
      end
    end

    def addresses_array
      Array(addresses)
    end

    # Grant (or extend) the MCP tool-name glob patterns this instance-agent may
    # invoke on the platform MCP. mode: :replace (default) or :add (union). Read
    # by core Mcp::Principal via the injected tool_grant_resolver.
    def grant_mcp_tools!(patterns, mode: :replace)
      incoming = Array(patterns).map(&:to_s).reject(&:blank?).uniq
      self.granted_mcp_tools =
        mode.to_sym == :add ? (Array(granted_mcp_tools) | incoming) : incoming
      save!
      granted_mcp_tools
    end

    # A2A — grant (or extend) the skill-name glob patterns this instance-agent may
    # invoke on OTHER peers via agent-to-agent MCP. mode: :replace (default)/:add.
    def grant_peer_skills!(patterns, mode: :replace)
      incoming = Array(patterns).map(&:to_s).reject(&:blank?).uniq
      self.granted_peer_skills =
        mode.to_sym == :add ? (Array(granted_peer_skills) | incoming) : incoming
      save!
      granted_peer_skills
    end

    # A2A — may this instance-agent invoke `skill` on a peer? Default-deny; matched
    # against its granted_peer_skills glob patterns.
    def may_invoke_peer_skill?(skill)
      name = skill.to_s
      Array(granted_peer_skills).any? { |p| ::File.fnmatch(p.to_s, name, ::File::FNM_EXTGLOB) }
    end

    # A2A — the skill names this peer OFFERS (from its announced declared_skills).
    def offered_skill_names
      Array(declared_skills).map { |s| s.is_a?(Hash) ? (s["name"] || s[:name]) : s }.compact.map(&:to_s)
    end

    private

    def mcp_tool_grant_changed?
      return false unless saved_change_to_granted_mcp_tools?
      # A brand-new peer that starts at the default-deny empty grant has not
      # changed any catalog — announcing is not granting.
      return Array(granted_mcp_tools).any? if previously_new_record?

      true
    end

    # Account-scoped by construction: Mcp::SessionNotifier addresses an account,
    # while the grant is per-instance. Deliberate — a tools/list re-fetch is
    # cheap and idempotent, sibling sessions get their own permission-scoped
    # catalog back, and the session -> instance mapping is not resolvable from
    # here. It cannot become a disclosure channel: the notification carries NO
    # params, so a sibling session learns "re-list", never which instance
    # exists or what it was granted. A sibling that re-lists gets its OWN
    # permission-scoped catalog back (Mcp::Principal#filter_tools), so the
    # residual signal is only "some grant in this account changed at time T" —
    # the same account-wide channel semantic_tool_discovery_service already
    # uses.
    #
    # The rescue is belt-and-braces: Mcp::SessionNotifier already swallows its
    # own transport errors, so this only catches a failure to reach it at all.
    # Either way a committed grant must not be undone by a pubsub outage.
    def notify_mcp_tool_catalog_changed
      ::Mcp::SessionNotifier.notify_tools_changed(account)
    rescue StandardError => e
      Rails.logger.warn(
        "[System::NodeInstancePeer] tools/list_changed notify failed for peer #{id}: #{e.message}"
      )
    end

    def capability_revoking_change?
      (saved_change_to_enabled? && !enabled) || saved_change_to_granted_peer_skills?
    end

    def publish_capability_revocation!
      reason = saved_change_to_enabled? && !enabled ? "peer_disabled" : "peer_grants_changed"
      ::System::PeerCapabilityRevocation.publish_for_peer!(self, reason: reason)
    end

    def rollover_window
      return if daily_decision_window_start.present? &&
                daily_decision_window_start >= 24.hours.ago

      assign_attributes(
        daily_decision_window_start: Time.current,
        daily_decision_used: 0
      )
    end

    def window_stale?
      daily_decision_window_start.blank? || daily_decision_window_start < 24.hours.ago
    end
  end
end
