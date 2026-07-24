# frozen_string_literal: true

module System
  module Autonomy
    # RCP v2 (campaign 019f9250, increment p0c) — INV-1: no self-management.
    # A node's management authority must always come from the consensus
    # group, never itself. Every hard failure the RCP campaign traces back to
    # one fault: "ops-hub is its own control plane" — the frozen-LKG boot
    # trap, the 2-day unnoticed outage, the un-deliverable agent, and a
    # recovery that wasn't a clean rollback all root there.
    #
    # Distinct from System::Autonomy::ControlPlaneFence, deliberately:
    #
    #   ControlPlaneFence answers "does a DIFFERENT control-plane deployment
    #   own this instance" — cross-plane arbitration via a per-instance
    #   ownership STAMP (NodeInstance.config["control_plane_id"]), populated
    #   by the dev->ops-hub cutover runbook (#14, a separate task). It is
    #   deliberately INERT until that stamping happens — every instance is
    #   "unclaimed" until then, so both planes still reconcile it.
    #
    #   SelfManagementFence answers "IS this the node hosting ME" — a single
    #   deployment's own reflexive identity, via a DIFFERENT SiteSetting
    #   (self_hosting_node_id) that nothing else gates. INV-1 must hold even
    #   in today's single-plane world (arguably especially then — that is
    #   literally ops-hub's current situation, pre-cutover). Hanging INV-1
    #   enforcement off control_plane_id would inherit ControlPlaneFence's
    #   dormancy exactly when INV-1 matters most, and would incorrectly
    #   treat "I legitimately own this instance" (a plane fencing question)
    #   as equivalent to "I may act on my own host" (an INV-1 question) —
    #   they are orthogonal. A plane can legally OWN the very instance that
    #   hosts it per ControlPlaneFence, and that is exactly the case INV-1
    #   forbids. Hence a distinct fence, not an extension of the existing one
    #   — but the SAME pattern (memoized SiteSetting self-id, nil-safe /
    #   inert by default) and the SAME integration points (provisioning-time
    #   entry points + the fleet reconciler's reap/actuate paths).
    #
    # Both fences are nil-safe/inert by default: unset => always false =>
    # zero behavior change on any currently-running node until an operator
    # deliberately configures the relevant SiteSetting. Check BOTH at every
    # reap/actuate path — they catch different hazards and neither implies
    # the other.
    #
    # NOTE on INV-1b (the bootstrap exception): at cold-start a member may
    # self-compose from its own pinned local known-good image for survival,
    # then immediately submit to quorum. That path is agent-local and
    # offline by construction (INV-2 — no control-plane call on the boot
    # path), so it never calls through this Rails API and never reaches this
    # fence. No bypass flag is needed or provided here; introducing one would
    # be dead, untested code and a footgun for a case that structurally
    # cannot occur through this seam.
    module SelfManagementFence
      # Global SiteSetting key: the System::Node id this deployment's own
      # backend process is hosted on/as. nil (the default) means "unknown /
      # not self-hosted" (e.g. dev, a plain workstation) => fence fully
      # inert. Node-level (not instance-level): a Node persists across
      # instance rebuilds (ops-hub's underlying VM has been recreated
      # several times), so keying on the stable Node is what actually
      # survives a member being rebuilt from a golden image.
      SELF_HOSTING_NODE_ID_KEY = "self_hosting_node_id"

      # Raised by the assert_* form. A StandardError (not ArgumentError) so
      # callers that specifically rescue validation-style ArgumentErrors
      # don't accidentally swallow this — it is a distinct, more severe
      # class of refusal.
      class SelfManagementViolation < StandardError; end

      # Memoized for the life of the including object (mirrors
      # ControlPlaneFence#control_plane_self_id) — one SiteSetting read per
      # reconcile pass / request, not one per instance checked.
      def self_hosting_node_id
        return @self_hosting_node_id if defined?(@self_hosting_node_id)

        @self_hosting_node_id = ::SiteSetting.get(SELF_HOSTING_NODE_ID_KEY).presence
      end

      # True when `target` (a System::Node, System::NodeInstance, or a raw
      # node-id string) IS this deployment's own hosting node — i.e. acting
      # on it would be self-management. Always false when no self-id is
      # configured (inert default).
      def self_managed_target?(target)
        self_id = self_hosting_node_id
        return false if self_id.nil?

        target_node_id(target) == self_id
      end

      # Raising counterpart for provisioning-time hard gates. `action` is a
      # short human label folded into the message (e.g. "provision an
      # instance onto", "terminate"). A no-op whenever self_managed_target?
      # is false (including the fully-inert unconfigured default).
      def assert_not_self_managed!(target, action:)
        return unless self_managed_target?(target)

        raise SelfManagementViolation,
              "refusing to #{action} node #{target_node_id(target).inspect} — it is this " \
              "control plane's own hosting node (INV-1: no self-management). Management " \
              "authority must come from the consensus group, never the node itself."
      end

      private

      def target_node_id(target)
        case target
        when ::System::Node then target.id
        when ::System::NodeInstance then target.node_id
        else target.to_s.presence
        end
      end
    end
  end
end
