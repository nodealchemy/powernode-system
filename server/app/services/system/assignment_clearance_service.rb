# frozen_string_literal: true

module System
  # The platform's per-module statement that it unassigned a module from a node
  # (IMP-9f4e162d9ed1).
  #
  # WHY IT EXISTS. The node agent fails closed on an assignment list that names no
  # data-bearing module while modules are attached (IMP-1023e79cc82d): success:true
  # with an empty list is indistinguishable from a degraded answer, and acting on
  # it detaches every module and, on a node with no boot breadcrumb, renders
  # /etc/passwd down to the baseline. That left the platform unable to say "these
  # modules were unassigned" for the five flows that empty a node on purpose:
  # re-templating onto a module-less template, a purging apply_template, removing
  # a template's last module then purging, disabling a node's last assignment, and
  # disabling a NodeModule globally.
  #
  # WHAT IT IS. A row per (node, module), written by the server action that removed
  # the module from the node's served list (the callbacks on NodeModuleAssignment
  # and NodeModule) and served on GET node_api/modules as data.confirmed_unassigned.
  # The agent detaches on an untrusted list only a module named there.
  #
  # WHY IT CANNOT BE FORGED BY THE FAILURE THAT PRODUCES A SPURIOUS EMPTY LIST.
  # A row is a POSITIVE fact created by a write, never derived from the list being
  # empty. A read that comes back empty (a wrong account, a database hiccup, a
  # backend that answered with nothing) therefore returns an empty confirmation
  # set too: absence yields absence. A row exists only if a removal was recorded,
  # in the same commit as the removal, with an audit row. Stale rows are bounded
  # four ways: they expire (TTL); they are revoked the moment the module is
  # assigned or enabled again, in the enabling transaction, so a failed revoke
  # rolls the assign back rather than being swallowed (only ISSUES are swallowed,
  # see .guarded); the response never lists a module it is itself serving (the
  # controller subtracts the served set); and the agent drops a confirmation its
  # own list contradicts. Audit granularity: one row per issue! call, which the
  # per-assignment callbacks make one per assignment; issue_for_module! writes one
  # per module.
  #
  # WHAT IT IS NOT. It is not signed: the response is authenticated by mTLS like
  # every node_api answer, no more. The fail-closed rule guards against a degraded
  # path, not a hostile control plane, which could already attach any module it
  # liked. See docs on IMP-9f4e162d9ed1 for the residual cases.
  class AssignmentClearanceService
    DEFAULT_TTL = 7.days
    # A bad or tiny setting shortens the window to this, never to zero: an expired
    # clearance fails CLOSED (the agent keeps the module), so the floor exists to
    # keep a typo from making the feature silently inert, not for safety.
    TTL_FLOOR = 1.hour
    TTL_SETTING = "system.assignment_clearance.ttl_seconds"

    AUDIT_ACTION = "system.assignment_clearance.issued"
    # Registered with core's AuditActions seam by the engine's
    # register_audit_actions initializer (an unregistered action fails AuditLog's
    # inclusion validation, which the model callbacks would swallow).
    AUDITED_ACTIONS = [ AUDIT_ACTION ].freeze
    MAX_AUDITED_MODULE_IDS = 50
    UPSERT_BATCH = 500

    class << self
      # Record that +node_module_ids+ were unassigned from +node+. One audit row for
      # the batch. Returns the number of clearances written.
      def issue!(node:, node_module_ids:, reason:, trigger: {})
        ids = Array(node_module_ids).compact.map(&:to_s).uniq
        return 0 if ids.empty? || node.nil? || !::System::Node.exists?(node.id)

        write!(ids.map { |module_id| [ node.id, module_id ] }, account_id: node.account_id, reason: reason)
        audit!(resource: node, account_id: node.account_id, reason: reason,
               metadata: { "module_count" => ids.size, "node_module_ids" => ids.first(MAX_AUDITED_MODULE_IDS) }.merge(trigger))
        ids.size
      end

      # A module left every node that served it (disabled, or destroyed): one row
      # per serving node, ONE audit row for the module. The blast radius is exactly
      # the nodes whose served list changes, and the audit row states how many.
      def issue_for_module!(node_module:, reason:)
        node_ids = serving_node_ids(node_module)
        return 0 if node_ids.empty?

        write!(node_ids.map { |node_id| [ node_id, node_module.id ] }, account_id: node_module.account_id, reason: reason)
        audit!(resource: node_module, account_id: node_module.account_id, reason: reason,
               metadata: { "node_count" => node_ids.size, "node_module_ids" => [ node_module.id ] })
        node_ids.size
      end

      # The module is assigned or enabled again: whatever said it was unassigned is
      # no longer true THERE. Scoped to one node (node_id), to the nodes where the
      # module is served again (node_ids), or to every node when neither is named.
      # Raises on failure; see #guarded for why a revoke is never swallowed.
      def revoke!(node_module_ids:, node_id: nil, node_ids: nil)
        ids = Array(node_module_ids).compact.map(&:to_s).uniq
        return 0 if ids.empty?

        scope = ::System::NodeAssignmentClearance.where(node_module_id: ids)
        scope = scope.where(node_id: node_id) if node_id
        scope = scope.where(node_id: node_ids) if node_ids
        scope.delete_all
      end

      # What GET node_api/modules serves for +node+: its live clearances, newest
      # first. Never raises into the caller's response: a failed lookup is an EMPTY
      # confirmation set, which is the fail-closed answer.
      def served_for(node)
        ::System::NodeAssignmentClearance.live.where(node_id: node.id).order(:issued_at).map do |row|
          { module_id: row.node_module_id, reason: row.reason, issued_at: row.issued_at.utc.iso8601,
            expires_at: row.expires_at.utc.iso8601 }
        end
      end

      # Runs an ISSUE from a model callback. A SAVEPOINT, so a failure here cannot
      # poison the caller's transaction, and swallowed after logging: the operator's
      # removal must not be blocked by its own bookkeeping. Swallowing is safe ONLY
      # because a failed issue means no confirmation, so the agent keeps the module
      # and the node reports a persistent empty_assignment deferral (the fail-closed
      # direction). NEVER wrap a revoke in this: a failed revoke that is swallowed
      # leaves a live confirmation on a module that is assigned again, which is the
      # fail-OPEN direction. A revoke runs bare, inside the enabling transaction, so
      # if it fails the assign or enable rolls back with it.
      def guarded(context)
        ::ActiveRecord::Base.transaction(requires_new: true) { yield }
      rescue StandardError => e
        ::Rails.logger.error("[AssignmentClearance] #{context}: #{e.class}: #{e.message}")
        nil
      end

      def ttl
        raw = ::SiteSetting.get(TTL_SETTING).presence
        seconds = raw.to_s.match?(/\A\d+\z/) ? raw.to_i : nil
        return DEFAULT_TTL if seconds.nil?

        [ seconds.seconds, TTL_FLOOR ].max
      end

      # Nodes whose SERVED list contains the module: an enabled assignment, plus the
      # node a dependant child is bound to (node_modules in NodeApi::ModulesController
      # serves both). A node whose own assignment is already disabled never served it.
      def serving_node_ids(node_module)
        ids = ::System::NodeModuleAssignment.where(node_module_id: node_module.id, enabled: true).pluck(:node_id)
        ids << node_module.node_id if node_module.node_id.present?
        ids.uniq
      end

      private

      # pairs: [[node_id, node_module_id], ...]
      def write!(pairs, account_id:, reason:)
        now = Time.current
        expires_at = now + ttl
        rows = pairs.map do |node_id, module_id|
          { account_id: account_id, node_id: node_id, node_module_id: module_id, reason: reason,
            issued_at: now, expires_at: expires_at, metadata: {}, created_at: now, updated_at: now }
        end
        upsert!(rows)
      end

      def upsert!(rows)
        rows.each_slice(UPSERT_BATCH) do |batch|
          ::System::NodeAssignmentClearance.upsert_all(
            batch,
            unique_by: :index_node_assignment_clearances_on_node_and_module,
            update_only: %i[reason issued_at expires_at]
          )
        end
      end

      def audit!(resource:, account_id:, reason:, metadata:)
        ::AuditLog.create!(
          account_id: account_id,
          action: AUDIT_ACTION,
          resource_type: resource.class.name,
          resource_id: resource.id.to_s,
          source: "system",
          metadata: { "reason" => reason }.merge(metadata)
        )
      end
    end
  end
end
