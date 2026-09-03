# frozen_string_literal: true

module System
  # Places and lifts a CORDON on a NodeInstance: "stop scheduling new work
  # here, leave what is running alone". Reversible, and distinct from the two
  # verbs it sits between — a drain (cordon + STOP, PlatformResilienceExecutor
  # #drain_instance) and a terminate (irreversible). The Kubernetes
  # cordon/uncordon shape, applied at the platform layer.
  #
  # IMP-0467eee9fc57. docs/runbooks/node-provisioning.md documented a
  # `cordon_only` parameter on system_drain_instance that never existed; this
  # is the capability the false parameter was standing in for.
  #
  # WHAT A CORDON IS, mechanically — two writes, and the second is the one
  # that binds anything:
  #
  #   MARKER  — `config["cordon"]` = { cordoned_at, by_user_id, reason,
  #             pool_state_before }. Who, why, when, and what to restore. On
  #             its own a marker binds nobody (the drain_* markers this task
  #             was filed against had exactly that defect: written in two
  #             places, read in none). It is here for REVERSIBILITY and
  #             attribution, not as the fence.
  #   FENCE   — for a pool member that is ACQUIRABLE (pool_state "ready"),
  #             pool_state → "draining". That is the one pool_state
  #             InstancePoolService#acquire! never picks and the reaper
  #             (recycle_stale_members!) never touches, and every scheduler
  #             that hands a NodeInstance new work today goes through that
  #             one acquire! query: AgentFleetMissionService#acquire_member,
  #             CiRunnerLeaseService#acquire_instance and the MCP verb
  #             system_acquire_pooled_instance. Fencing the pool_state fences
  #             all of them without a second reader.
  #
  # Why the marker is load-bearing anyway: a bare "draining" is
  # indistinguishable from a drain in flight, a recycled member awaiting
  # terminate, or drain! walking the pool. An uncordon that flipped any
  # "draining" row back to "ready" would resurrect one of those as an
  # acquirable member — so #uncordon! restores ONLY a member this service
  # fenced (pool_state_before "ready"), ONLY while it is still "draining", and
  # ONLY if the instance is running. Everything else fails closed.
  #
  # Three pool states are deliberately NOT fenced:
  #   claimed  — already un-acquirable, and both release paths
  #              (system_return_pooled_instance, AgentFleetMissionService
  #              #reap_member!) guard on pool_state == "claimed", so flipping
  #              it would strand the member. Marker only. When its consumer
  #              returns it, the default "recycled" disposition terminates it;
  #              on a pool opted into reuse_without_reset,
  #              InstancePoolService#release! reads the marker and hands the
  #              member to #fence_admission! (pool_state "draining",
  #              disposition "cordoned") instead of re-marking it "ready"
  #              (IMP-c9adb5a71dca).
  #   draining — already fenced by someone else's write. Marker only, and the
  #              uncordon will not restore it (pool_state_before "draining").
  #   warming / errored — REFUSED. A warming member is not acquirable yet, and
  #              this service does not pre-cordon a member ahead of its
  #              admission; an errored member is on its way out. (Should a
  #              marker reach a warming member by another route,
  #              NodeInstance#mark_pool_ready! honours it: the heartbeat
  #              promotion lands on "draining" via #fence_admission!, never on
  #              "ready" — IMP-c9adb5a71dca.)
  #
  # A non-pool instance gets the marker alone (`not_pooled`): there is no
  # allocator to fence it out of. The marker's readers beyond acquire! all go
  # through the ONE predicate this service owns — NodeInstance#cordoned? and
  # the .cordoned / .not_cordoned scopes (#cordoned_relation /
  # #not_cordoned_relation below): System::Platform::ReplicaReconciler keeps a
  # cordoned replica OUT of the live count (so it provisions a replacement)
  # and takes it FIRST as a scale-in victim (IMP-c9adb5a71dca). The node_api
  # task lease does not read the marker (recorded on the task).
  #
  # The fence write is CONDITIONAL (update_all ... where pool_state: "ready"):
  # acquire! claims under a row lock, and a plain update! after a stale read
  # would write "draining" over "claimed" and strand the consumer's member.
  # Same for the restore.
  #
  # Nothing here checks permission or the self-management fence: callers do
  # (the MCP verbs require system.instances.control and park under the
  # system.instance_cordon category). A cordon stops nothing, so INV-1 does not
  # apply — cordoning the control plane's own node takes it out of the pool,
  # not offline.
  class InstanceCordonService
    CONFIG_KEY = "cordon"

    # How many times #fence! re-reads and retries after losing the conditional
    # ready → draining flip to the allocator. Not operator-tunable: it bounds
    # an optimistic-concurrency retry, not a policy threshold.
    FENCE_ATTEMPTS = 3

    # cordon_state after #cordon!:
    #   fenced      — pool member flipped ready → draining
    #   claimed     — marker only; already un-acquirable
    #   already_fenced — marker only; pool_state was already draining
    #   not_pooled  — marker only; no allocator
    # after #uncordon!:
    #   restored    — member handed back to the allocator (draining → ready)
    #   cleared     — marker removed, pool_state untouched
    Result = Struct.new(:ok, :instance, :cordon_state, :message, :error, keyword_init: true) do
      def ok? = ok
    end

    def self.cordon!(...)   = new.cordon!(...)
    def self.uncordon!(...) = new.uncordon!(...)

    def self.cordoned?(instance)
      marker(instance).present?
    end

    def self.marker(instance)
      value = instance.config&.dig(CONFIG_KEY)
      value.is_a?(Hash) ? value : nil
    end

    # SQL twins of .cordoned?, for the readers that count or order in the
    # database (ReplicaReconciler#live_scope / #scale_in). Same shape as the
    # Ruby predicate — a Hash under CONFIG_KEY — so the two cannot disagree
    # on a row. `jsonb_typeof` of a missing key is NULL, which is why the
    # negation is COALESCEd rather than written as `<>`: a plain `NOT (NULL)`
    # would drop every un-cordoned row from the "not cordoned" scope.
    def self.cordoned_relation(relation)
      relation.where(marker_present_sql, key: CONFIG_KEY)
    end

    def self.not_cordoned_relation(relation)
      relation.where("NOT COALESCE(#{marker_present_sql}, false)", key: CONFIG_KEY)
    end

    def self.marker_present_sql
      "jsonb_typeof(#{::System::NodeInstance.quoted_table_name}.config -> :key) = 'object'"
    end
    private_class_method :marker_present_sql

    # Called by the two writers that ADMIT a member to the acquirable set —
    # NodeInstance#mark_pool_ready! (warming → ready on heartbeat) and
    # InstancePoolService#release! on a reuse_without_reset pool (claimed →
    # ready) — when the member they are about to admit is cordoned. Fences it
    # to "draining" instead (conditional on the pool_state the caller saw, the
    # same optimistic write as #fence!) and re-records the marker's restore
    # target as "ready": ready is the state the admission would have produced,
    # so it is what #uncordon! hands back. The two writes are one transaction
    # for the reason #cordon! gives — a fence with no restore target is a
    # member nothing can re-admit except by hand.
    #
    # Returns true when the member was fenced, false when it was not cordoned
    # or its pool_state moved before the flip (the caller then re-reads).
    def self.fence_admission!(instance, from:)
      marker = marker(instance)
      return false unless marker && instance.in_pool?

      fenced = false
      ::ActiveRecord::Base.transaction do
        flipped = ::System::NodeInstance.where(id: instance.id, pool_state: from)
                                        .update_all(pool_state: "draining", pool_acquired_at: nil,
                                                    updated_at: Time.current)
        instance.reload
        next unless flipped.positive?

        instance.merge_config!({ CONFIG_KEY => marker.merge("pool_state_before" => "ready") })
        fenced = true
      end
      Rails.logger.info("[InstanceCordonService] #{instance.id} fenced at admission (#{from} → draining) under its cordon") if fenced
      fenced
    end

    # PRE-FLIGHT REFUSALS, exposed so the approval gate can ask them BEFORE
    # parking: an approval-gated verb never reaches #cordon! until an
    # operator approves, and an approval for a cordon that could only ever be
    # refused on replay (already cordoned, blank reason, warming member) is
    # one an operator then has to dispose of. Returns the refusal message, or
    # nil when the write may proceed. Read-only. #cordon! re-asks the same
    # question, so the two doors cannot disagree.
    def self.cordon_refusal(instance:, reason:)
      return "reason is required — an unattributed cordon is indistinguishable from a bug later" if reason.blank?
      return "#{instance.name} is terminated; there is nothing to cordon" if instance.status == "terminated"
      if cordoned?(instance)
        m = marker(instance)
        return "#{instance.name} is already cordoned (since #{m['cordoned_at']}, reason: #{m['reason']})"
      end

      pool_state_refusal(instance)
    end

    def self.uncordon_refusal(instance:)
      m = marker(instance)
      return "#{instance.name} is not cordoned" unless m
      return nil unless m["pool_state_before"] == "ready" && instance.in_pool? && instance.pool_state == "draining"
      return nil if instance.status == "running"

      # Fail closed: a "ready" member that is not running is handed to its
      # next consumer as a dead VM. Start it, then uncordon.
      "#{instance.name} is #{instance.status}, not running — re-admitting it to the pool would hand " \
        "a consumer a dead member. Start it first, then uncordon."
    end

    def self.pool_state_refusal(instance)
      return nil unless instance.in_pool?

      case instance.pool_state
      when "ready", "claimed", "draining" then nil
      when "warming"
        "#{instance.name} is a warming pool member: it is not acquirable yet, and a cordon is not " \
          "placed ahead of a member's admission. Wait for it to reach ready, or drain it."
      else
        "#{instance.name} is a pool member in pool_state #{instance.pool_state.inspect}, which the " \
          "allocator already never hands out and the reaper is retiring; there is nothing to cordon"
      end
    end

    def cordon!(instance:, user:, reason:)
      why = self.class.cordon_refusal(instance: instance, reason: reason)
      return err(instance, why) if why

      # ONE transaction, because the fence and the marker are two writes and
      # only the pair is meaningful. A failure between them would leave a pool
      # member in pool_state "draining" with no marker: #uncordon! refuses it
      # ("is not cordoned"), and a re-cordon classifies it as "already_fenced"
      # — whose marker records pool_state_before "draining", so ITS uncordon
      # never writes "ready" back either. The member would be permanently
      # unschedulable except by hand.
      state = nil
      ::ActiveRecord::Base.transaction do
        state = fence!(instance)

        # "fenced" means THIS write took the member from "ready" to "draining",
        # and "ready" is what #uncordon! restores. Every other state is recorded
        # as the pool_state the fence found (read after the conditional flip, so
        # a member the allocator claimed between our read and our write is
        # recorded as "claimed", never as the "ready" we last saw).
        #
        # A refusal Result writes nothing, so it leaves the block without
        # raising — `return` from inside a transaction block COMMITS in Rails,
        # and there would be nothing to roll back anyway.
        unless state.is_a?(Result)
          # One key at a time through System::ConfigDocument, never
          # `update!(config: <whole document>)`: `config` is a SHARED jsonb
          # document and the node's telemetry lanes merge into it continuously,
          # so a read-modify-write here erases whatever landed in between.
          instance.merge_config!({
            CONFIG_KEY => {
              "cordoned_at"       => Time.current.iso8601,
              "by_user_id"        => user&.id,
              "reason"            => reason,
              "pool_state_before" => state == "fenced" ? "ready" : instance.pool_state
            }
          })
        end
      end
      return state if state.is_a?(Result)

      emit_event!(instance, kind: "system.instance.cordoned",
                            payload: { cordon_state: state, reason: reason, by_user_id: user&.id })

      Result.new(ok: true, instance: instance, cordon_state: state, message: cordon_message(instance, state))
    end

    def uncordon!(instance:, user: nil)
      why = self.class.uncordon_refusal(instance: instance)
      return err(instance, why) if why

      marker = self.class.marker(instance)

      # Mirror hazard of the cordon pair, and the one that fails UNSAFE: a
      # failure between the restore and the clear leaves an ACQUIRABLE member
      # that #cordoned? still reports true for.
      state = nil
      ::ActiveRecord::Base.transaction do
        state = restore!(instance, marker)
        instance.delete_config_keys!(CONFIG_KEY) unless state.is_a?(Result)
      end
      return state if state.is_a?(Result)

      emit_event!(instance, kind: "system.instance.uncordoned",
                            payload: { cordon_state: state, by_user_id: user&.id,
                                       cordoned_at: marker["cordoned_at"], reason: marker["reason"] })

      Result.new(ok: true, instance: instance, cordon_state: state, message: uncordon_message(instance, state))
    end

    private

    # Returns a cordon_state string, or a Result on refusal.
    #
    # BOUNDED, not recursive: losing the conditional flip means the row moved
    # to some other pool_state, but the state it moved to can be "ready" again
    # (acquire! claims it, the consumer returns it through the
    # reuse_without_reset path, which re-marks it ready). A self-call on that
    # arm has no terminal case, so a contended member could drive unbounded
    # recursion and UPDATE churn. Three passes, then refuse and say so.
    def fence!(instance)
      return "not_pooled" unless instance.in_pool?

      FENCE_ATTEMPTS.times do
        case instance.pool_state
        when "ready"
          flipped = ::System::NodeInstance.where(id: instance.id, pool_state: "ready")
                                          .update_all(pool_state: "draining", updated_at: Time.current)
          instance.reload
          return "fenced" if flipped.positive?
          # Lost the race — re-read and re-classify on the state that won.
        when "claimed"  then return "claimed"
        when "draining" then return "already_fenced"
        else
          # The pre-flight already refused warming/errored; reaching here means
          # the pool_state moved underneath us. Same refusal, same words.
          return err(instance, self.class.pool_state_refusal(instance) ||
                               "#{instance.name} changed pool_state to #{instance.pool_state.inspect} mid-cordon; retry")
        end
      end

      err(instance, "#{instance.name} changed pool_state under #{FENCE_ATTEMPTS} cordon attempts " \
                    "(now #{instance.pool_state.inspect}); the allocator is actively churning it — retry")
    end

    def restore!(instance, marker)
      return "cleared" unless marker["pool_state_before"] == "ready" && instance.in_pool?
      return "cleared" unless instance.pool_state == "draining"

      # Re-asked here, not only in the pre-flight: the status can move between
      # the gate's check and an approved replay.
      if (why = self.class.uncordon_refusal(instance: instance))
        return err(instance, why)
      end

      # pool_warming_started_at doubles as the ready-TTL anchor in
      # InstancePoolService#recycle_stale_members!; restarting it here mirrors
      # the reuse path in #release!, so a member cordoned for longer than
      # ready_ttl_seconds is not stale-recycled on the next reaper tick.
      now = Time.current
      restored = ::System::NodeInstance.where(id: instance.id, pool_state: "draining")
                                       .update_all(pool_state: "ready", pool_warming_started_at: now,
                                                   updated_at: now)
      instance.reload
      restored.positive? ? "restored" : "cleared"
    end

    def cordon_message(instance, state)
      case state
      when "fenced"
        "#{instance.name} cordoned: pool_state=draining, so the allocator will not hand it out; " \
        "it keeps running and keeps whatever it is doing. system_uncordon_instance reverses this."
      when "claimed"
        "#{instance.name} cordoned. It is CLAIMED by a consumer, so it was not flipped — it is " \
        "already un-acquirable. When its consumer returns it, the default recycled disposition " \
        "terminates it; on a pool opted into reuse_without_reset it is fenced (pool_state=draining) " \
        "instead of re-admitted, and system_uncordon_instance restores it."
      when "already_fenced"
        "#{instance.name} cordoned. Its pool_state was already draining (a drain or recycle is in " \
        "flight), so nothing was flipped and an uncordon will not restore it to ready."
      else
        "#{instance.name} cordoned. It is not a pool member, so no allocator was fenced; the marker " \
        "is visible on system_get_instance as `cordon`. If a platform deployment owns this " \
        "instance, System::Platform::ReplicaReconciler honours the marker: it is left out of the " \
        "live count (so target_replicas provisions a replacement) and is the first scale-in victim."
      end
    end

    def uncordon_message(instance, state)
      if state == "restored"
        "#{instance.name} uncordoned: pool_state=ready, acquirable again with a fresh ready-TTL anchor."
      else
        "#{instance.name} uncordoned: marker cleared; pool_state (#{instance.pool_state.inspect}) untouched."
      end
    end

    def emit_event!(instance, kind:, payload:)
      return unless defined?(::System::FleetEvent)

      ::System::FleetEvent.create!(
        account_id: instance.account_id,
        kind: kind,
        severity: "low",
        payload: payload.merge(instance_id: instance.id, instance_name: instance.name),
        node_instance_id: instance.id,
        emitted_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.warn("[InstanceCordonService] #{kind} not emitted for #{instance.id}: #{e.message}")
    end

    def err(instance, message)
      Result.new(ok: false, instance: instance, error: message)
    end
  end
end
