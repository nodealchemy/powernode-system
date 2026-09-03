# frozen_string_literal: true

module System
  module Executors
    module InstancePool
      # IMP-714ab7da6b9c — NO PRODUCER, AND THAT IS THE DECISION. Nothing
      # constructs an Ai::DeferredOperation naming this class: no site assigns
      # `executor_class` to it, and no site composes the name either. Both
      # halves are pinned continuously by
      # spec/lint/instance_pool_replenish_gating_spec.rb, which scans
      # server/, worker/ and every extensions/*/server tree it can find — so a
      # producer added ANYWHERE in this checkout reds that guard. Do NOT delete
      # this file as tidy-up: it is the record of the intent, and re-wiring it
      # is the whole fix if the decision below is ever revisited.
      #
      # THE ASYMMETRY. Of the five instance-pool executors only CreatePool and
      # DeletePool have producers (InstancePoolsController#create and
      # #destroy, via Ai::GatedActions). Replenish — the verb that actually
      # spends money, provisioning VMs and minting `ephemeral`/`spot` Nodes
      # through InstancePoolService#provision_warming_member! — reaches
      # ::System::InstancePoolService.replenish! directly from its operator
      # surfaces: InstancePoolsController#replenish and the MCP verb
      # system_replenish_instance_pool. A third path,
      # System::InstancePoolReplenisherJob
      # (worker/app/jobs/system/instance_pool_replenisher_job.rb), reaches the
      # first of those over HTTP on a 60 s Sidekiq cron
      # (worker/config/sidekiq.yml). It LISTS with status=active,draining —
      # draining pools for the recycle phase — but POSTs replenish only for
      # the active ones (IMP-cb2da06a384b; replenish! refuses a non-active
      # pool either way). (db/seeds/example_instance_pool.rb calls the
      # service too, on a seeded pool.) Note which way round that runs: the
      # two verbs that ARE gated are pool creation and teardown, while the
      # verb with the spend attached is not. (_drain and _acquire are ungated
      # too, as is every _update transition except the ceiling raise and the
      # archive IMP-24daa05e7a22 gated — replenish is simply the one this note
      # is about.)
      #
      # WHY UNGATED IS DELIBERATE. The policy for the verb already exists and
      # already says so: PolicyDeclarations::INSTANCE_POOL_POLICIES maps
      # "system.instance_pool_replenish" => "auto_approve" ("tops up to target
      # — routine"), beside "system.instance_pool_create" =>
      # "require_approval". That pairing IS the argument. A replenish tick is
      # idempotent and doubly bounded — by `target_size` (InstancePool#deficit)
      # and again by `max_size` headroom, the P2.5 gap-#6 cap in
      # InstancePoolService#replenish! — so a tick can never exceed the
      # capacity ceiling standing on the pool.
      #
      # THE LIMITS OF THAT ARGUMENT, stated rather than glossed. "The spend was
      # approved at pool-create time" is the weak half, twice over:
      #   * The ceiling is not immutable behind a gated verb.
      #     InstancePoolsController#update permits :target_size, :max_size and
      #     :status, and until IMP-24daa05e7a22 applied all three inline: the
      #     ceiling could be raised without an approval and the next tick would
      #     spend up to the new one, and PATCH "archived" reproduced what the
      #     gated destroy does. An INCREASE to either size now gates under
      #     "system.instance_pool_ceiling_raise" and the archive transition
      #     under "system.instance_pool_archive" — on the REST route AND, since
      #     IMP-067f39468350, on the MCP verb system_update_instance_pool,
      #     which routes through the same two categories via
      #     Ai::Executors::DeferredToolCall. Decreases, min_size and status
      #     "paused"/"draining" stay inline on BOTH doors by operator
      #     direction, and TWO writers still move the same columns with no
      #     approval at all: System::Gitops::ApplyService#apply! (POOL_SCALAR_KEYS)
      #     — whose MCP door system_gitops_apply_proposal now gates under
      #     system.gitops_apply_proposal (IMP-0b4f18ae4384), leaving
      #     Reconciler#auto_apply_proposal (the repository's own auto_apply
      #     opt-in) and DecisionEngine#apply_gitops_drift (system.gitops_drift_
      #     remediate, seeded notify_and_proceed) as its ungated callers — and
      #     System::CiRunnerLeaseService. Both are censused by file and count
      #     in spec/lint/instance_pool_replenish_gating_spec.rb.
      #   * #create is gated on BOTH DOORS as of IMP-067f39468350 — the REST
      #     route under "system.instance_pool_create" and the MCP verb
      #     system_create_instance_pool under the same category — but a pool
      #     can still be minted with no approved ceiling by GitOps apply and
      #     the CI-runner lease, so "the spend was approved at pool-create
      #     time" remains a claim about the operator doors, not about the
      #     column. That is what keeps this bullet alive.
      # #update was the verb worth gating, and both of its operator doors are
      # gated now — gating replenish catches the actuator and misses the
      # decision. GitOps apply and the CI-runner lease still reach the
      # decision ungated.
      #
      # WHAT A GATE HERE WOULD COST. A require_approval gate on an unattended
      # 60 s cron would park one approval per pool per minute and stall
      # replenishment for every active pool — an availability decision wearing
      # a control's clothes, not a control.
      #
      # WHAT WAS ALSO WRONG, and is now SETTLED (IMP-5a2b801f3386).
      # "system.instance_pool_replenish" used to be seeded onto the OPERATOR
      # path as well (POLICY_SETS "instance-pool-operator", scope global),
      # together with _acquire, _drain and _update — four categories with a
      # policy row an operator can edit and no gate site that reads it. That is
      # the shape RUNTIME_OPERATOR_GATED_KEYS was introduced to avoid
      # (IMP-9b9653e6514e, which restricted the runtime operator row to its
      # gated subset for exactly this reason). The operator set is now the
      # gated subset — INSTANCE_POOL_OPERATOR_POLICIES — so an operator is no
      # longer shown a replenish control that governs nothing. That changes
      # NOTHING about this executor or about the decision above: replenish is
      # still ungated, still by decision, and Fleet Autonomy's AGENT-scoped row
      # for it is untouched. Pinned by
      # spec/db/seeds/system_instance_pool_operator_policies_spec.rb.
      class ReplenishPool < ::System::Executors::Base
        protected

        def perform
          pool = ::System::InstancePool.find(params[:pool_id])
          # replenish! is an InstancePoolService class method (pool: kwarg),
          # not a model method — the previous respond_to?(:replenish!) guard
          # was always false, so this executor silently no-opped.
          result = ::System::InstancePoolService.replenish!(pool: pool)
          { pool_id: pool.id, replenished: result[:provisioned] }
        end

        def summarize = "Replenish instance pool #{params[:pool_id]} to target size"
      end
    end
  end
end
