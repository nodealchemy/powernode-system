# frozen_string_literal: true

module System
  # Slice 7 — orchestrates pre-warmed instance pool operations.
  #
  # Three core operations:
  #   - acquire!  : atomically claim the oldest ready member (concurrency-safe)
  #   - replenish! : provision new instances to bring ready+warming up to target_size
  #   - drain!    : terminate ready members + halt replenishment
  #
  # All operations are idempotent and safe to retry. Atomic acquire uses
  # Postgres row-level locking (SELECT ... FOR UPDATE SKIP LOCKED) so
  # concurrent operators racing for the same pool member each get a
  # different instance (or NoReadyMembersError when the pool is empty).
  class InstancePoolService
    include ::System::DevCellDeployKeyRevocation
    class PoolError < StandardError; end
    class NoReadyMembersError < PoolError; end
    class PoolNotActiveError < PoolError; end
    class PoolAtMaxCapacityError < PoolError; end
    class InvalidPoolStateError < PoolError; end

    # How long a dead pool member's DB records survive before the reaper
    # prunes them. Pool members are ephemeral (a CI builder lives minutes), so
    # a week is already generous for post-mortem inspection while keeping the
    # fleet list bounded. Override per pool with
    # metadata["record_retention_days"]; 0 or negative disables pruning.
    DEAD_RECORD_RETENTION_DAYS = 7

    # Maximum age (seconds) for a "warming" instance before the reaper
    # marks it errored. Provider boot + agent enrollment + module attach
    # should reach "running" + ready within ~10min for cloud, longer for
    # cold-boot physical. Bumping this on a per-pool basis is a future
    # extension via metadata["warming_timeout_seconds"].
    DEFAULT_WARMING_TIMEOUT_SECONDS = 1800 # 30 min

    # Maximum age (seconds) for a "ready" pool member before the reaper
    # recycles it. Prevents a stale member that's been ready for hours
    # from being acquired and immediately failing because some
    # underlying provider state expired (security group changed, IP
    # released, etc). Configurable per-pool via metadata.
    DEFAULT_READY_TTL_SECONDS = 4 * 3600 # 4 hours

    # F1-10 — maximum claim age (seconds) before the reaper flags a
    # "claimed" member for operator review. Generous: claims normally
    # last minutes-to-hours; anything past a day is most likely a
    # consumer that crashed after acquire! and leaked the member (each
    # leak occupies max_size headroom forever, shrinking the pool).
    # Configurable per-pool via metadata["claimed_ttl_seconds"].
    DEFAULT_CLAIMED_TTL_SECONDS = 24 * 3600 # 24 hours

    # Bound + backoff for the errored → terminated cleanup phase. That phase
    # retries a CLOUD PROVIDER call from a reaper that ticks every 60s, so
    # unbounded retries are not an option: a permanently-failing terminate
    # (credentials revoked, VM stranded on a dead hypervisor, provider
    # rejecting the delete) would otherwise cost 1440 provider calls per
    # member per day, forever.
    #
    #   - MAX_ATTEMPTS caps the total number of terminate calls one member
    #     can ever cost.
    #   - BACKOFF_SECONDS is the BASE of an exponential delay between
    #     attempts — base * 2^(attempts - 1), capped at BACKOFF_CAP_SECONDS,
    #     measured from the member's last recorded attempt.
    #
    # With the defaults a stuck member costs at most 5 provider calls spread
    # over ~75 minutes (attempt 1 immediately, then +5m, +10m, +20m, +40m)
    # before the reaper stops and escalates to the operator (error log +
    # high-severity FleetEvent — see #abandon_errored_member!).
    #
    # The numbers are POLICY. Override per pool via
    # metadata["errored_terminate_max_attempts"] /
    # ["errored_terminate_backoff_seconds"] /
    # ["errored_terminate_backoff_cap_seconds"], same shape as
    # ["warming_timeout_seconds"] / ["record_retention_days"]. A missing,
    # non-numeric, or non-positive override falls back to the default rather
    # than being taken literally — a 0 cap would silently disable cloud
    # cleanup (leaking VMs), and a 0 backoff would restore the every-60s
    # hammering this bound exists to prevent.
    DEFAULT_ERRORED_TERMINATE_MAX_ATTEMPTS = 5
    DEFAULT_ERRORED_TERMINATE_BACKOFF_SECONDS = 300 # 5 min
    DEFAULT_ERRORED_TERMINATE_BACKOFF_CAP_SECONDS = 3600 # 1 hour

    # IMP-68403ec0358d — the claim ledger's event kinds. `claimed` is written
    # inside acquire!'s transaction; `released` is written by release! on every
    # disposition it has. The pair is correlated by a minted claim id.
    CLAIM_EVENT_KIND = "system.pool.claimed"
    RELEASE_EVENT_KIND = "system.pool.released"

    # The claim id minted by the most recent #acquire! on THIS service instance
    # (nil before the first one). #acquire! has to keep returning the member —
    # four internal callers and the MCP verb read it directly — so the id is
    # exposed here rather than by changing that return type.
    attr_reader :last_claim_id

    def self.acquire!(account:, pool_name: nil, pool_id: nil, lifecycle_class: nil,
                      acquired_by: nil, acquired_for: nil)
      new(account: account).acquire!(
        pool_name: pool_name,
        pool_id: pool_id,
        lifecycle_class: lifecycle_class,
        acquired_by: acquired_by,
        acquired_for: acquired_for
      )
    end

    def self.release!(instance:, pool:)
      new(account: pool.account).release!(instance: instance, pool: pool)
    end

    def self.replenish!(pool:)
      new(account: pool.account).replenish!(pool: pool)
    end

    def self.drain!(pool:)
      new(account: pool.account).drain!(pool: pool)
    end

    def self.recycle_stale_members!(pool:)
      new(account: pool.account).recycle_stale_members!(pool: pool)
    end

    def initialize(account:)
      @account = account
    end

    # Atomic acquire — claims the oldest ready pool member.
    # Concurrency-safe via SELECT ... FOR UPDATE SKIP LOCKED.
    #
    # Pool selection priority:
    #   1. Specific pool_id if provided
    #   2. Specific pool_name if provided
    #   3. Any active pool with matching lifecycle_class + ready members
    #
    # CALLER ATTRIBUTION (IMP-68403ec0358d). `acquired_by` (the claiming actor)
    # and `acquired_for` (the workload) are free text, both optional, and are
    # recorded on a durable claim record — see #record_claim!.
    def acquire!(pool_name: nil, pool_id: nil, lifecycle_class: nil,
                 acquired_by: nil, acquired_for: nil)
      pool = resolve_pool!(pool_name: pool_name, pool_id: pool_id, lifecycle_class: lifecycle_class)
      # F2-02 — draining pools never hand out members. drain! terminates
      # all ready inventory immediately, so anything still acquirable in a
      # draining pool is either mid-drain (racing termination) or a warming
      # member that ripened post-drain and escaped the wind-down.
      raise PoolNotActiveError, "pool '#{pool.name}' is #{pool.status}" unless pool.active?

      ::ActiveRecord::Base.transaction do
        member = pool.node_instances
                     .where(pool_state: "ready")
                     .order(Arel.sql("pool_warming_started_at NULLS LAST"))
                     .lock("FOR UPDATE SKIP LOCKED")
                     .first

        raise NoReadyMembersError, "no ready members in pool '#{pool.name}' " \
                                   "(target=#{pool.target_size}, ready=#{pool.ready_count}, " \
                                   "warming=#{pool.warming_count}). Reaper will replenish." unless member

        acquired_at = Time.current
        member.update!(
          pool_state: "claimed",
          pool_acquired_at: acquired_at
        )

        # INSIDE the transaction, and deliberately not through
        # EventBroadcaster.emit! — see #record_claim!.
        record_claim!(pool: pool, member: member, acquired_at: acquired_at,
                      acquired_by: acquired_by, acquired_for: acquired_for)

        Rails.logger.info(
          "[InstancePoolService] acquired pool member " \
          "pool_id=#{pool.id} member_id=#{member.id} claim_id=#{@last_claim_id} " \
          "acquired_by=#{acquired_by.inspect} acquired_for=#{acquired_for.inspect} " \
          "ready_remaining=#{pool.ready_count} warming=#{pool.warming_count}"
        )

        member
      end
    end

    # Release — give a claimed member back to its pool. F2-03: the default
    # is RECYCLE (pool_state="draining" + best-effort VM terminate, mirroring
    # the stale-ready recycle path) so replenish! backfills a freshly
    # provisioned member instead of re-serving an instance that still carries
    # the prior consumer's on-disk state, mounted credentials, and agent
    # working memory. Reuse-without-reset is per-pool opt-in via
    # metadata["reuse_without_reset"] — appropriate only when every consumer
    # of the pool is in the same trust domain.
    #
    # Returns "reused" (opt-in path: member back to ready, TTL anchor reset),
    # "recycled" (default path), "errored" when the recycle's terminate
    # failed, or "cordoned" (IMP-c9adb5a71dca — the opt-in path found the
    # member cordoned and fenced it to draining instead of re-admitting it).
    # Callers own the claimed-state guard. AgentFleetMissionService#reap_member!
    # passes the disposition straight through as a persisted mission action
    # label, so "cordoned" surfaces there too.
    #
    # IMP-68403ec0358d — this is also where the claim ledger is CLOSED. The
    # attribution has to be read back AFTER the release, which is exactly what
    # a member-row column cannot survive: both branches below null
    # pool_acquired_at, so anything stamped on the row at acquire time is gone
    # the moment the member is returned. #record_release! copies the
    # attribution onto the closing record so the release row answers "who used
    # this" on its own, and it fires on EVERY disposition — including
    # "errored", where the member rests with a VM that may still exist and
    # still bill, which is the single case attribution matters most for.
    def release!(instance:, pool:)
      claim = open_claim_event_for(instance)
      acquired_at = instance.pool_acquired_at

      disposition = perform_release!(instance: instance, pool: pool)

      # DELIBERATELY NOT one transaction with #perform_release!, unlike the
      # acquire side. The recycle branch of #perform_release! calls the
      # PROVIDER (terminate_member -> ProvisioningService.terminate_instance),
      # so a wrapping transaction would both hold a DB transaction open across
      # a network call and — on a ledger failure — roll back the DB half of a
      # termination that already happened at the provider, leaving the member
      # recorded as claimed while its VM is gone. Fail-closed is right at
      # acquire (nobody should hold an unattributed member); at release the
      # disposition is the irreversible half, so it commits and a ledger
      # failure raises LOUDLY afterwards rather than un-doing it.
      record_release!(pool: pool, instance: instance, claim: claim,
                      acquired_at: acquired_at, disposition: disposition)
      disposition
    end

    private def perform_release!(instance:, pool:)
      if pool&.metadata.is_a?(Hash) && pool.metadata["reuse_without_reset"]
        # A1' security (F5): reuse-without-reset returns the member to service
        # WITHOUT terminating, so finalize_termination!'s revoke never runs.
        # Revoke the prior consumer's dev-cell deploy key + Vault secret here so
        # a read-write repo key can't survive into the next acquirer. (No-op
        # unless this member ever bootstrapped a dev-cell key; a re-boot mints a
        # fresh key via rotate-on-bootstrap.)
        revoke_dev_cell_deploy_key!(instance)

        # IMP-71c852bffc37: same hazard as the deploy-key revoke above, one
        # control short. AgentPeeringService.announce! find_or_initializes the
        # peer keyed on node_instance_id, so a reused instance's re-announcement
        # lands on the SAME NodeInstancePeer row — any MCP tool-name glob
        # widening granted to the prior consumer (system_grant_instance_mcp_tools,
        # or an operator/agent action) would otherwise survive verbatim into the
        # next acquirer. Clear to [] rather than restoring some pool-defined
        # baseline: no such baseline concept exists today, and the next
        # enrollment (e.g. AgentFleetMissionService#enroll_member!) already
        # grants whatever that specific mission needs. Fail-closed: a cleared
        # grant means the reacquired instance can act on nothing until
        # re-granted (recoverable), never that it can act beyond what its new
        # acquirer expects (not recoverable).
        reset_granted_mcp_tools!(instance, pool: pool)

        # IMP-c9adb5a71dca — a CORDONED member is not re-admitted. The two
        # revokes above still ran on purpose: an uncordon later hands this
        # member to a new acquirer, and the prior consumer's key and grant
        # must not ride along. fence_admission! flips claimed → draining and
        # records "ready" as the state the uncordon restores. The flip is
        # conditional on "claimed"; losing it means the pool_state moved
        # under the releaser, which only the releaser writes — fail CLOSED
        # rather than fall through to the reuse write and re-admit a member
        # an operator cordoned.
        if instance.cordoned?
          return "cordoned" if ::System::InstanceCordonService.fence_admission!(instance, from: "claimed")

          raise InvalidPoolStateError,
                "instance #{instance.id} is cordoned and left pool_state=claimed " \
                "(now #{instance.pool_state.inspect}) during release; not re-admitting it"
        end

        # pool_warming_started_at doubles as the ready-TTL anchor in
        # recycle_stale_members! (F2-05) — without restarting it, a member
        # older than ready_ttl is stale-recycled on the next reaper tick
        # instead of being reused.
        instance.update!(pool_state: "ready", pool_acquired_at: nil,
                         pool_warming_started_at: Time.current)
        "reused"
      else
        instance.update!(pool_state: "draining", pool_acquired_at: nil)

        # IMP-28ca3e61f7c2 — route through #terminate_member rather than
        # calling the provider directly.
        #
        # This used to call ProvisioningService.terminate_instance inside a
        # `rescue StandardError` and DISCARD the return value. A provider
        # failure comes back as an err Result, not an exception, so the rescue
        # never fired and a failed terminate was indistinguishable from a
        # successful one — the same defect af978858 fixed at every other
        # terminate site by introducing #terminate_member. This site was
        # missed.
        #
        # The comment that used to sit here claimed "the reaper retries
        # cleanup". It does not, and that is what made the miss expensive:
        # InstancePool exposes ready_members / warming_members /
        # claimed_members / errored_members and NO draining scope, so every
        # branch of recycle_stale_members! skips a draining member.
        # prune_dead_records! cannot see it either — it selects status
        # terminated/error, which a still-running instance never reaches. A
        # member stranded here leaked permanently, VM included, taking its
        # dedicated Node shell and that Node's module assignments with it.
        #
        # On failure hand the member to the errored ladder, which is the one
        # path that DOES retry a terminate (bounded by
        # errored_terminate_max_attempts, with abandon_errored_member! as the
        # stop). That mirrors how the stale-warming branch already treats a
        # member whose VM may exist but whose terminate did not land.
        if terminate_member(instance, pool: pool, phase: "release-recycle")
          "recycled"
        else
          # Deliberately a direct update rather than #mark_pool_errored!, which
          # refuses a claimed-or-draining row. That guard exists so nothing
          # errors a member out from under an acquirer — but here we ARE the
          # releaser: the lease is finished and the row was taken out of
          # circulation two lines above, so there is no acquirer to protect.
          # Going through the guard would silently no-op and re-strand the
          # member, which is the bug this branch exists to fix.
          #
          # The draining-first ordering is preserved on purpose: the member
          # leaves circulation immediately, even if the provider call hangs.
          # Only the RESTING state on failure changes.
          instance.update!(pool_state: "errored")
          "errored"
        end
      end
    end

    # Replenish — provision new NodeInstances to bring ready+warming
    # count up to target_size. Idempotent: if pool is already at
    # capacity, no-op.
    #
    # The actual provisioning is dispatched as worker jobs (one per
    # deficit slot) so this method returns quickly. Each job creates a
    # NodeInstance with pool_state="warming" + pool_warming_started_at
    # set; standard enrollment proceeds. There is no after_save callback —
    # promotion to "ready" is heartbeat-driven (NodeInstance#promote_pool_ready!,
    # called from StatusController#heartbeat once the instance's on-node
    # agent enrolls and reports in).
    def replenish!(pool:)
      # IMP-cb2da06a384b — ACTIVE ONLY. This used to read `pool.paused?` and
      # nothing else, so a pool in ANY other non-active status was topped up
      # normally. "draining" is the status that made that expensive: drain!
      # terminates the ready members and deliberately leaves target_size
      # standing (so re-activating the pool warms it again), which left the
      # deficit exactly as it was — and InstancePoolReplenisherJob, which
      # lists active AND draining pools every 60 s, provisioned the whole pool
      # straight back. A terminate/re-provision cycle billing real VMs, on the
      # one path an operator uses to wind a pool down.
      #
      # Drain now means what every operator-facing description of it already
      # said: stop topping up, let the members recycle out. The recycle phase
      # is untouched and still runs for a draining pool — that is the
      # mechanism that empties it (stale-warming, ready-TTL and the errored
      # terminate ladder all live in recycle_stale_members!). "archived" rides
      # the same guard for the same reason; it is strictly more terminal.
      #
      # Same shape as acquire! (:144), which has refused a non-active pool
      # since F2-02. The pool's own status is quoted in the message because
      # the two refusals now mean different things to the caller: paused is
      # resumable, draining is a wind-down.
      raise PoolNotActiveError, "pool '#{pool.name}' is #{pool.status}" unless pool.active?

      # Audit plan P2.5 gap #6 — cap deficit by max_size so a transient
      # burst (e.g., concurrent autonomy ticks during a slow provision
      # window) can't push the pool past its ceiling.
      raw_deficit = pool.deficit
      total_now = pool.ready_count + pool.warming_count + pool.claimed_count
      headroom = pool.max_size.to_i.positive? ? [ pool.max_size.to_i - total_now, 0 ].max : raw_deficit
      deficit = [ raw_deficit, headroom ].min
      return { provisioned: 0, deficit: raw_deficit, capped_by_max_size: deficit < raw_deficit } if deficit.zero?

      ::ActiveRecord::Base.transaction do
        provisioned = []
        deficit.times do |i|
          instance = provision_warming_member!(pool: pool, slot_index: i)
          provisioned << instance
        end

        pool.update!(last_replenished_at: Time.current)

        Rails.logger.info(
          "[InstancePoolService] replenished pool '#{pool.name}' " \
          "deficit=#{deficit} provisioned=#{provisioned.size}"
        )

        { provisioned: provisioned.size, deficit: deficit, member_ids: provisioned.map(&:id) }
      end
    end

    # Drain — set pool to draining, terminate ready members. Claimed
    # members stay running until normal lifecycle terminate. Reaper
    # stops replenishing draining pools (the `unless pool.active?` guard in
    # replenish! above, IMP-cb2da06a384b) and keeps recycling them.
    #
    # target_size is deliberately NOT zeroed: draining is reversible via an
    # ungated `PATCH status: "active"`, which warms the pool back to the size
    # it already had. Nothing ACTS on target_size while the pool is draining
    # (#deficit still computes from it, and to_summary still reports that
    # deficit to the UI — it just never becomes a provision), so leaving it
    # standing costs nothing and preserves the operator's setting.
    def drain!(pool:)
      ::ActiveRecord::Base.transaction do
        pool.update!(status: "draining")

        terminated = []
        failed = []
        # F2-02 — re-select under row lock so drain never races acquire!:
        # SKIP LOCKED skips members a concurrent acquire transaction holds,
        # and the conditional UPDATE skips members claimed since the
        # snapshot — only rows still 'ready' are drained + terminated.
        pool.ready_members.lock("FOR UPDATE SKIP LOCKED").find_each do |member|
          still_ready = pool.node_instances
                            .where(id: member.id, pool_state: "ready")
                            .update_all(pool_state: "draining", updated_at: Time.current)
          next if still_ready.zero?

          # Audit plan P2.5 gap #2 — actually call the cloud-provider
          # terminate. Prior implementation only flipped pool_state.
          if terminate_member(member, pool: pool, phase: "drain")
            terminated << member.id
          else
            # The terminate did NOT happen. Leaving the row in 'draining'
            # made the failure invisible: drain reported success, nothing
            # retried, the VM kept running, and once the row went silent
            # the fleet decision engine's presumed-dead ladder flipped it
            # to status=error. Park it in 'errored' so it is distinguishable
            # from a clean drain. Set directly rather than via
            # mark_pool_errored!, which refuses a 'draining' row — that
            # guard protects members mid-drain from the reaper, and here we
            # ARE the drain.
            pool.node_instances
                .where(id: member.id)
                .update_all(pool_state: "errored", updated_at: Time.current)
            failed << member.id
          end
        end

        if failed.any?
          ::System::Fleet::EventBroadcaster.emit!(
            account: pool.account,
            kind: "system.pool.terminate_failed",
            severity: :high,
            payload: {
              pool_id: pool.id,
              pool_name: pool.name,
              phase: "drain",
              failed_instance_ids: failed
            },
            source: "instance_pool_service"
          )
        end

        Rails.logger.info(
          "[InstancePoolService] drained pool '#{pool.name}' " \
          "ready_terminated=#{terminated.size} terminate_failed=#{failed.size} " \
          "claimed_remaining=#{pool.claimed_count}"
        )

        { drained: terminated.size, terminate_failed: failed.size, claimed_remaining: pool.claimed_count }
      end
    end

    # Recycle stale members — called by the reaper between replenishes.
    #   - warming members past warming_timeout → errored (provisioning got stuck)
    #   - ready members past ready_ttl → draining (stale, recycle for fresh state)
    #   - ready members whose on-node agent heartbeat has gone stale → same
    #     draining/recycle treatment as ready_ttl, even if the TTL window
    #     hasn't elapsed yet (ready members hold no workload, so recycling
    #     one early is safe)
    #   - claimed members past claimed_ttl → flagged + FleetEvent (F1-10;
    #     never auto-terminated — a long claim may be a live workload, so
    #     reclamation is an operator decision)
    #   - claimed members whose on-node agent heartbeat has gone stale →
    #     same flag-only treatment as claimed_ttl (NOT auto-terminate — see
    #     the flag-only rationale below). Demoted from an earlier
    #     auto-terminate design: a claimed member is in-use, and a
    #     fleet-wide heartbeat gap (backend reload/migration, SDWAN
    #     reconvergence) can blow past a 3-minute monitoring threshold
    #     while every claimed cell is perfectly healthy. Auto-terminating
    #     on that signal would kill live work on a false positive. Mirrors
    #     the platform's presumed-dead ladder (fleet/decision_engine.rb),
    #     which uses a much longer window (30min) + status==running and
    #     still never auto-terminates.
    #   - errored members → terminated (cleanup), with a BOUNDED,
    #     backed-off provider terminate. A member lands in "errored" when
    #     the warming-timeout path gives up on it or when drain!'s provider
    #     terminate failed — in the latter case its VM is very likely still
    #     running, so "never retried, never torn down" leaks a cloud
    #     instance forever. Retries are capped + exponentially spaced (see
    #     DEFAULT_ERRORED_TERMINATE_* above) because this calls a cloud
    #     provider every 60s tick; once the cap is spent the member is
    #     abandoned LOUDLY (error log + high-severity FleetEvent) and never
    #     retried again.
    def recycle_stale_members!(pool:)
      # Seed-reload phase runs FIRST and OUTSIDE the FOR UPDATE transaction
      # below — power-cycling a PVE VM is a slow external API call (multiple
      # seconds per stop+start), and holding a row lock across it would
      # serialize unrelated pool operations (acquire!, the recycle phases
      # further down) behind every cycle. See reload_pending_seeds! for the
      # eligibility rules + why this exists (deferred cloud-init seed reload,
      # replacing an ineffective immediate in-create power cycle).
      seed_reload_count = reload_pending_seeds!(pool: pool)

      now = Time.current
      warming_timeout = pool.metadata["warming_timeout_seconds"]&.to_i ||
                        DEFAULT_WARMING_TIMEOUT_SECONDS
      ready_ttl = pool.metadata["ready_ttl_seconds"]&.to_i ||
                  DEFAULT_READY_TTL_SECONDS
      claimed_ttl = pool.metadata["claimed_ttl_seconds"]&.to_i ||
                    DEFAULT_CLAIMED_TTL_SECONDS
      errored_max_attempts = positive_pool_setting(
        pool, "errored_terminate_max_attempts", DEFAULT_ERRORED_TERMINATE_MAX_ATTEMPTS
      )
      errored_backoff_seconds = positive_pool_setting(
        pool, "errored_terminate_backoff_seconds", DEFAULT_ERRORED_TERMINATE_BACKOFF_SECONDS
      )
      errored_backoff_cap_seconds = positive_pool_setting(
        pool, "errored_terminate_backoff_cap_seconds", DEFAULT_ERRORED_TERMINATE_BACKOFF_CAP_SECONDS
      )

      # Heartbeat-driven staleness — additive to the TTL windows above. A
      # ready/claimed member whose on-node agent has stopped heartbeating is
      # broken regardless of how long it's sat in that pool_state; waiting
      # out the full ready/claimed TTL leaves a dead member sitting in the
      # pool (ready, acquirable by the next consumer) or silently unusable
      # under a consumer (claimed) in the meantime. Reuses NodeInstance's
      # existing liveness definition (HEARTBEAT_STALE_AFTER) instead of
      # inventing a second one. `last_heartbeat_at IS NOT NULL` deliberately
      # excludes members that have never heartbeated yet (e.g. one that just
      # flipped to ready a moment before its first heartbeat lands) — those
      # stay governed by the existing warming/ready TTL paths instead.
      #
      # Coercion — both metadata overrides can arrive as JSON-serialized
      # strings (not just native bool/int) depending on how the caller
      # wrote them, so treat both "false" (string) and false (bool) as
      # opt-out, and never call numeric coercion on the boolean flag (a
      # bare `false.to_i` raises NoMethodError, killing every recycle
      # phase in this transaction — `&.to_i` does NOT save you here since
      # safe-nav only short-circuits on nil, not false).
      heartbeat_reap_enabled = ![ false, "false" ].include?(pool.metadata["reap_on_stale_heartbeat"])
      # A garbage or non-positive override ("abc" → 0, literal 0, or
      # negative) must fall back to the default rather than being taken
      # literally — a 0-or-negative threshold makes `last_heartbeat_at <
      # now - threshold` true for virtually every member, i.e. "everything
      # is stale".
      raw_heartbeat_stale_after_seconds = pool.metadata["heartbeat_stale_after_seconds"].to_i
      heartbeat_stale_after_seconds = raw_heartbeat_stale_after_seconds.positive? ?
                                      raw_heartbeat_stale_after_seconds :
                                      ::System::NodeInstance::HEARTBEAT_STALE_AFTER.to_i

      stale_warming = pool.warming_members
                          .where("pool_warming_started_at < ?", now - warming_timeout)
      stale_ready = pool.ready_members
                        .where("pool_warming_started_at < ?", now - ready_ttl)
      stale_ready = stale_ready.or(
        pool.ready_members.where(
          "last_heartbeat_at IS NOT NULL AND last_heartbeat_at < ?",
          now - heartbeat_stale_after_seconds
        )
      ) if heartbeat_reap_enabled
      stale_claimed = pool.claimed_members
                          .where("pool_acquired_at < ?", now - claimed_ttl)
      heartbeat_stale_claimed = if heartbeat_reap_enabled
        pool.claimed_members.where(
          "last_heartbeat_at IS NOT NULL AND last_heartbeat_at < ?",
          now - heartbeat_stale_after_seconds
        )
      else
        pool.node_instances.none
      end

      # Errored-member cleanup candidates, snapshotted as IDs BEFORE the
      # transaction below runs its warming phase. Two reasons this is a
      # snapshot and not a lazy relation:
      #
      #   1. The warming-timeout phase marks members "errored" in this same
      #      transaction AND already makes their first terminate attempt. A
      #      lazy `pool.errored_members` would pick those up moments later
      #      and terminate them a second time in the same tick; the snapshot
      #      defers them to the next tick instead.
      #   2. Members already abandoned (pool_terminate_gave_up_at stamped)
      #      are excluded outright — their bound is spent and the operator
      #      has been notified, so nothing here calls the provider for them
      #      again. That exclusion is what makes "stop retrying" durable
      #      across reaper ticks.
      errored_member_ids = pool.errored_members
                               .where("config->>'pool_terminate_gave_up_at' IS NULL")
                               .pluck(:id)

      counts = {
        warming_to_errored: 0,
        ready_to_draining: 0,
        claimed_flagged: 0,
        claimed_heartbeat_flagged: 0,
        errored_terminated: 0,
        errored_abandoned: 0,
        terminate_failed: 0,
        records_pruned: 0,
        node_shells_pruned: 0,
        seed_reloads: seed_reload_count
      }

      ::ActiveRecord::Base.transaction do
        # F2-02 — same locking discipline as drain!: SKIP LOCKED skips
        # members a concurrent acquire holds, and the conditional UPDATE
        # skips members claimed since the snapshot. The reaper runs this
        # every 60s, so an unguarded update here terminated instances out
        # from under agents that had just acquired them.
        stale_warming.lock("FOR UPDATE SKIP LOCKED").find_each do |m|
          next unless m.mark_pool_errored!

          counts[:warming_to_errored] += 1

          # Mirrors the stale_ready fix below (Audit plan P2.5 gap #3) — a
          # member stuck in warming past warming_timeout may already have a
          # real cloud VM (creation succeeded but the guest never came up /
          # never heartbeated). Marking it errored without tearing down the
          # VM leaked it on the provider forever; this was the dominant
          # cause of the ci-builder VM sprawl on dna (2026-07-21).
          counts[:terminate_failed] += 1 unless terminate_member(m, pool: pool, phase: "stale-warming")
        end
        stale_ready.lock("FOR UPDATE SKIP LOCKED").find_each do |m|
          still_ready = pool.node_instances
                            .where(id: m.id, pool_state: "ready")
                            .update_all(pool_state: "draining", updated_at: Time.current)
          next if still_ready.zero?

          # Audit plan P2.5 gap #3 — TTL-aware reaping must actually
          # terminate the cloud VM. Prior implementation only flipped
          # pool_state; the underlying VM ran past ready_ttl indefinitely.
          counts[:terminate_failed] += 1 unless terminate_member(m, pool: pool, phase: "stale-ready")
          counts[:ready_to_draining] += 1

          # Observability parity with the claimed-flag event below — a
          # ready member holds no workload, so recycling it is safe and
          # stays silent-by-default (folded into ready_to_draining), but
          # when the TRIGGER is a dead heartbeat specifically (as opposed
          # to plain ready_ttl expiry) it's worth its own signal: a mass
          # heartbeat-driven ready-recycle right after an outage would
          # otherwise be invisible outside the aggregate log line.
          if heartbeat_reap_enabled && m.last_heartbeat_at.present? &&
             m.last_heartbeat_at < now - heartbeat_stale_after_seconds
            ::System::Fleet::EventBroadcaster.emit!(
              account: pool.account,
              kind: "system.pool.ready_stale_heartbeat_recycled",
              severity: :medium,
              payload: {
                pool_id: pool.id,
                pool_name: pool.name,
                heartbeat_stale_after_seconds: heartbeat_stale_after_seconds,
                last_heartbeat_at: m.last_heartbeat_at&.iso8601
              },
              source: "instance_pool_service",
              node_instance_id: m.id
            )
          end
        end

        # F1-10 — flag, never terminate: the claim may still back a live
        # workload. The config flag + FleetEvent surface the leak to the
        # operator; without them a consumer crash after acquire! leaked
        # the member forever while replenish! counted it against
        # max_size headroom. The flag is per-claim-cycle: a flag stamped
        # before the current pool_acquired_at belongs to an earlier
        # claim and is re-raised.
        stale_claimed.lock("FOR UPDATE SKIP LOCKED").find_each do |m|
          next unless flag_claimed_stale!(member: m, now: now)

          ::System::Fleet::EventBroadcaster.emit!(
            account: pool.account,
            kind: "system.pool.claimed_stale",
            severity: :medium,
            payload: {
              pool_id: pool.id,
              pool_name: pool.name,
              claimed_ttl_seconds: claimed_ttl,
              pool_acquired_at: m.pool_acquired_at&.iso8601
            },
            source: "instance_pool_service",
            node_instance_id: m.id
          )
          counts[:claimed_flagged] += 1
        end

        # Heartbeat-driven claimed flag — demoted from an earlier
        # auto-terminate design (see the class-level comment above this
        # method for the incident that prompted the demotion). A claimed
        # member whose heartbeat has gone stale gets EXACTLY the same
        # flag-only treatment as the claimed_ttl path above, including
        # its per-claim-cycle guard (a member already flagged this cycle
        # by either trigger isn't double-flagged/double-notified) — the
        # only difference is the FleetEvent kind, so operators can tell a
        # TTL-triggered flag from a heartbeat-triggered one.
        heartbeat_stale_claimed.lock("FOR UPDATE SKIP LOCKED").find_each do |m|
          next unless flag_claimed_stale!(member: m, now: now)

          ::System::Fleet::EventBroadcaster.emit!(
            account: pool.account,
            kind: "system.pool.claimed_stale_heartbeat_flagged",
            severity: :medium,
            payload: {
              pool_id: pool.id,
              pool_name: pool.name,
              heartbeat_stale_after_seconds: heartbeat_stale_after_seconds,
              last_heartbeat_at: m.last_heartbeat_at&.iso8601
            },
            source: "instance_pool_service",
            node_instance_id: m.id
          )
          counts[:claimed_heartbeat_flagged] += 1
        end

        # errored → terminated (cleanup). The phase this method's header has
        # documented since slice 7 but which was never implemented — which is
        # why System::NodeInstance.pool_errored had zero callers and an
        # errored member was neither retried nor torn down.
        #
        # Same locking discipline as drain!/stale_ready: FOR UPDATE SKIP
        # LOCKED plus a conditional UPDATE guarded on the member still being
        # "errored", so a member whose state changed since the snapshot is
        # never clobbered (and never charged an attempt).
        pool.node_instances
            .where(id: errored_member_ids, pool_state: "errored")
            .lock("FOR UPDATE SKIP LOCKED").find_each do |m|
          # Nothing to reclaim on the provider: the member never got a cloud
          # VM (provision died before the provider call, or it isn't a cloud
          # member), or its row already reached the terminal `terminated`
          # status so the VM is gone. terminate_instance would answer
          # err("Instance has no cloud instance ID") / re-delete a destroyed
          # VM, burning the whole retry bound and ending in a high-severity
          # "the VM may still be running" alert that is simply false. Take it
          # out of the errored set directly — 'draining' is the same
          # out-of-circulation state a successful drain leaves behind, and
          # record retention takes the row from there.
          if m.cloud_instance_id.blank? || m.status == "terminated"
            cleaned = pool.node_instances
                          .where(id: m.id, pool_state: "errored")
                          .update_all(pool_state: "draining", updated_at: now)
            next if cleaned.zero?

            Rails.logger.info(
              "[InstancePoolService] errored member has no provider resource to reclaim " \
              "(instance=#{m.id} pool='#{pool.name}' status=#{m.status}) — marking cleaned up"
            )
            counts[:errored_terminated] += 1
            next
          end

          attempts = m.config.to_h["pool_terminate_attempts"].to_i

          # Bound already spent without an abandonment stamp — reachable when
          # an operator LOWERS errored_terminate_max_attempts after the fact.
          # Give up loudly rather than silently retrying past the new cap.
          if attempts >= errored_max_attempts
            counts[:errored_abandoned] += 1 if abandon_errored_member!(
              member: m, pool: pool, now: now,
              attempts: attempts, max_attempts: errored_max_attempts
            )
            next
          end

          next unless errored_terminate_backoff_elapsed?(
            member: m, now: now, attempts: attempts,
            base: errored_backoff_seconds, cap: errored_backoff_cap_seconds
          )

          # Conditional UPDATE under the row lock: re-checks pool_state AND
          # records the attempt in the same statement, so the bound is
          # durable the moment we commit to calling the provider — the
          # reaper re-reads it 60s later, where an in-memory counter would
          # be long gone.
          claimed = pool.node_instances
                        .where(id: m.id, pool_state: "errored")
                        .update_all([
                          "config = config || ?::jsonb, updated_at = ?",
                          { "pool_terminate_attempts" => attempts + 1,
                            "pool_terminate_last_attempt_at" => now.iso8601 }.to_json,
                          now
                        ])
          next if claimed.zero?

          # Reuses terminate_member so the Runtime::Result is inspected
          # correctly (terminate_instance returns an err Result on provider
          # failure and only RAISES ArgumentError — ignoring its return value
          # is the original defect this whole cleanup exists to unwind).
          if terminate_member(m, pool: pool, phase: "errored-cleanup")
            pool.node_instances
                .where(id: m.id, pool_state: "errored")
                .update_all(pool_state: "draining", updated_at: now)
            counts[:errored_terminated] += 1
          else
            counts[:terminate_failed] += 1
            # Stays "errored" so the next tick can retry it — unless that was
            # the last attempt the bound allows, in which case stop here.
            if attempts + 1 >= errored_max_attempts
              counts[:errored_abandoned] += 1 if abandon_errored_member!(
                member: m, pool: pool, now: now,
                attempts: attempts + 1, max_attempts: errored_max_attempts
              )
            end
          end
        end
      end

      # Runs outside the FOR UPDATE transaction above: pruning touches only
      # rows that are already dead (terminated/error) and long past the
      # retention window, so it never contends with acquire!/drain!, and
      # holding the pool's row locks across a cascading destroy would
      # serialise the 60s tick behind it.
      counts[:records_pruned] = prune_dead_records!(pool: pool, now: now)
      counts[:node_shells_pruned] = prune_orphaned_node_shells!(pool: pool, now: now)

      counts.values.sum.positive? &&
        Rails.logger.info("[InstancePoolService] recycled stale members in '#{pool.name}': #{counts}")

      counts
    end

    # Reaper-driven deferred cloud-init seed reload for Proxmox uefi_disk
    # builders (see System::Providers::ProxmoxProvider#reload_cloudinit_seed!
    # and #power_cycle_instance for the provider side).
    #
    # Background: PVE only materializes the cloud-init NoCloud (CIDATA) seed
    # drive some unknown number of minutes AFTER a uefi_disk VM's first boot
    # — never on the first boot itself, and never on a graceful reboot. A
    # prior fix tried firing the power cycle once, synchronously, right after
    # create — the PVE task log proved that lands ~8s into boot, mid-UEFI,
    # long before the seed exists, so it was a no-op (two builders only
    # enrolled after a manual cycle done minutes later). Because the real
    # materialization delay is unknown, the fix has to retry until it works,
    # not fire once — this method is that retry loop, called once per
    # recycle_stale_members! tick.
    #
    # Runs NON-transactionally and is called BEFORE recycle_stale_members!'s
    # ActiveRecord::Base.transaction block (see the call site) — power-
    # cycling a VM is a slow external PVE call, and holding a FOR UPDATE row
    # lock across it would serialize unrelated pool operations behind it.
    #
    # Eligibility — a warming member that:
    #   - has never enrolled (last_heartbeat_at IS NULL). Once a member
    #     heartbeats it drops out of this query immediately, whether or not
    #     it was ever cycled — an enrolled member's seed already worked.
    #   - has a cloud VM already created (config->>'cloud_instance_id'
    #     present) — nothing to power-cycle otherwise.
    #   - has been warming at least SEED_RELOAD_AFTER seconds — gives the
    #     first boot time to reach the point PVE would materialize the seed
    #     before we cycle it (cycling too early just repeats the original
    #     bug's mid-boot timing).
    #   - was never cycled, or wasn't cycled within the last
    #     SEED_RELOAD_INTERVAL seconds — throttles re-cycling so a member
    #     mid-cycle from the previous tick isn't cycled again 60s later.
    #   - hasn't hit SEED_RELOAD_MAX attempts yet — past the cap we stop
    #     cycling and let the normal warming_timeout recycle path (above)
    #     eventually error the member out instead of power-cycling forever.
    #
    # An idle warming VM does no useful work, so re-cycling it is safe.
    #
    # Returns the count of members power-cycled this tick.
    def reload_pending_seeds!(pool:)
      seed_reload_after = (::SiteSetting.get("system.ci_builder.seed_reload_after_seconds").presence || 120).to_i
      seed_reload_interval = (::SiteSetting.get("system.ci_builder.seed_reload_interval_seconds").presence || 240).to_i
      seed_reload_max = (::SiteSetting.get("system.ci_builder.seed_reload_max_attempts").presence || 6).to_i

      now = Time.current
      candidates = pool.warming_members
                       .where(last_heartbeat_at: nil)
                       .where("config->>'cloud_instance_id' IS NOT NULL")
                       .where("pool_warming_started_at < ?", now - seed_reload_after)

      cycled = 0
      candidates.find_each do |member|
        attempts = member.config["seed_reload_count"].to_i
        next if attempts >= seed_reload_max

        last_reload_at = begin
          raw = member.config["last_seed_reload_at"]
          raw.present? ? Time.zone.parse(raw) : nil
        rescue ArgumentError
          nil
        end
        next if last_reload_at && last_reload_at > now - seed_reload_interval

        provider = resolve_seed_reload_provider(member)
        next unless provider&.respond_to?(:power_cycle_instance)

        begin
          provider.power_cycle_instance(member.config["cloud_instance_id"])
        rescue StandardError => e
          Rails.logger.warn(
            "[InstancePoolService] reload_pending_seeds!: power_cycle_instance failed " \
            "(instance=#{member.id} pool='#{pool.name}'): #{e.class}: #{e.message}"
          )
          next
        end

        # Two keys only — see System::ConfigDocument. `member` came out of the
        # query at the top of this loop and has since survived a provider
        # power-cycle round trip, so its document is stale by construction.
        member.merge_config!(
          "last_seed_reload_at" => now.iso8601,
          "seed_reload_count" => attempts + 1
        )
        cycled += 1
      end

      Rails.logger.info("[InstancePoolService] reload_pending_seeds!: cycled=#{cycled} in '#{pool.name}'") if cycled.positive?

      cycled
    end

    private

    # === Claim ledger (IMP-68403ec0358d) ===
    #
    # WHY A LEDGER AND NOT COLUMNS. The offer that asked for this recommended
    # generalising System::CiRunnerLease, and its reason is the deciding one:
    # the motive is COST AND AUDIT attribution, and #release! CLEARS the
    # member's claim columns on every disposition (`pool_acquired_at: nil` on
    # both branches). Attribution that vanishes when the thing is returned
    # cannot answer "who used this last month", which is the only question
    # worth asking. So the record has to outlive the claim.
    #
    # WHY FleetEvent AND NOT A NEW TABLE. CiRunnerLease is a table because a
    # LEASE carries mutable lifecycle state — an AASM column, expires_at,
    # runner correlation — that has to be queried as CURRENT state and
    # transitioned. An attribution record has no state: it is an append-only
    # fact about a moment. system_fleet_events is already the platform's
    # account-scoped, instance-referencing, correlation-keyed record of exactly
    # such facts, and it already has a read path on both doors — MCP
    # (`system_recent_signals`) and REST
    # (Api::V1::System::FleetController#signals), both filtering by `kind` and
    # by `correlation_id`. NOT the ActionCable feed, for these two kinds: see
    # the last paragraph. Building a second ledger beside it would have bought
    # an index and cost a schema migration, a model, a controller, a
    # serializer and a read verb.
    #
    # THE HORIZON THIS BUYS, STATED PLAINLY. FleetEvents ARE pruned: the
    # nightly sweep at Api::V1::System::WorkerApi::FleetController#retention_sweep
    # deletes low/medium rows past POWERNODE_FLEET_EVENT_RETENTION_DAYS
    # (default 90) and high/critical rows past the critical window (default
    # 365). These two are `low`, so the ledger answers "who used this last
    # month" — the question the offer was filed to answer — and roughly the
    # last quarter, but it is NOT a permanent cost archive. Raising the
    # severity to buy the longer window is the wrong lever: on both terminate
    # kinds (`terminate_failed`, `terminate_abandoned`) `high` already means "a
    # VM may still be billing", and every `high` row feeds
    # FleetEvent.high_or_critical, so borrowing it would page on a routine
    # claim. A retention horizon longer than the sweep's is the case for a
    # dedicated table, and it is the only thing that case rests on.
    #
    # WHY NOT EventBroadcaster.emit!. That seam is explicitly best-effort — it
    # rescues StandardError and returns nil — so a failed insert would leave
    # the caller believing the attribution was recorded when it was discarded,
    # which is the exact failure mode this capability exists to end (the MCP
    # door used to accept `acquired_by` and drop it silently). These two writes
    # go straight to the model so a failure is loud. The claim write sits
    # INSIDE acquire!'s transaction: if the ledger cannot record who is taking
    # the member, the claim rolls back and nobody gets an unattributed member.
    # The price, paid knowingly: these two kinds do NOT reach SystemFleetChannel,
    # because the ActionCable push lives inside that seam. They are a queryable
    # record, not a live feed — and a record that can be silently lost is not a
    # record at all.
    def record_claim!(pool:, member:, acquired_at:, acquired_by:, acquired_for:)
      @last_claim_id = ::UUID7.generate

      ::System::FleetEvent.create!(
        account: @account,
        kind: CLAIM_EVENT_KIND,
        severity: "low",
        source: "instance_pool_service",
        correlation_id: @last_claim_id,
        node_id: member.node_id,
        node_instance_id: member.id,
        payload: {
          "claim_id" => @last_claim_id,
          "pool_id" => pool.id,
          "pool_name" => pool.name,
          "node_instance_id" => member.id,
          "instance_name" => member.name,
          "acquired_by" => acquired_by.presence,
          "acquired_for" => acquired_for.presence,
          "acquired_at" => acquired_at&.utc&.iso8601
        }
      )
    end

    # The open claim for a member is its MOST RECENT claim event: a member is
    # claimed by at most one consumer at a time, and every release closes the
    # last claim, so a reused member's second claim is the one a second release
    # is closing. Nil for a member claimed before this ledger shipped — the
    # release is still recorded (see #record_release!), because the disposition
    # is the half of the record that cannot be reconstructed afterwards.
    # Scoped by @account, the SAME source #record_claim! and #record_release!
    # write with. Reading by instance.account_id instead would silently miss
    # every claim whenever a member's own account differs from the pool's —
    # a lookup that cannot find rows it wrote is worse than no lookup.
    def open_claim_event_for(instance)
      ::System::FleetEvent
        .where(account: @account, kind: CLAIM_EVENT_KIND, node_instance_id: instance.id)
        # emitted_at defaults to now(), which inside a transaction is the
        # TRANSACTION's start time — two rows written in one transaction can
        # tie. id is uuidv7 and therefore time-ordered, so it breaks the tie
        # deterministically rather than leaving the pick to the planner.
        .order(emitted_at: :desc, id: :desc)
        .first
    end

    # Copies the attribution FORWARD onto the closing record rather than only
    # correlating to the claim event. That is what makes the release row answer
    # "who used this" on its own: an auditor summing held_seconds by
    # acquired_by over last month reads one kind, with no self-join.
    def record_release!(pool:, instance:, claim:, acquired_at:, disposition:)
      released_at = Time.current
      claim_payload = claim&.payload.is_a?(Hash) ? claim.payload : {}
      started_at = acquired_at || claim_payload["acquired_at"]&.then { |t| Time.zone.parse(t.to_s) }

      ::System::FleetEvent.create!(
        # @account, not pool&.account || instance.account: the release row has
        # to land where #record_claim! wrote the claim and where
        # #open_claim_event_for reads it, or the pair stops correlating.
        account: @account,
        kind: RELEASE_EVENT_KIND,
        severity: "low",
        source: "instance_pool_service",
        correlation_id: claim&.correlation_id,
        node_id: instance.node_id,
        node_instance_id: instance.id,
        payload: {
          "claim_id" => claim&.correlation_id,
          "pool_id" => pool&.id,
          "pool_name" => pool&.name,
          "node_instance_id" => instance.id,
          "instance_name" => instance.name,
          "disposition" => disposition,
          "acquired_by" => claim_payload["acquired_by"],
          "acquired_for" => claim_payload["acquired_for"],
          "acquired_at" => started_at&.utc&.iso8601,
          "released_at" => released_at.utc.iso8601,
          "held_seconds" => started_at ? (released_at - started_at).round : nil
        }
      )
    end

    # Terminate one pool member, returning whether it actually happened.
    #
    # ProvisioningService.terminate_instance RETURNS a Runtime::Result and only
    # re-raises ArgumentError — a provider failure comes back as an err Result,
    # NOT an exception. Every caller here used to wrap the call in `rescue
    # StandardError` and discard the return value, so a failed terminate was
    # indistinguishable from a successful one: drain reported success, the VM
    # kept running on the provider, and the row sat in a non-terminal state
    # until the fleet decision engine's presumed-dead ladder flipped it to
    # status=error (reap_presumed_dead!). That is how ops-hub accumulated 20
    # ci-builder rows in pool_state=draining + status=error by 2026-08-02.
    #
    # Tolerates a non-Result return so existing callers and test stubs that
    # hand back a bare truthy value keep meaning "succeeded" — only an explicit
    # failure Result counts as a failure.
    def terminate_member(member, pool:, phase:)
      result = ::System::ProvisioningService.terminate_instance(instance: member)
      return true unless result.respond_to?(:failure?) && result.failure?

      Rails.logger.error(
        "[InstancePoolService] terminate FAILED during #{phase} " \
        "(instance=#{member.id} pool='#{pool.name}'): #{result.error}"
      )
      false
    rescue StandardError => e
      Rails.logger.error(
        "[InstancePoolService] terminate RAISED during #{phase} " \
        "(instance=#{member.id} pool='#{pool.name}'): #{e.class}: #{e.message}"
      )
      false
    end

    # Per-pool integer setting with the same coercion discipline the
    # heartbeat_stale_after_seconds override learned the hard way: a missing,
    # non-numeric ("abc" → 0), or non-positive value falls back to the
    # built-in default instead of being taken literally. `.to_i` is NOT safe
    # to call blindly — a boolean in metadata raises NoMethodError, which
    # would kill every phase in the reaper's transaction.
    def positive_pool_setting(pool, key, default)
      raw = pool.metadata.to_h[key]
      value = raw.respond_to?(:to_i) ? raw.to_i : 0
      value.positive? ? value : default
    end

    # Exponential-backoff gate for the errored-member terminate retry.
    # Never attempted (attempts == 0) → always eligible. Otherwise the next
    # attempt waits base * 2^(attempts - 1), capped, measured from the last
    # recorded attempt. A missing or unparseable timestamp means we have no
    # evidence of a recent attempt, so we proceed — the attempt COUNT bounds
    # the provider calls independently of the clock.
    def errored_terminate_backoff_elapsed?(member:, now:, attempts:, base:, cap:)
      return true if attempts <= 0

      last_attempt_at = begin
        raw = member.config.to_h["pool_terminate_last_attempt_at"]
        raw.present? ? Time.zone.parse(raw) : nil
      rescue ArgumentError
        nil
      end
      return true if last_attempt_at.nil?

      last_attempt_at <= now - [ base * (2**(attempts - 1)), cap ].min
    end

    # Terminal give-up for an errored member whose bounded terminate retries
    # are spent. Stamps pool_terminate_gave_up_at — which drops the member
    # out of the cleanup snapshot for good, so this is also what makes the
    # alert fire exactly once — then logs at error and emits a high-severity
    # FleetEvent. Abandoning cleanup can mean a provider VM is still running
    # (and billing), so it is never silent. Guarded on the member still being
    # "errored" (the same conditional-UPDATE discipline as the phase itself);
    # returns false when it isn't, so the caller neither counts nor alerts.
    def abandon_errored_member!(member:, pool:, now:, attempts:, max_attempts:)
      stamped = pool.node_instances
                    .where(id: member.id, pool_state: "errored")
                    .update_all([
                      "config = config || ?::jsonb, updated_at = ?",
                      { "pool_terminate_gave_up_at" => now.iso8601 }.to_json,
                      now
                    ])
      return false if stamped.zero?

      Rails.logger.error(
        "[InstancePoolService] GIVING UP on errored pool member after #{attempts} failed " \
        "terminate attempts (limit=#{max_attempts} instance=#{member.id} pool='#{pool.name}' " \
        "cloud_instance_id=#{member.cloud_instance_id.inspect}) — the provider resource may " \
        "still exist; operator cleanup required"
      )

      ::System::Fleet::EventBroadcaster.emit!(
        account: pool.account,
        kind: "system.pool.terminate_abandoned",
        severity: :high,
        payload: {
          pool_id: pool.id,
          pool_name: pool.name,
          phase: "errored-cleanup",
          instance_id: member.id,
          cloud_instance_id: member.cloud_instance_id,
          attempts: attempts,
          max_attempts: max_attempts
        },
        source: "instance_pool_service",
        node_instance_id: member.id
      )
      true
    end

    # Retention sweep for dead pool members' DB records.
    #
    # Pool members are ephemeral by definition — a CI builder lives minutes —
    # but nothing ever pruned their rows, so Node + NodeInstance records
    # accumulated without bound (94 ci-native-builder nodes in 15 days on
    # ops-hub, 2026-08-02). NodeMaintenanceService#task_resource_cleanup is not
    # a substitute: it is never scheduled, runs per-node, defaults to a 30-day
    # window (longer than a member's entire lifecycle), only handles
    # "terminated", and leaves the Node row behind.
    #
    # Deliberately conservative: scoped to this pool's own members via
    # instance_pool_id, only rows already in a terminal status, and only past
    # the retention window. `destroy` (not delete_all) so dependent tasks and
    # certificates go with them — several FKs onto these tables are NO ACTION,
    # and a raw delete would either violate them or orphan rows.
    def prune_dead_records!(pool:, now:)
      retention_days = record_retention_days(pool)
      return 0 if retention_days <= 0

      dead = pool.node_instances
                 .where(status: %w[terminated error])
                 .where("updated_at < ?", now - retention_days.days)

      pruned = 0
      dead.find_each do |member|
        node = member.node

        # A member whose terminate failed still carries cloud_instance_id, and
        # that row is the ONLY pointer we hold to a VM that may still be
        # running and billing. Nothing here can reconcile against the provider,
        # so name the id in the journal before the row goes: the pointer then
        # survives an operator audit even though the record does not.
        Rails.logger.info(
          "[InstancePoolService] pruning dead pool record " \
          "(instance=#{member.id} pool='#{pool.name}' status=#{member.status} " \
          "cloud_instance_id=#{member.cloud_instance_id.inspect}) — if the " \
          "provider resource was never destroyed this id is the last record of it"
        )

        # Without this the destroy below was INERT: an enrolled member has a
        # System::NodeInstancePeer (every builder announces one), and
        # system_node_instance_peers.node_instance_id is a NO ACTION FK that
        # NodeInstance declares no `dependent:` for — so destroy! raised
        # InvalidForeignKey, the rescue logged "record prune failed", and the
        # same doomed destroy was retried every 60s forever. See
        # NodeInstance::CASCADE_DEPENDENTS, which classifies each blocker as
        # nullify (optional FK, audit history kept) vs destroy (required FK).
        # That list is NOT known to be exhaustive — it is narrower than
        # SystemFleetTool::DESTROY_INSTANCE_FKS, and NO ACTION FKs exist that
        # neither list covers — so a member holding one of those still fails
        # here and still gets logged below. Reconciling the two lists is its
        # own change; this one unsticks the blocker CI builders actually carry.
        #
        # This is destructive beyond the member row: the required-FK arm takes
        # storage migrations/assignments/credentials and SDWAN peers with it,
        # and the member's own `dependent: :destroy` tasks go too — for a CI
        # builder that is its ci.module_build task history, unrecoverable. That
        # is the accepted price of collecting a record already past its
        # retention window; the selection above is what keeps it bounded.
        #
        # Both statements share ONE transaction, as
        # cascade_destroy_dependents!'s own doc requires: it commits
        # internally, so an un-wrapped destroy! failure would leave the
        # member's peers and storage rows permanently destroyed while the
        # member itself survived — and the rescue below would log a bare
        # "record prune failed" that discloses none of it, every 60s forever.
        cascade_summary = nil
        ::ActiveRecord::Base.transaction do
          cascade_summary = member.cascade_destroy_dependents!
          member.destroy!
        end
        pruned += 1

        # The cascade's return value is the only record of WHICH dependent
        # rows went with the member (and which provider volumes were merely
        # detached, since those outlive the row and keep billing).
        if cascade_summary && (cascade_summary[:nullified].any? || cascade_summary[:destroyed].any?)
          Rails.logger.info(
            "[InstancePoolService] pruned member cascade (instance=#{member.id} " \
            "pool='#{pool.name}'): #{cascade_summary}"
          )
        end

        # The pool provisions a dedicated Node per member, so once its last
        # instance is gone the Node is an empty shell. Guarded on there being
        # no surviving instances so a shared or pre-provisioned Node is never
        # taken out from under a live one.
        destroy_pool_node_shell!(node) if node && node.node_instances.reload.empty?
      rescue StandardError => e
        Rails.logger.error(
          "[InstancePoolService] record prune failed " \
          "(instance=#{member.id} pool='#{pool.name}'): #{e.class}: #{e.message}"
        )
      end

      pruned
    end

    # Second retention phase: pool-provenance Node shells with no instances
    # left at all.
    #
    # prune_dead_records! iterates pool.node_instances, so it can only ever
    # reach a Node through a surviving member. A Node whose instances are all
    # gone but whose own destroy! failed — system_node_modules.node_id is a
    # NO ACTION FK, and Node's has_many :node_modules goes THROUGH
    # node_module_assignments, a different column, so no `dependent:` covers it
    # — becomes permanently invisible to the member loop and leaks with no path
    # to collection. This is that path.
    #
    # Deliberately narrow: this pool's own account, pool provenance recorded in
    # config by provision_warming_member!, zero instances, and past the same
    # retention window. Provenance is matched with `@>` rather than `->>` so it
    # uses the GIN jsonb_ops index on system_nodes.config — equivalent for a
    # string value, but `->>` cannot use that index and this runs every 60s per
    # pool. Both raw fragments qualify the table because `where.missing` LEFT
    # JOINs system_node_instances, which has its own `config` and `updated_at`.
    #
    # The age guard is load-bearing, not decoration:
    # provision_warming_member! creates the Node in step 1 and its instance in
    # step 2, so a just-created Node is legitimately instance-less for the
    # width of that gap.
    def prune_orphaned_node_shells!(pool:, now:)
      retention_days = record_retention_days(pool)
      return 0 if retention_days <= 0

      cutoff = now - retention_days.days
      shells = ::System::Node
               .where(account_id: pool.account_id)
               .where("system_nodes.config @> ?", { instance_pool_id: pool.id }.to_json)
               .where("system_nodes.updated_at < ?", cutoff)
               .where.missing(:node_instances)

      pruned = 0
      shells.find_each do |node|
        destroy_pool_node_shell!(node)
        pruned += 1
      rescue StandardError => e
        Rails.logger.error(
          "[InstancePoolService] node shell prune failed " \
          "(node=#{node.id} pool='#{pool.name}'): #{e.class}: #{e.message}"
        )
      end

      pruned
    end

    # Node-level analogue of NodeInstance#cascade_destroy_dependents!. Only one
    # FK onto system_nodes is both NO ACTION and unhandled by a `dependent:`
    # declaration: system_node_modules.node_id, whose belongs_to is
    # `optional: true` — so it nullifies, exactly as the optional arm of
    # CASCADE_DEPENDENTS does, keeping the module row and its history.
    # (system_node_module_assignments and system_node_instances are covered by
    # dependent: :destroy; system_bootstrap_tokens.node_id is ON DELETE CASCADE.)
    def destroy_pool_node_shell!(node)
      ::ActiveRecord::Base.transaction do
        ::System::NodeModule.where(node_id: node.id)
                            .update_all(node_id: nil, updated_at: Time.current)
        node.destroy!
      end
    end

    # Per-pool retention knob, shared by both retention phases so they can
    # never drift apart. Operator policy — deliberately not changed here.
    def record_retention_days(pool)
      pool.metadata.to_h["record_retention_days"].presence&.to_i ||
        DEAD_RECORD_RETENTION_DAYS
    end

    # Best-effort provider resolution for reload_pending_seeds! — a member
    # whose pool/region has no resolvable provider connection (misconfigured,
    # deleted, etc.) should be skipped for this tick, not blow up the whole
    # reaper run.
    def resolve_seed_reload_provider(member)
      ::System::Providers::Registry.for_instance(member)
    rescue StandardError => e
      Rails.logger.warn(
        "[InstancePoolService] reload_pending_seeds!: no provider for instance=#{member.id}: #{e.class}: #{e.message}"
      )
      nil
    end

    attr_reader :account

    # Best-effort + guarded reset of a member's granted_mcp_tools on the
    # reuse-without-reset release path (IMP-71c852bffc37) — see the call site
    # comment for why this must clear rather than restore a baseline. No-op
    # for an instance that never announced as a peer, and no-op (no write) if
    # the grant is already empty.
    #
    # A reset failure must never block the member returning to the pool (same
    # best-effort discipline as the deploy-key revoke beside it) — but unlike
    # that revoke, a swallowed failure here means the instance goes back into
    # circulation STILL carrying the widened grant, i.e. the original defect
    # with extra steps. So this must never be silent: error-level log (not
    # warn) plus a high-severity FleetEvent, the same "loud, never raise"
    # shape #abandon_errored_member! uses for its own can't-block-but-can't-
    # hide failure below.
    def reset_granted_mcp_tools!(instance, pool:)
      peer = ::System::NodeInstancePeer.find_by(node_instance_id: instance.id)
      return unless peer
      return if Array(peer.granted_mcp_tools).empty?

      peer.grant_mcp_tools!([], mode: :replace)
    rescue StandardError => e
      Rails.logger.error(
        "[InstancePoolService] granted_mcp_tools reset FAILED (instance=#{instance&.id} " \
        "pool='#{pool&.name}') — the member is returning to the pool STILL CARRYING its prior " \
        "acquirer's MCP tool grant; operator review required: #{e.class}: #{e.message}"
      )

      ::System::Fleet::EventBroadcaster.emit!(
        account: pool&.account || instance&.account,
        kind: "system.pool.mcp_grant_reset_failed",
        severity: :high,
        payload: {
          pool_id: pool&.id,
          pool_name: pool&.name,
          instance_id: instance&.id,
          error_class: e.class.name,
          error_message: e.message
        },
        source: "instance_pool_service",
        node_instance_id: instance&.id
      )
    end

    # Shared per-claim-cycle flag guard for the claimed_ttl and
    # claimed-heartbeat stale paths (F1-10 and its heartbeat-triggered
    # sibling): stamps pool_claimed_stale_flagged_at unless the current
    # claim has already been flagged this cycle (by either trigger).
    # Returns true if the member was (re-)flagged and the caller should
    # emit its FleetEvent + bump its counter; false if skipped.
    def flag_claimed_stale!(member:, now:)
      flagged_at = begin
        raw = member.config&.dig("pool_claimed_stale_flagged_at")
        raw.present? ? Time.zone.parse(raw) : nil
      rescue ArgumentError
        nil
      end
      return false if flagged_at && flagged_at >= member.pool_acquired_at

      member.merge_config!("pool_claimed_stale_flagged_at" => now.iso8601)
      true
    end

    def resolve_pool!(pool_name:, pool_id:, lifecycle_class:)
      if pool_id
        pool = ::System::InstancePool.for_account(account).find_by(id: pool_id)
        raise PoolError, "pool_id=#{pool_id} not found in account #{account.id}" unless pool
        return pool
      end

      if pool_name
        pool = ::System::InstancePool.for_account(account).find_by(name: pool_name)
        raise PoolError, "pool '#{pool_name}' not found in account #{account.id}" unless pool
        return pool
      end

      # Fallback — pick any active pool with matching lifecycle_class
      # and ready members. Used when caller wants ANY ready instance
      # regardless of pool name.
      query = ::System::InstancePool.for_account(account).active
      query = query.where(lifecycle_class: lifecycle_class) if lifecycle_class
      query = query.joins(:node_instances).where(system_node_instances: { pool_state: "ready" })

      pool = query.first
      raise NoReadyMembersError, "no active pool with ready members " \
                                  "(lifecycle_class=#{lifecycle_class || 'any'})" unless pool
      pool
    end

    # Provisions a single warming member. The actual NodeInstance row
    # creation + cloud provider call happens in the worker via the
    # standard provisioning flow; this method just creates a stub
    # Node + NodeInstance with pool_state="warming" and dispatches the
    # provision job.
    def provision_warming_member!(pool:, slot_index:)
      # Step 1 — create the parent Node row. NodeInstance gets created
      # by ProvisioningService.provision_instance below; we don't
      # pre-create it because provision_instance always creates a
      # fresh row (calling it on an existing instance would either
      # double-up or no-op, neither of which is what we want).
      # THE MEMBER NODE CARRIES NO COPY OF THE POOL'S CLASS.
      # IMP-19843220ac68 retired `system_nodes.lifecycle_class`: this method
      # used to write `pool.lifecycle_class` onto the member. It was a
      # SNAPSHOT, never a view — rotating pool.lifecycle_class afterwards
      # (GitOps apply_pool "update" carries it) left the copy not refreshed on
      # members already created — and nothing anywhere read it.
      # IMP-f2a7a729d39b then dropped the column, so passing the attribute
      # here now raises ActiveModel::UnknownAttributeError.
      #
      # The pool row is authoritative and stays reachable from the member
      # through `config["instance_pool_id"]` below, which is the value any
      # future lifecycle short-circuit must read. Do not reintroduce the copy;
      # spec/models/system/node_lifecycle_class_retirement_spec.rb reddens on it.
      node = ::System::Node.create!(
        account: account,
        name: "#{pool.name}-pool-#{Time.current.to_i}-#{slot_index}",
        node_template: pool.node_template,
        enabled: true,
        config: { "instance_pool_id" => pool.id }
      )

      # Step 2 — synchronously provision the cloud instance via the
      # canonical ProvisioningService path (the same path the MCP
      # `system_provision_instance` action uses; proven-working). This
      # returns when the libvirt/cloud VM is created + the
      # NodeInstance row is populated with cloud_instance_id + status.
      #
      # Why synchronous? The previous implementation dispatched to a
      # System::NodeInstanceProvisionJob worker job that:
      #   (a) had its method called wrong (.dispatch vs .enqueue)
      #   (b) expected node_id + operation_id args (an Operation
      #       record had to exist first); pool was sending
      #       node_instance_id + options hash
      #   (c) the queue 'system' wasn't even in the worker's listened
      #       queue list, so jobs accumulated forever in Redis
      # All three layers were broken; pool replenish has NEVER
      # actually provisioned cloud instances since pool support
      # landed. A synchronous direct call to ProvisioningService is
      # both correct and proven; the trade-off is replenish call
      # latency ≈ deficit × per-instance provisioning time
      # (~3-5s per cloud VM in our LocalQemu setup).
      # Audit plan P2.5 gap #1 + #5 — cross-AZ replenishment + AZ failover.
      # `pool.preferred_regions` is round-robin'd at slot_index for HA spread;
      # `pool.metadata.region_health` (populated by InstanceStatusSensor) lets
      # us skip degraded regions automatically. Empty preferred_regions falls
      # back to the single `provider_region_id` column (single-AZ default).
      chosen_region_id = pick_region_for_slot(pool: pool, slot_index: slot_index)

      # protection: false — ProxmoxProvider defaults new VMs to protection=1
      # (apply_protection!), a setting meant for durable/persistent
      # instances. Pool members are inherently ephemeral (recycled on TTL,
      # heartbeat staleness, or drain); leaving them protected adds a second
      # way cleanup can fail to actually delete the VM (PVE refuses to
      # DELETE a protected VM) on top of terminate_instance already having
      # to clear the flag first.
      result = ::System::ProvisioningService.provision_instance(
        node: node,
        provider_region_id: chosen_region_id,
        provider_instance_type_id: pool.provider_instance_type_id,
        options: { protection: false }
      )

      unless result.success?
        Rails.logger.warn(
          "[InstancePoolService] cloud provision failed for pool '#{pool.name}' " \
          "slot=#{slot_index}: #{result.error}"
        )
        # Tear down the orphan Node so re-replenish doesn't accumulate
        # zombie nodes; the failure is propagated to the operator via
        # the result.error path.
        node.destroy
        raise PoolError, "cloud provision failed: #{result.error}"
      end

      # Step 3 — patch the freshly-created NodeInstance with the pool
      # tracking fields. ProvisioningService doesn't know about pools;
      # we apply pool_state/pool_warming_started_at/instance_pool_id
      # here so the pool's accounting (warming_count, ready_count,
      # deficit) is honest.
      instance = result.data[:instance]
      instance.update!(
        instance_pool_id: pool.id,
        pool_state: "warming",
        pool_warming_started_at: Time.current
      )

      instance
    end

    # P2.5 gap #1 + #5 — choose a provider_region for a given pool slot.
    # Prefers the `preferred_regions` list (round-robin by slot_index) and
    # filters out regions marked unhealthy via `pool.metadata["region_health"]`.
    # Falls back to `pool.provider_region_id` if no preferred list is set.
    def pick_region_for_slot(pool:, slot_index:)
      preferred = Array(pool.preferred_regions).compact_blank
      return pool.provider_region_id if preferred.empty?

      region_health = pool.metadata.is_a?(Hash) ? pool.metadata["region_health"].to_h : {}
      healthy = preferred.reject { |rid| region_health[rid.to_s].to_s == "unhealthy" }
      # All preferred regions unhealthy — fall back to the canonical preferred
      # list rather than skipping the slot. Operator visibility of the degraded
      # state lives in InstanceStatusSensor's emitted events.
      pool_choices = healthy.any? ? healthy : preferred
      pool_choices[slot_index % pool_choices.size]
    end
  end
end
