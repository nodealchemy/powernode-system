# frozen_string_literal: true

module System
  module Autonomy
    # Shared control-plane fence for every autonomy actuator.
    #
    # When more than one control plane exists (e.g. the dev -> ops-hub cutover),
    # each plane's reconciler must act ONLY on instances its own plane owns —
    # otherwise both planes reconcile the same fleet members over the shared
    # provider and race to reap/reboot them (double-reap). Account scoping does
    # NOT catch this: the two planes can share an account, yet each is a distinct
    # backend deployment.
    #
    # Identity model (read-side; imp 019f6d6b-63e5):
    #   - THIS plane's id: the global SiteSetting `control_plane_id`
    #     (nil = single-plane deployment — the DEFAULT; the fence is then FULLY
    #     INERT and every reconciler behaves exactly as it did before).
    #   - An instance's OWNING plane: NodeInstance.config["control_plane_id"]
    #     (nil = unclaimed -> still reconciled, so newly-provisioned instances
    #     are never orphaned).
    #
    # Fence rule — an instance is actionable by this plane unless:
    #   self-id is set AND the instance's owner is present AND owner != self-id.
    #
    #   self-id nil       -> reconcile all   (single plane; inert)
    #   owner nil          -> reconcile       (unclaimed)
    #   owner == self-id   -> reconcile       (ours)
    #   owner != self-id   -> SKIP            (another plane's)
    #
    # NOTE: this is the READ-SIDE fence only. Nothing here STAMPS owners onto
    # instances — that is the cutover/handoff's job (#14). Until owners are
    # stamped every instance is unclaimed, so the fence stays inert even with a
    # self-id configured. The existing account scoping is KEPT alongside this
    # (belt-and-suspenders: account-scope AND plane-fence).
    #
    # Mix into any reconciler/actuator (it needs no `account` — the self-id is a
    # global deployment identity). Filter reconcile queries with
    # `fence_to_control_plane(relation)` and guard reap/actuate paths with
    # `owned_by_this_control_plane?(instance)`.
    module ControlPlaneFence
      # Identifier name — used for BOTH the global SiteSetting key (this plane's
      # id) and the per-instance config key (an instance's owning plane).
      CONTROL_PLANE_ID_KEY = "control_plane_id"

      # This deployment's control-plane id, or nil for a single-plane deployment
      # (the default — fence inert). Memoized for the life of one reconcile pass.
      def control_plane_self_id
        return @control_plane_self_id if defined?(@control_plane_self_id)

        @control_plane_self_id = ::SiteSetting.get(CONTROL_PLANE_ID_KEY).presence
      end

      # True when this plane may reconcile/actuate on `instance`. Inert (always
      # true) until a self-id is configured; then true unless the instance is
      # explicitly owned by a DIFFERENT plane.
      def owned_by_this_control_plane?(instance)
        self_id = control_plane_self_id
        return true if self_id.nil?

        owner = instance_control_plane_owner(instance)
        owner.blank? || owner == self_id
      end

      # Narrow a NodeInstance relation to instances this plane may act on. Inert
      # (returns the relation unchanged) for a single-plane deployment, so the
      # generated SQL is identical to today when no self-id is configured.
      def fence_to_control_plane(relation)
        self_id = control_plane_self_id
        return relation if self_id.nil?

        col = "#{::System::NodeInstance.table_name}.config ->> '#{CONTROL_PLANE_ID_KEY}'"
        relation.where("#{col} IS NULL OR #{col} = ?", self_id)
      end

      private

      def instance_control_plane_owner(instance)
        cfg = instance.respond_to?(:config) ? instance.config : nil
        cfg.is_a?(Hash) ? cfg[CONTROL_PLANE_ID_KEY].presence : nil
      end
    end
  end
end
