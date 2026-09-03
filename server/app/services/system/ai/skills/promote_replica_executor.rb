# frozen_string_literal: true

module System
  module Ai
    module Skills
      # APO-6 (DR-3) — PROMOTE A POSTGRES STREAMING REPLICA, the recovery half
      # of the cluster_member spawn mode.
      #
      # WHAT WAS MISSING. `modules/postgres-replica` has streamed from a parent
      # primary since P6.4: System::ClusterMember::PgReplicaSetupService creates
      # the physical slot, mints the replication role and stashes the credential
      # in Vault, and ClusterMemberPgReplicaSetupJob drives it. That is the
      # SETUP side, and it was the only side. A grep for
      # promote/pg_promote/failover across both postgres module manifests, the
      # setup job and System::PlatformDeploymentOrchestrator returned nothing:
      # the platform could BUILD a replica and had no way to use one. "The
      # primary is gone" ended in a person with psql, while the replica sat
      # caught up and idle.
      #
      # WHY THE VIP IS THE CUTOVER POINT, not a config edit. The component-per-
      # instance north star puts the DB behind an Sdwan::VirtualIp, and the
      # promote's job is to make that name resolve to the promoted node. Editing
      # postgresql.conf on the old primary is not available on the path this
      # executor exists for — the host is unreachable, which is why we are
      # promoting — so the durable fence has to be a control-plane write.
      # Moving the VIP off the old primary's peer is that write: nothing reaches
      # the old host as primary again even if its VM comes back.
      #
      # THE TWO SAFETY CONDITIONS (operator ruling 2026-09-02), and which of
      # them is waivable:
      #
      #   * SPLIT BRAIN — the primary must be PROVIDER-CONFIRMED DOWN. Read the
      #     same way System::Fleet::Sensors::InstanceUnrecoverableSensor reads
      #     it (adapter #sync_status, TERMINAL_PROVIDER_STATES), and EVERY
      #     absence path — no adapter, no cloud id, an unsuccessful read, a
      #     blank status, a raise — counts as "not confirmed down". NOT
      #     WAIVABLE by any input: two primaries accepting writes for the same
      #     database is the one outcome no approval can make safe, and a
      #     planned switchover (primary alive, drained on purpose) is a
      #     different verb that this one deliberately does not pretend to be.
      #
      #   * DATA LOSS — the replica's lag AT THE LAST SAMPLE must be under a
      #     DB-resolved bound. Once the primary is gone the true lag is
      #     unknowable, so the last sample is the only evidence there is; a
      #     MISSING or STALE sample is therefore a refusal, not a pass. This one
      #     IS waivable, by an explicit `accept_data_loss: true` — an operator
      #     may knowingly trade unreplicated writes for availability, and
      #     refusing that outright would leave a dead database with a healthy
      #     standby next to it. The waiver does not bypass the approval gate:
      #     every invocation still resolves #{ACTION_CATEGORY} first, so the
      #     auto arm (a policy tuned to proceed) never sets the flag and
      #     therefore auto-applies ONLY when both conditions hold, which is
      #     exactly the ruling.
      #
      # THE OLD PRIMARY IS FENCED, NEVER RESTARTED. This class has no start /
      # restart / reboot call site at all — the same shape ReplaceInstanceExecutor
      # uses to make "a replace never terminates anything" survive an unexpected
      # input. Re-basing the old host as a replica of the promoted node is a
      # separate, operator-initiated act.
      #
      # WHAT THE MODULE MANIFESTS OWN. The promote and fence COMMANDS are
      # declared by the modules (postgres-replica's `promote_command`,
      # postgres-primary's `fence_command`, both under the service's
      # `metadata:` alongside a namespaced `pg_role:`) and resolved here off
      # the imported System::ModuleService rows. A missing declaration is a
      # REFUSAL and an AMBIGUOUS one (two modules claiming the same pg_role
      # with different commands) is also a refusal, so the manifest keys are
      # load-bearing rather than documentation, and a module that moves to a new
      # PG major or cluster name changes one manifest instead of a constant on
      # the control plane. NOTE: a manifest change reaches the fleet only via a
      # module BUILD — shipping this class does not by itself put the promote
      # command on any node.
      #
      # IDEMPOTENT ON operation_id, keyed off the System::FleetEvent it writes,
      # the same ledger shape the DR replace lane uses: a re-drive after a
      # partial run replays the recorded outcome instead of promoting twice or
      # re-pointing a VIP an operator has since moved back.
      class PromoteReplicaExecutor < BaseSkillExecutor
        # Declared rather than derived: the derived name would be
        # system.promote_replica, and the operator-facing row, the
        # PolicyDeclarations entry and Ai::AutonomyGate must all resolve the
        # SAME spelling.
        #
        # DECLARED since IMP-93b83b5c82d8 (commit 1df6f589), NOT by APO-6b:
        # the category has its row in
        # System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES —
        #
        #     "system.replica_promote"         => "require_approval",
        #
        # (system.instance_replace / system.instance_reap, which this lane is
        # the DR sibling of, sat next to it there until HIER-P2DECL moved them
        # to CAPACITY_MANAGER_POLICIES; this key stayed) — and
        # docs/FLEET_SENSORS.md's
        # "### Fleet Autonomy agent (N policies)" heading counts it, which is
        # what spec/docs/reference_counts_spec.rb pins. So
        # System::Autonomy::ActionCategoryRouter sees a declared routed lane
        # and FleetAutonomyService#gate_action! parks an operator-visible card
        # instead of failing GATE_POLICY_MISSING.
        #
        # STILL OPERATIONALLY TRUE: a declaration is not a seeded row.
        # Re-seeding fleet_autonomy_agent.rb is required on an already-running
        # host — db:seed is first-boot-only, so a live fleet that predates the
        # declaration has no intervention policy for this name and falls back
        # to Ai::InterventionPolicyService#default_policy (require_approval,
        # fail-safe, but no tunable row an operator can find).
        ACTION_CATEGORY = "system.replica_promote"

        # Event kind prefix — one kind per step, all carrying the payload's
        # `operation_id`, so a whole promote reads off System::FleetEvent by
        # correlation as well as step by step.
        EVENT_PREFIX = "system.replica_promote"

        # The replication record ClusterMemberPgReplicaSetupService stamps onto
        # the cluster_member peer, and the two keys inside it the lag sampler
        # maintains.
        #
        # THE SAMPLER is System::Fleet::Sensors::ReplicaLagSensor
        # (IMP-5b38cd356010, APO-6b), on the Fleet Autonomy tick: it reads
        # pg_stat_replication on the platform's own connection — the primary
        # every cluster_member child streams from, the same connection
        # PgReplicaSetupService created the slot on — and writes these two
        # keys onto the peer at a SensorConfig-tunable interval (default 60s,
        # inside the DEFAULT_LAG_SAMPLE_MAX_AGE window below). When this class
        # first shipped nothing wrote them, so #lag_refusal refused every real
        # promote and DR-3 was waiver-only; with the sampler in the tick the
        # AUTO arm of the operator ruling is reachable. The sampler never
        # writes a sample it did not take (a replica that is not streaming
        # leaves the last sample to age out), which is what makes the
        # absence-and-staleness-are-refusals rule below safe.
        CLUSTER_PG_KEY  = "cluster_pg"

        # System::SpawnPlatformService's record of WHICH NodeInstance the
        # cluster_member spawn produced — the peer's own statement of the
        # replica it describes.
        PEER_INSTANCE_KEY = "node_instance_id"
        LAG_BYTES_KEY   = "replication_lag_bytes"
        LAG_SAMPLED_KEY = "lag_sampled_at"

        # Manifest-declared roles, matched against System::ModuleService#metadata
        # rather than against a module NAME — the name is an authoring choice,
        # the role is the contract.
        #
        # NAMESPACED KEY AND VALUE. `metadata.role = "primary"` was an
        # unnamespaced token in a free-form jsonb bag: a redis-primary or
        # mysql-primary module declaring it would have had its command handed
        # to a postgres fence. The key is `pg_role` and the primary's value is
        # `postgres_primary` so a collision has to be deliberate — and
        # #declared_command REFUSES on a collision rather than taking .first of
        # an unordered relation.
        ROLE_KEY     = "pg_role"
        REPLICA_ROLE = "streaming_replica"
        PRIMARY_ROLE = "postgres_primary"

        # POLICY, DB-resolved via SiteSetting with a constant fallback; never
        # ENV, never a bare literal in the code path.
        #
        # 16 MiB is one WAL segment: a replica within a single segment of the
        # primary has, at the last sample, lost at most the writes of one
        # segment. The freshness window bounds how old that evidence may be —
        # a sample from last week says nothing about the moment the primary
        # died, and treating it as a pass is the "absence of a refusal is not
        # a passed gate" failure in its most expensive form.
        MAX_LAG_BYTES_SETTING       = "system.promote_replica.max_lag_bytes"
        LAG_SAMPLE_MAX_AGE_SETTING  = "system.promote_replica.lag_sample_max_age_seconds"
        DEFAULT_MAX_LAG_BYTES       = 16 * 1024 * 1024
        DEFAULT_LAG_SAMPLE_MAX_AGE  = 300

        # Provider states that mean the VM is gone. REFERENCED, not restated:
        # the class comment promises this reading is the one
        # InstanceUnrecoverableSensor makes, and a copied literal would let the
        # two drift silently the next time the sensor's list changes.
        # "terminated" additionally means there is no VM object left to fence,
        # so the best-effort fence command is not dispatched for it.
        TERMINAL_PROVIDER_STATES =
          ::System::Fleet::Sensors::InstanceUnrecoverableSensor::TERMINAL_PROVIDER_STATES
        DESTROYED_PROVIDER_STATE = "terminated"

        skill_descriptor(
          name: "promote_replica",
          description: "Promote a postgres streaming replica to primary after the primary is provider-confirmed down: cut the DB VIP over to the replica's SDWAN peer, fence the old primary, and dispatch the module-declared pg_ctl promote. Refuses a live primary outright and refuses an unknown or over-bound replication lag unless the operator accepts the data loss.",
          category: "fleet",
          inputs: {
            peer_id: { type: "string", required: true,
                       description: "System::FederationPeer carrying the cluster_pg replication record (spawn_mode cluster_member)" },
            primary_instance_id: { type: "string", required: true,
                                   description: "System::NodeInstance running postgres-primary — the LOST one" },
            replica_instance_id: { type: "string", required: true,
                                   description: "System::NodeInstance running postgres-replica — the one to promote" },
            operation_id: { type: "string", required: true,
                            description: "Idempotency key — the promote is replayed if a FleetEvent already records it for this id" },
            virtual_ip_id: { type: "string", required: false,
                             description: "Restrict the cutover to ONE Sdwan::VirtualIp (default: every VIP the old primary's peers hold)" },
            reason: { type: "string", required: false,
                      description: "Classified reason from the sensor, carried onto every step event" },
            accept_data_loss: { type: "boolean", required: false, default: false,
                                description: "Waive the replication-lag bound. Waives NOTHING else — a live primary is refused regardless." },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — report the safety verdict and what would move, without promoting" }
          },
          outputs: {
            promoted: :boolean,
            replayed: :boolean,
            moved_virtual_ip_ids: [ :string ],
            promote_task_id: :string,
            fence_command: :string,
            fence_dispatched: :boolean,
            data_loss_accepted: :boolean,
            blocked: :boolean
          },
          requires_approval: true,
          action_category: ACTION_CATEGORY,
          blast_radius: :high
        )

        binds_to "Fleet Autonomy"

        protected

        def perform(peer_id:, primary_instance_id:, replica_instance_id:, operation_id:,
                    virtual_ip_id: nil, reason: nil, accept_data_loss: false, dry_run: false)
          peer = find_peer(peer_id)
          return failure("Cluster_member peer not found in account scope: #{peer_id}") unless peer

          primary = find_instance(primary_instance_id)
          return failure("Primary instance not found in account scope: #{primary_instance_id}") unless primary

          replica = find_instance(replica_instance_id)
          return failure("Replica instance not found in account scope: #{replica_instance_id}") unless replica

          # THE PEER MUST NAME THIS CLUSTER, checked before anything is read
          # off it. The lag sample is the only WAIVABLE safety condition and it
          # lives on the caller-supplied peer, and the promotion stamp is
          # WRITTEN to that peer — an uncorrelated peer would let a caught-up
          # spawn from an unrelated cluster satisfy the gate for a badly
          # lagging replica, and would stamp the wrong cluster's record.
          correlation = correlation_refusal(peer: peer, primary: primary, replica: replica)
          return failure(correlation) if correlation

          # A REPLAY IS THE FIRST QUESTION, ahead of the safety gates: the
          # conditions that licensed the promote (the primary was terminal, the
          # lag sample was fresh) legitimately stop holding the moment it
          # succeeds, so re-evaluating them on a re-drive would report a
          # completed promote as a refusal.
          prior = replayed_promote(operation_id)
          if prior
            return success(prior.payload.symbolize_keys.merge(promoted: true, replayed: true))
          end

          # ONE provider read for the whole run. Reading it again inside the
          # fence would let the two answers disagree — a primary that reads
          # `error` at the safety gate and `running` a second later would be
          # fenced on evidence the gate no longer has, and vice versa.
          primary_status = provider_status(primary)

          vips    = cutover_vips(primary, virtual_ip_id)
          refusal = safety_refusal(primary: primary, primary_status: primary_status,
                                   peer: peer, accept_data_loss: accept_data_loss) ||
                    cutover_refusal(vips: vips, replica: replica)

          if dry_run
            return plan(peer: peer, primary: primary, primary_status: primary_status,
                        replica: replica, vips: vips,
                        refusal: refusal, accept_data_loss: accept_data_loss)
          end

          return failure(refusal) if refusal

          ambiguous = ambiguity_refusal(REPLICA_ROLE, "promote_command") ||
                      ambiguity_refusal(PRIMARY_ROLE, "fence_command")
          return failure(ambiguous) if ambiguous

          promote_command = declared_command(REPLICA_ROLE, "promote_command")
          unless promote_command
            return failure(
              "No module declares a promote_command for role #{REPLICA_ROLE}: the replica cannot be " \
              "promoted from the control plane until postgres-replica's manifest carries " \
              "services[].metadata.promote_command AND that manifest change has been BUILT into the " \
              "module version the fleet runs."
            )
          end

          fence_command = declared_command(PRIMARY_ROLE, "fence_command")

          # FENCE BEFORE PROMOTE, in that order and never the reverse. The VIP
          # move is what makes the old primary unreachable AS primary; doing it
          # after the promote leaves a window in which the name still resolves
          # to a host that may be answering.
          #
          # ONE TRANSACTION around the cutover, the stamp, the dispatched tasks
          # AND the ledger event. They are one fact — "this replica is the
          # primary now" — and each pair that can commit without the other is a
          # distinct way to be wrong:
          #   * stamp without cutover: the peer record names a host the VIP
          #     does not, so every later reader trusts the wrong node;
          #   * cutover + dispatch without the LEDGER: nothing records that the
          #     promote applied, so #replayed_promote finds no marker and the
          #     next drive promotes a second time — which is exactly the
          #     "idempotent on operation_id" promise this class makes.
          # The System::Task rows are DB rows an async dispatcher picks up, so
          # creating them here means they become visible only on commit.
          payload = nil
          begin
            ::ActiveRecord::Base.transaction do
              moved_vip_ids = fence_vips!(vips: vips, primary: primary, replica: replica)
              stamp_promotion!(peer: peer, primary: primary, replica: replica)

              fence_task   = dispatch_fence(primary: primary, status: primary_status, command: fence_command)
              promote_task = dispatch_promote(replica: replica, command: promote_command)

              payload = {
                "promoted" => true,
                "peer_id" => peer.id,
                "primary_instance_id" => primary.id,
                "replica_instance_id" => replica.id,
                "moved_virtual_ip_ids" => moved_vip_ids,
                "promote_task_id" => promote_task&.id,
                "promote_command" => promote_command,
                "fence_command" => fence_command,
                "fence_task_id" => fence_task&.id,
                "fence_dispatched" => !fence_task.nil?,
                "data_loss_accepted" => accept_data_loss == true
              }

              record_step!(step: "promote", operation_id: operation_id, payload: payload,
                           instance: replica, reason: reason, severity: "high")
            end
          rescue ::ActiveRecord::ActiveRecordError => e
            # A HALF-APPLIED CUTOVER IS THE ONE OUTCOME WORSE THAN A REFUSAL,
            # so the rollback is reported as a refusal an operator reads rather
            # than re-raised as a stack trace. Nothing was written.
            Rails.logger.error("[PromoteReplicaExecutor] cutover rolled back: #{e.class}: #{e.message}")
            return failure(
              "Refusing to report a promote that did not apply: the cutover was rolled back " \
              "(#{e.class}: #{e.message}). No virtual ip moved, no promotion was stamped and no " \
              "task was dispatched — re-drive with the same operation_id once the cause is cleared."
            )
          end

          success(payload.symbolize_keys.merge(replayed: false))
        end

        # ── safety ─────────────────────────────────────────────────────────

        # nil when the promote may run, otherwise the refusal an operator reads.
        def safety_refusal(primary:, primary_status:, peer:, accept_data_loss:)
          split_brain_refusal(primary, primary_status) ||
            (accept_data_loss == true ? nil : lag_refusal(peer))
        end

        # NOT WAIVABLE. Every absence path is "not confirmed down" — the same
        # conservative direction InstanceUnrecoverableSensor#provider_probe
        # takes, and for a stronger reason here: it proposes a replace, this
        # takes a database's write path away from a host that may still own it.
        def split_brain_refusal(primary, status)
          return nil if TERMINAL_PROVIDER_STATES.include?(status)

          "Refusing to promote: the primary #{primary.name} is not provider-confirmed down " \
          "(provider reports #{status.presence || 'nothing readable'}). Promoting around a primary " \
          "that may still be accepting writes is a split brain, and no approval makes that safe. " \
          "This guard is not waivable — a planned switchover is a different operation."
        end

        # The last sample is the ONLY evidence of how far behind the replica is
        # once the primary is unreachable, so absence and staleness are
        # refusals rather than passes.
        def lag_refusal(peer)
          cluster_pg = peer.metadata.is_a?(Hash) ? peer.metadata[CLUSTER_PG_KEY] : nil
          cluster_pg = {} unless cluster_pg.is_a?(Hash)

          bytes = Integer(cluster_pg[LAG_BYTES_KEY].to_s, exception: false)
          taken = parse_time(cluster_pg[LAG_SAMPLED_KEY])
          max   = positive_setting(MAX_LAG_BYTES_SETTING, DEFAULT_MAX_LAG_BYTES)
          age   = positive_setting(LAG_SAMPLE_MAX_AGE_SETTING, DEFAULT_LAG_SAMPLE_MAX_AGE)

          if bytes.nil? || taken.nil?
            return "Refusing to promote: peer #{peer.id} carries no replication lag sample " \
                   "(#{CLUSTER_PG_KEY}.#{LAG_BYTES_KEY} / #{CLUSTER_PG_KEY}.#{LAG_SAMPLED_KEY}). " \
                   "An unsampled replica is not a caught-up replica. Pass accept_data_loss: true " \
                   "to promote anyway and accept whatever was not replicated."
          end

          if taken < age.seconds.ago
            return "Refusing to promote: the replication lag sample for peer #{peer.id} was taken " \
                   "#{taken.iso8601} — older than the #{age}s freshness window " \
                   "(SiteSetting #{LAG_SAMPLE_MAX_AGE_SETTING}). A stale sample says nothing about " \
                   "the moment the primary died. Pass accept_data_loss: true to promote anyway."
          end

          return nil if bytes <= max

          "Refusing to promote: replication lag at the last sample was #{bytes} bytes, over the " \
          "#{max}-byte bound (SiteSetting #{MAX_LAG_BYTES_SETTING}). Pass accept_data_loss: true to " \
          "promote anyway and accept the unreplicated writes."
        end

        # THE PEER ↔ CLUSTER LINK. `cluster_pg` has THREE writers, and the role
        # guard below holds because every one of them applies the same
        # parent-only filter — not because any one of them is the sole writer:
        #
        #   * System::ClusterMember::PgReplicaSetupService CREATES the record
        #     and refuses any peer whose spawn_role is not "parent";
        #   * System::Fleet::Sensors::ReplicaLagSensor SAMPLES into it, and its
        #     candidate scope is spawn_mode "cluster_member" AND spawn_role
        #     "parent" (replica_lag_sensor.rb #candidates);
        #   * #stamp_promotion! below STAMPS it, only after this very guard.
        #
        # So a peer with another role cannot be carrying a legitimate lag
        # sample no matter what its metadata says. THAT INVARIANT IS THE
        # SENSOR'S FILTER AS MUCH AS THE SETUP SERVICE'S: widening either
        # population to a non-parent peer falsifies this guard's premise and
        # the refusal text it prints, so widen neither without revisiting both.
        # System::SpawnPlatformService stamps `metadata.node_instance_id` with
        # the spawned CHILD's NodeInstance — the replica — so that key is the
        # peer's statement of which host it describes.
        #
        # ABSENCE IS A REFUSAL, deliberately. A cluster_member spawn that was
        # provisioned records node_instance_id; one that was not has no replica
        # NodeInstance to promote in the first place, and accepting an
        # unlinked peer would make the correlation check waivable by simply
        # omitting the field — which is the shape of gate this platform has
        # been burned by before.
        def correlation_refusal(peer:, primary:, replica:)
          if primary.id == replica.id
            return "Refusing to promote: primary_instance_id and replica_instance_id name the same " \
                   "host (#{replica.name}). A promote fences one node and promotes another."
          end

          unless peer.spawn_role.to_s == "parent"
            return "Refusing to promote: peer #{peer.id} has spawn_role " \
                   "#{peer.spawn_role.inspect}, and every writer of #{CLUSTER_PG_KEY} — " \
                   "System::ClusterMember::PgReplicaSetupService, which prepares it, and " \
                   "System::Fleet::Sensors::ReplicaLagSensor, which samples into it — only ever " \
                   "touches a \"parent\" peer. This peer cannot be carrying this cluster's " \
                   "replication record."
          end

          declared = peer.metadata.is_a?(Hash) ? peer.metadata[PEER_INSTANCE_KEY].to_s : ""
          if declared.blank?
            return "Refusing to promote: peer #{peer.id} carries no #{PEER_INSTANCE_KEY}, so nothing " \
                   "proves it describes the cluster containing #{replica.name}. The lag sample and " \
                   "the promotion stamp both live on this peer — an unlinked peer would let another " \
                   "cluster's evidence license this promote."
          end

          return nil if declared == replica.id

          "Refusing to promote: peer #{peer.id} does not describe #{replica.name} — its " \
          "#{PEER_INSTANCE_KEY} is #{declared}. Name the peer of the cluster_member spawn that " \
          "created this replica."
        end

        # ── the cutover ────────────────────────────────────────────────────

        # SUBSTITUTION on the holder set, the same write ReplaceInstanceExecutor
        # #move_vips! makes and for the same reason: #failover! promotes a
        # designated STANDBY and rotates the old head into the failover list,
        # which would leave the fenced primary as a promotion candidate. Here
        # the old primary must come OFF both lists entirely.
        def fence_vips!(vips:, primary:, replica:)
          # NO EARLY EXIT on an empty primary peer set. An explicitly named
          # virtual_ip_id can be a VIP the old primary never held, and bailing
          # here would skip the loop entirely — reporting a promote that moved
          # nothing as a success. Subtracting an empty array is a harmless
          # no-op; the replica still has to be added.
          primary_peer_ids = sdwan_peer_ids(primary)

          moved = []
          vips.each do |vip|
            holders  = Array(vip.holder_peer_ids)
            standbys = Array(vip.failover_holder_peer_ids)

            # The parens are load-bearing: `|` binds LOOSER than `-` in Ruby, so
            # the subtraction is what must happen first — the promoted peer is
            # added to what is LEFT after the fenced primary comes off, not to
            # the full holder set.
            vip.holder_peer_ids = ((holders - primary_peer_ids) | replica_peer_ids_for(vip, replica)).uniq
            # OFF THE STANDBY LIST TOO. #failover! promotes the head of
            # failover_holder_peer_ids, so a fenced primary left there is a
            # promotion candidate the next VIP failover would reach for.
            vip.failover_holder_peer_ids = (standbys - primary_peer_ids).uniq

            # save!, NOT `if vip.save`. Sdwan::VirtualIp validates its holder
            # set (non_anycast_single_holder, anycast_requires_holder_set), and
            # a non-anycast VIP whose failover list carries the fenced primary
            # while a THIRD peer holds it lands on two holders and is rejected.
            # Swallowing that returned `promoted: true` with the fenced primary
            # still answering under the name. The raise rolls the whole
            # promote back — see the rescue in #perform.
            vip.save!
            moved << vip.id
          end
          moved
        end

        # Only the replica peers that live on THIS VIP's network may hold it —
        # an Sdwan::VirtualIp belongs to one network, and adding a peer from
        # another would be a holder the data plane can never satisfy.
        # Resolved ONCE per run into a network => peer-ids hash. This is called
        # per-VIP from both #cutover_refusal and #fence_vips!, so a query per
        # call was two round trips per VIP for an answer that cannot change
        # inside the run.
        def replica_peer_ids_for(vip, replica)
          @replica_peer_ids_by_network ||=
            ::Sdwan::Peer.where(account_id: @account.id, node_instance_id: replica.id)
                         .pluck(:sdwan_network_id, :id)
                         .each_with_object(Hash.new { |h, k| h[k] = [] }) { |(net, id), acc| acc[net] << id }

          @replica_peer_ids_by_network[vip.sdwan_network_id]
        end

        # REFUSE BEFORE MUTATING. A VIP whose network the replica is not
        # enrolled on cannot be cut over: taking the fenced primary off it
        # would leave the VIP with NO holder at all — the database unreachable
        # under its own name, which is worse than the outage we are answering.
        # Checked across every VIP in the cutover, so a partial move is never
        # applied and then discovered.
        def cutover_refusal(vips:, replica:)
          # NO VIP IS NOT "NOTHING TO DO". The DB VIP is the cutover point: with
          # none resolved, the promote would dispatch pg_ctl and re-point
          # nothing, so every client would keep dialling the fenced host while
          # the result said `promoted: true`. Refuse instead of succeeding at
          # half the operation.
          if vips.empty?
            return "Refusing to promote: no Sdwan::VirtualIp resolves for this cutover. The DB VIP " \
                   "is the cutover point — without one the promote would re-point nothing and every " \
                   "client would keep dialling the fenced primary. Give the DB a VIP (or name an " \
                   "existing virtual_ip_id) before promoting."
          end

          stranded = vips.reject { |vip| replica_peer_ids_for(vip, replica).any? }
          return nil if stranded.empty?

          "Refusing to promote: #{replica.name} holds no SDWAN peer on the network of " \
          "VIP(s) #{stranded.map(&:id).join(', ')}, so the cutover would strip the fenced " \
          "primary off a VIP with nothing to replace it. Enrol the replica on that network " \
          "first (Sdwan::PeerEnroller), or name a different virtual_ip_id."
        end

        def sdwan_peer_ids(instance)
          ::Sdwan::Peer.where(account_id: @account.id, node_instance_id: instance.id).pluck(:id)
        end

        def cutover_vips(primary, virtual_ip_id)
          scope = ::Sdwan::VirtualIp.where(account_id: @account.id)
          return scope.where(id: virtual_ip_id).to_a if virtual_ip_id.present?

          peer_ids = sdwan_peer_ids(primary)
          return [] if peer_ids.empty?

          # FILTERED IN POSTGRES, not in Ruby. `scope.select { ... }` is
          # Enumerable#select on an unmaterialised relation — it loaded every
          # VIP in the account to find the handful the primary touches.
          # `&&` is array OVERLAP on a uuid[] column, which the holder indexes
          # can serve.
          scope.where(
            "holder_peer_ids && ARRAY[:ids]::uuid[] OR failover_holder_peer_ids && ARRAY[:ids]::uuid[]",
            ids: peer_ids
          ).to_a
        end

        # BEST EFFORT, and only while a VM object still exists. A `terminated`
        # instance has nothing to ssh into, and minting a task that can only
        # fail is the "false work" shape that makes a ledger unreadable — the
        # DURABLE fence is the VIP move plus the peer stamp, both of which have
        # already happened by the time this is called.
        def dispatch_fence(primary:, status:, command:)
          return nil if command.blank?
          return nil if status == DESTROYED_PROVIDER_STATE

          create_ssh_task(instance: primary, command: command,
                          note: "Fence old postgres primary before promotion")
        end

        def dispatch_promote(replica:, command:)
          create_ssh_task(instance: replica, command: command,
                          note: "Promote postgres streaming replica to primary")
        end

        # A SAVEPOINT, because this runs inside the cutover transaction: a
        # rescued INSERT failure would otherwise leave the outer transaction
        # aborted and every later statement in it would fail. A task that
        # cannot be minted is best-effort (the DURABLE fence is the VIP move
        # plus the stamp), so it degrades to nil rather than losing the
        # cutover — but a DB-level failure still reaches the outer rescue.
        def create_ssh_task(instance:, command:, note:)
          ::ActiveRecord::Base.transaction(requires_new: true) do
            ::System::Task.create!(
              account_id: @account.id,
              operable: instance,
              command: "ssh_command",
              status: "pending",
              initiated_by: @user,
              options: { "command" => command, "sudo" => true, "note" => note }
            )
          end
        rescue ::ActiveRecord::RecordInvalid => e
          Rails.logger.error("[PromoteReplicaExecutor] task create failed for #{instance.id}: #{e.message}")
          nil
        end

        # The operator-visible record of which node is primary now, and of the
        # host that must never be started as primary again.
        def stamp_promotion!(peer:, primary:, replica:)
          cluster_pg = peer.metadata.is_a?(Hash) ? peer.metadata[CLUSTER_PG_KEY] : nil
          cluster_pg = {} unless cluster_pg.is_a?(Hash)

          peer.update!(
            metadata: peer.metadata.merge(
              CLUSTER_PG_KEY => cluster_pg.merge(
                "state" => "promoted",
                "promoted_at" => Time.current.iso8601,
                "promoted_instance_id" => replica.id,
                "fenced_primary_instance_id" => primary.id
              )
            )
          )
        end

        # ── the preview an approval card is built from ─────────────────────
        #
        # A SUCCESS carrying the verdict, never a #failure: System::Fleet::
        # DecisionEngine's skill_metadata_payload reads `skill_result[:data]`,
        # which #failure does not carry, so a refusal returned as a failure
        # would park a card that says nothing about what was going to happen.
        # Same shape SdwanVipFailoverExecutor's dry_run branch uses.
        def plan(peer:, primary:, primary_status:, replica:, vips:, refusal:, accept_data_loss:)
          success(
            dry_run: true,
            blocked: refusal.present?,
            note: refusal,
            peer_id: peer.id,
            primary_instance_id: primary.id,
            primary_provider_status: primary_status,
            replica_instance_id: replica.id,
            data_loss_accepted: accept_data_loss == true,
            would_move_virtual_ip_ids: vips.map(&:id),
            would_promote_with: declared_command(REPLICA_ROLE, "promote_command"),
            would_fence_with: declared_command(PRIMARY_ROLE, "fence_command")
          )
        end

        # ── lookups ────────────────────────────────────────────────────────

        # The manifest-declared command for a role, read off the imported
        # System::ModuleService rows (ManifestImportService lands `services[]`
        # metadata verbatim). Matched on the declared ROLE rather than on a
        # module NAME so a re-named or forked postgres module still resolves.
        #
        # ACCOUNT-WIDE, not per-instance, and deliberately so: a NodeModule is
        # an account-level artifact and the role is its contract, while an
        # instance's effective module set is resolved on the node. Taking the
        # command from the instance would make the promote depend on the
        # assignment bookkeeping of a host that is, by construction, unreachable.
        def declared_command(role, key)
          declared_commands(role, key).first
        end

        # AMBIGUITY IS A REFUSAL, never a .first on an unordered relation. The
        # result is a root-equivalent command dispatched over ssh; two modules
        # declaring the same pg_role with different commands must be resolved
        # by a human, not by whichever row Postgres returned first.
        def declared_commands(role, key)
          ::System::ModuleService
            .where(account_id: @account.id)
            .where("metadata->>? = ?", ROLE_KEY, role)
            .filter_map { |svc| svc.metadata[key].presence }
            .uniq
        end

        # nil when exactly one command is declared (or none — the caller's own
        # "nothing declares it" refusal is the better message), otherwise the
        # collision an operator has to settle.
        def ambiguity_refusal(role, key)
          found = declared_commands(role, key)
          return nil if found.size <= 1

          "Refusing to promote: more than one module declares #{key} for #{ROLE_KEY} #{role} " \
          "(#{found.join(' | ')}). Which one runs is not something the control plane may guess " \
          "for a root-equivalent command — leave exactly one module declaring this role."
        end

        def find_peer(id)
          return nil if id.blank?

          ::System::FederationPeer
            .where(account_id: @account.id, spawn_mode: "cluster_member")
            .find_by(id: id)
        end

        # Account-scoped through the node, because that is where the account
        # lives — an instance id alone is not proof the caller may act on it.
        def find_instance(id)
          return nil if id.blank?

          ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: @account.id })
            .find_by(id: id)
        end

        # Read the provider the way InstanceUnrecoverableSensor does. Returns
        # the provider's own status string, or nil for EVERY absence path — no
        # adapter, no cloud id, an unsuccessful read, a blank status, a raise.
        def provider_status(instance)
          adapter = ::System::Providers::Registry.for_instance(instance)
          return nil unless adapter.respond_to?(:sync_status)

          cloud_id = instance.config&.dig("cloud_instance_id")
          return nil if cloud_id.blank?

          result = adapter.sync_status(cloud_id)
          return nil unless result.is_a?(Hash) && result[:success]

          result[:status].to_s.presence
        rescue StandardError => e
          Rails.logger.warn("[PromoteReplicaExecutor] provider read failed for #{instance.id}: #{e.message}")
          nil
        end

        # ── ledger ─────────────────────────────────────────────────────────

        def replayed_promote(operation_id)
          ::System::FleetEvent
            .where(account_id: @account.id, kind: "#{EVENT_PREFIX}.promote")
            .where("payload->>'operation_id' = ?", operation_id.to_s)
            .order(emitted_at: :desc)
            .first
        end

        # DELIBERATELY UNRESCUED: the event IS the ledger, so a promote that
        # applied and was not recorded would be re-applied on the next drive.
        def record_step!(step:, operation_id:, payload:, instance:, reason:, severity: "low")
          ::System::FleetEvent.create!(
            account_id: @account.id,
            kind: "#{EVENT_PREFIX}.#{step}",
            severity: severity,
            correlation_id: operation_id.to_s,
            payload: payload.merge(
              "operation_id" => operation_id.to_s,
              "step" => step,
              "reason" => reason
            ),
            node_instance_id: instance.id,
            emitted_at: Time.current
          )
        end

        # ── settings ───────────────────────────────────────────────────────

        # DB-resolved with a constant fallback. A missing, non-numeric or
        # non-positive override falls back rather than being taken literally: a
        # 0 bound would refuse every promote and silently disable the lane.
        def positive_setting(key, default)
          raw = defined?(::SiteSetting) ? ::SiteSetting.get(key) : nil
          value = Integer(raw.to_s, exception: false)
          value&.positive? ? value : default
        rescue StandardError
          default
        end

        def parse_time(value)
          return nil if value.blank?

          Time.zone.parse(value.to_s)
        rescue StandardError
          nil
        end
      end
    end
  end
end
