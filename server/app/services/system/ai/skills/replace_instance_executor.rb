# frozen_string_literal: true

module System
  module Ai
    module Skills
      # APO-4 (DR-1) — the first DISASTER-RECOVERY lane: replace an instance
      # the platform has classified UNRECOVERABLE with a warm pool member and
      # move its attachments across.
      #
      # WHY THIS CLASS EXISTS. Every verb it composes already shipped, each
      # reachable on its own: System::InstancePoolService#acquire! hands out a
      # warm member, System::VolumeManagementService attaches and detaches,
      # Sdwan::PeerEnroller enrols a node instance onto a network,
      # Sdwan::VirtualIp carries the holder set, and
      # System::ProvisioningService.terminate_instance reaps. NOTHING joined
      # them. InstanceUnrecoverableSensor (APO-2b) classified the condition and
      # System::Fleet::DecisionEngine routed it to system.instance_replace with
      # `skill: nil` and no applier — deliberately, because a half-wired
      # replace is worse than none — so the answer to "this VM is gone" was a
      # runbook under docs/runbooks a person walked by hand while the fleet ran
      # short an instance.
      #
      # THE TWO HALVES, AND WHY THEY GATE SEPARATELY (operator ruling
      # 2026-09-02). The ADDITIVE half — acquire, reattach, re-enrol, move the
      # VIP — only ever adds capacity and re-points attachments that are
      # already stranded; it applies as one unit once the replace itself is
      # approved, bounded by #bounds_refusal below so a stuck sensor cannot
      # drain a pool. The REAP is destructive and irreversible, so it lives in
      # a CLASS OF ITS OWN — ReapInstanceExecutor, whose action_category is
      # system.instance_reap — and this executor only ever ASKS for it through
      # Ai::AutonomyGate. THIS CLASS HAS NO TERMINATE CALL SITE AT ALL, which
      # is the only form of "a replace never terminates anything" that survives
      # a caller who passes unexpected inputs or an operator who retunes
      # system.instance_replace to a proceeding verb: a flag on this class
      # would have been gated on the ADDITIVE category, so the card an operator
      # released would have said "replace" and done a terminate.
      #
      # IDEMPOTENCY. Every step is keyed on `operation_id` and recorded as a
      # System::FleetEvent whose payload carries that id (see
      # InstanceReplacementLedger). Before a step runs, #prior_event looks for
      # its event; if one exists the step is SKIPPED and its recorded payload
      # is replayed into the result. That is what makes a re-drive after a
      # partial run safe — without it, a second pass would claim a SECOND warm
      # member out of the pool and leave the first one orphaned in `claimed`
      # with nothing attached to it.
      #
      # The operation_id is NOT trusted to be stable. The lane passes the
      # signal fingerprint, and the sensor rebuilds that fingerprint from a
      # reason it RE-DERIVES every tick — so the same dead instance arrives
      # under a new id the moment it reclassifies. #adopted_acquisition is the
      # answer: an acquire is also matched on the FAILED INSTANCE, so a
      # re-classified failure adopts the replacement it already has instead of
      # claiming a second one.
      class ReplaceInstanceExecutor < BaseSkillExecutor
        # EVENT_PREFIX, #replayed_step, #record_step! and #find_instance live
        # here, shared with ReapInstanceExecutor so both halves of one replace
        # write the same ledger under the same correlation_id.
        include InstanceReplacementLedger

        # The DESTRUCTIVE half's own operator control. Distinct from
        # system.instance_replace (which governs whether the replace runs at
        # all) precisely so the additive half can be tuned to proceed while the
        # terminate still needs a person. Declared in
        # System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES so
        # the reconciler lands a row on a running install. It is the category
        # ReapInstanceExecutor declares — named here rather than reached for
        # through that class so the constant reads at the call site that asks
        # for the approval.
        REAP_ACTION_CATEGORY = "system.instance_reap"

        # How far back #adopted_acquisition scans for an acquire naming the
        # same failed instance. Bounded so a long-lived account with thousands
        # of replace events cannot turn one lookup into a table walk; the
        # newest acquisition for an instance is the only one that can still be
        # live, and the scan is ordered newest-first.
        ADOPTION_SCAN_LIMIT = 25

        # BOUNDS on the additive half. A sensor that misclassifies — or a
        # provider outage that makes every instance look terminal — would
        # otherwise walk the whole pool one approved replace at a time. These
        # are POLICY, DB-resolved via SiteSetting with a constant fallback;
        # never read from ENV and never a bare literal in the code path.
        MAX_PER_WINDOW_SETTING = "system.replace_instance.max_per_window"
        WINDOW_MINUTES_SETTING = "system.replace_instance.window_minutes"
        DEFAULT_MAX_PER_WINDOW = 3
        DEFAULT_WINDOW_MINUTES = 60

        skill_descriptor(
          name: "replace_instance",
          description: "Replace an unrecoverable NodeInstance with a warm pool member: acquire the replacement, reattach its volumes, re-enrol it on every SDWAN network the failed one held (inheriting the failed peer's routing attributes, not the schema defaults), and move its VIPs. The terminate of the failed instance is a SEPARATE approval, performed by ReapInstanceExecutor.",
          category: "fleet",
          inputs: {
            instance_id: { type: "string", required: true,
                           description: "System::NodeInstance the platform classified unrecoverable" },
            operation_id: { type: "string", required: true,
                            description: "Idempotency key — every step is skipped if a FleetEvent already records it for this id" },
            pool_id: { type: "string", required: false,
                       description: "System::InstancePool to draw the replacement from (defaults to the failed instance's own pool)" },
            pool_name: { type: "string", required: false,
                         description: "Pool by name, when the failed instance is not itself a pool member" },
            reason: { type: "string", required: false,
                      description: "Classified reason from the unrecoverable sensor, carried onto every step event" },
            reap: { type: "boolean", required: false, default: false,
                    description: "Ask for the failed instance to be terminated. Handed to ReapInstanceExecutor under #{REAP_ACTION_CATEGORY} as a second approval; this executor never terminates anything itself." },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — report what would be moved without acquiring, attaching or enrolling" }
          },
          outputs: {
            replacement_instance_id: :string,
            reattached_volume_ids: [ :string ],
            enrolled_peer_ids: [ :string ],
            moved_virtual_ip_ids: [ :string ],
            replayed_steps: [ :string ],
            pool_ready_count: :integer,
            blocked: :boolean,
            failures: [ :object ],
            partial: :boolean,
            reaped: :boolean,
            reap_decision: :string
          },
          requires_approval: true,
          # The category the DecisionEngine lane already carries. Declared
          # rather than derived so the gate and the Autonomy modal resolve ONE
          # row (`system.instance_replace`) instead of two spellings of it —
          # the derived name would be `system.replace_instance`.
          action_category: "system.instance_replace",
          blast_radius: :high
        )

        binds_to "Fleet Autonomy"

        protected

        def perform(instance_id:, operation_id:, pool_id: nil, pool_name: nil, reason: nil,
                    reap: false, dry_run: false)
          failed = find_instance(instance_id)
          return failure("Instance not found in account scope: #{instance_id}") unless failed

          volumes  = stranded_volumes(failed)
          peers    = stranded_peers(failed)
          if dry_run
            return plan(failed, volumes, peers, reap, operation_id,
                        pool_id: pool_id, pool_name: pool_name)
          end

          # BOUNDS GATE NEW ACQUISITIONS ONLY. An operation whose acquire is
          # already on the ledger has consumed its pool capacity; refusing its
          # re-drive would strand a half-finished replace — volumes moved, VIP
          # not — for the rest of the window, which is the opposite of what a
          # safety bound is for. #in_flight? is the same ledger read the
          # acquire step itself uses, so the two cannot disagree.
          unless in_flight?(failed, operation_id)
            refusal = bounds_refusal
            return failure(refusal) if refusal
          end

          replayed = []
          failures = []

          # ONE TRANSACTION around the claim AND its ledger row. #acquire!
          # commits `pool_state: "claimed"` in a transaction of its own, so
          # without this an unrescued #record_step! would leave a member
          # claimed by an operation the ledger has never heard of — and the
          # next drive would claim a second. Nested here, the claim rolls back
          # with the failed write.
          acquired = ::ActiveRecord::Base.transaction do
            run_step("acquire_replacement", operation_id, replayed, failed: failed, reason: reason) do
              outcome = acquire_replacement!(failed: failed, pool_id: pool_id, pool_name: pool_name)
              if outcome.is_a?(Hash)
                outcome # a failure envelope — run_step returns it untouched and records nothing
              else
                { "replacement_instance_id" => outcome.id, "instance_pool_id" => outcome.instance_pool_id }
              end
            end
          end
          return acquired if acquired.is_a?(Hash) && acquired[:success] == false

          replacement = find_instance(acquired["replacement_instance_id"])
          unless replacement
            return failure("Replacement #{acquired['replacement_instance_id']} recorded for " \
                           "operation #{operation_id} is no longer in account scope")
          end

          volume_ids = run_step("reattach_volumes", operation_id, replayed, failed: failed, reason: reason) do
            moved, errs = reattach_volumes!(volumes: volumes, replacement: replacement)
            failures.concat(errs)
            { "reattached_volume_ids" => moved, "errors" => errs }
          end

          peer_map = run_step("reenrol_sdwan", operation_id, replayed, failed: failed, reason: reason) do
            enrolled, errs = reenrol_sdwan!(peers: peers, replacement: replacement)
            failures.concat(errs)
            { "peer_map" => enrolled, "errors" => errs }
          end

          # `clean:` IS THE FIX FOR THE ONE LEG THAT IS NOT SELF-HEALING. The
          # VIP move's input is the ENROL STEP'S RETURN VALUE, not a query: with
          # an empty peer map it moves nothing, reports no errors of its own,
          # and would be recorded as done. The re-drive that finally mints the
          # peers would then replay that empty move forever, leaving the VIP
          # pinned to a peer row that disappears with the reap.
          vip_ids = run_step("move_vips", operation_id, replayed, failed: failed, reason: reason,
                             clean: peer_map["recorded"] != false) do
            moved, errs = move_vips!(peer_map: peer_map["peer_map"] || {})
            failures.concat(errs)
            { "moved_virtual_ip_ids" => moved, "errors" => errs }
          end

          reap_outcome = reap ? request_reap(failed: failed, operation_id: operation_id, reason: reason) : no_reap

          success(
            failed_instance_id: failed.id,
            replacement_instance_id: replacement.id,
            reattached_volume_ids: Array(volume_ids["reattached_volume_ids"]),
            enrolled_peer_ids: Array((peer_map["peer_map"] || {}).values),
            moved_virtual_ip_ids: Array(vip_ids["moved_virtual_ip_ids"]),
            replayed_steps: replayed,
            failures: failures,
            partial: failures.any?,
            **reap_outcome
          )
        end

        # ── steps ──────────────────────────────────────────────────────────

        # Runs `step` unless a FleetEvent already records it for this
        # operation_id, in which case the recorded payload is REPLAYED (marked
        # with "replayed" => true so the caller can tell the two apart and so
        # the result names which steps did not re-run).
        #
        # Returns the step payload, or a failure envelope when the block
        # refuses — an acquire that finds no warm member has to stop the run,
        # not carry on reattaching volumes onto nothing.
        def run_step(step, operation_id, replayed, failed:, reason:, clean: true)
          prior = prior_event(step, operation_id, failed)
          if prior
            replayed << step
            return prior.payload.merge("replayed" => true)
          end

          payload = yield
          return payload if payload.is_a?(Hash) && payload[:success] == false

          # ONLY A CLEAN STEP GOES ON THE LEDGER. Recording a step that
          # partially failed would replay its empty result forever and make a
          # transient provider error permanent — the ledger's whole purpose is
          # a safe re-drive, and one that cannot repair anything is worse than
          # none. Leaving a failed step UNRECORDED is safe because each leg is
          # idempotent by its own query rather than by the ledger: a volume
          # already moved is no longer in #stranded_volumes, #reenrol_sdwan!
          # returns the peer it already minted for the replacement, and
          # #move_vips! skips a VIP with no old-peer id left to substitute. So
          # the retry touches exactly what is still stranded — EXCEPT the VIP
          # move, whose input is the previous step's output rather than a
          # query, which is what `clean:` carries: a step fed by an
          # unrecorded predecessor is itself unrecorded, however cleanly it
          # ran on the little it was given.
          if Array(payload["errors"]).any? || !clean
            return payload.merge("replayed" => false, "recorded" => false)
          end

          record_step!(step: step, operation_id: operation_id,
                       payload: payload.except("errors"), failed: failed, reason: reason)
          payload.merge("replayed" => false, "recorded" => true)
        end

        # True once this replace holds a replacement — under THIS operation_id
        # or an adopted one — i.e. we are re-driving, not starting.
        def in_flight?(failed, operation_id)
          prior_event("acquire_replacement", operation_id, failed).present?
        end

        # The recorded step for this operation, plus the one relaxation the
        # ledger needs: an ACQUIRE also matches on the failed instance.
        def prior_event(step, operation_id, failed)
          found = replayed_step(step, operation_id)
          return found if found
          return nil unless step == "acquire_replacement"

          adopted_acquisition(failed)
        end

        # A SECOND CLASSIFICATION OF THE SAME DEAD INSTANCE IS NOT A SECOND
        # REPLACE. The lane passes the signal fingerprint as the operation_id,
        # and InstanceUnrecoverableSensor builds that fingerprint as
        # "instance_unrecoverable:<id>:<reason>" from a reason it re-derives on
        # every tick — host_unreachable while the provider connection is down,
        # provider_terminal once it recovers and reports the VM gone. The
        # additive half deliberately leaves the failed instance alive, so it
        # stays in the sensor's population and WILL reclassify. Keyed on
        # operation_id alone, that new id finds no acquire, claims a second warm
        # member and leaks it: the run then finds no stranded volumes or peers
        # (the first replace moved them) and simply strands the member in
        # `claimed`. The bound caps the bleed at max_per_window; it does not
        # stop it.
        #
        # So an acquire is adopted when an earlier one names the same FAILED
        # instance and the replacement it named is still carrying the workload.
        # A replacement that has been returned to its pool (`ready` again) or
        # terminated is NOT adopted — there the fleet really is short an
        # instance and a fresh acquire is the correct answer.
        def adopted_acquisition(failed)
          ::System::FleetEvent
            .where(account_id: @account.id, kind: "#{EVENT_PREFIX}.acquire_replacement")
            .where("payload->>'failed_instance_id' = ?", failed.id.to_s)
            .order(emitted_at: :desc)
            .limit(ADOPTION_SCAN_LIMIT)
            .find { |event| replacement_still_serving?(event) }
        end

        def replacement_still_serving?(event)
          replacement = find_instance(event.payload["replacement_instance_id"])
          return false unless replacement
          return false if replacement.pool_state == "ready"

          !replacement.status.to_s.in?(%w[terminated terminating])
        end

        def acquire_replacement!(failed:, pool_id:, pool_name:)
          target_pool_id = pool_id.presence || (pool_name.blank? ? failed.instance_pool_id : nil)
          if target_pool_id.blank? && pool_name.blank?
            return failure(
              "No pool to draw a replacement from: #{failed.name} is not a pool member and " \
              "neither pool_id nor pool_name was given. DR needs warm capacity declared up front."
            )
          end

          ::System::InstancePoolService.acquire!(
            account: @account, pool_id: target_pool_id, pool_name: pool_name
          )
        rescue ::System::InstancePoolService::PoolError => e
          # PoolError is the BASE of the pool service's error family
          # (NoReadyMembers / PoolNotActive / PoolAtMaxCapacity /
          # InvalidPoolState) and #resolve_pool! raises the bare base class for
          # an unknown pool_id or name — rescuing only the leaves would let
          # "pool not found" escape as an uncaught exception.
          failure("Cannot replace #{failed.name}: #{e.message}")
        end

        # Volumes follow the workload. DETACH THEN ATTACH, in that order and
        # never the reverse: VolumeManagementService#attach refuses a volume
        # that is still `attached?`, so an attach-first pass would fail every
        # volume and leave the data pinned to a dead instance.
        def reattach_volumes!(volumes:, replacement:)
          moved  = []
          errors = []

          volumes.each do |volume|
            detach = ::System::VolumeManagementService.detach(volume: volume)
            unless detach.success?
              errors << { "step" => "detach_volume", "volume_id" => volume.id, "error" => detach.error }
              next
            end

            attach = ::System::VolumeManagementService.attach(volume: volume.reload, instance: replacement)
            if attach.success?
              moved << volume.id
            else
              errors << { "step" => "attach_volume", "volume_id" => volume.id, "error" => attach.error }
            end
          end

          [ moved, errors ]
        end

        # One new peer per network the failed instance held. Returns the
        # old-peer-id → new-peer-id map, which is what #move_vips! needs: a VIP
        # names PEERS, not instances, so the substitution cannot be done from
        # the instance ids alone.
        #
        # The failed instance's own peers are LEFT IN PLACE. Detaching them
        # here would drop the VIP holder rows this run is about to re-point
        # (Sdwan::PeerDetacher destroys the peer), and the peers go with the
        # instance when the reap is approved.
        def reenrol_sdwan!(peers:, replacement:)
          enrolled = {}
          errors   = []

          peers.each do |peer|
            network = peer.network
            next unless network

            existing = ::Sdwan::Peer.find_by(sdwan_network_id: network.id,
                                             node_instance_id: replacement.id)
            if existing
              enrolled[peer.id] = existing.id
              next
            end

            begin
              fresh = ::Sdwan::PeerEnroller.call(network: network, node_instance: replacement,
                                                 **inherited_peer_attributes(peer))
              enrolled[peer.id] = fresh.id
            rescue StandardError => e
              errors << { "step" => "enrol_peer", "network_id" => network.id,
                          "previous_peer_id" => peer.id, "error" => e.message }
            end
          end

          [ enrolled, errors ]
        end

        # THE REPLACEMENT INHERITS THE FAILED PEER'S ROUTING, not the schema
        # defaults. `PeerEnroller.call(network:, node_instance:)` with no
        # options mints a peer that is not publicly reachable, advertises no
        # LAN subnets, is not a route-reflector client and listens on 51820 —
        # so a hub silently becomes a spoke, a peer advertising a /24 stops
        # advertising it, and #move_vips! then points the VIP at that degraded
        # peer. "Re-enrol it on every network the failed one held" has to mean
        # the peer's ROLE, not just its membership.
        #
        # The ENDPOINT columns travel too, deliberately, even though they name
        # the dead instance's address: dropping them while keeping
        # publicly_reachable is a validation failure (Sdwan::Peer
        # #hub_must_have_endpoint), and dropping BOTH silently demotes a hub
        # every spoke on the network dials. An inherited endpoint is stale and
        # visible; a demoted hub is neither. #compact leaves an unset column
        # unset so the enroller's own default still applies.
        def inherited_peer_attributes(peer)
          {
            publicly_reachable: peer.publicly_reachable,
            bgp_route_reflector_client: peer.bgp_route_reflector_client,
            capabilities: peer.capabilities || {},
            lan_subnets: Array(peer.lan_subnets),
            endpoint_host: peer.endpoint_host,
            endpoint_host_v6: peer.endpoint_host_v6,
            endpoint_host_v4: peer.endpoint_host_v4,
            endpoint_port: peer.endpoint_port,
            listen_port: peer.listen_port
          }.compact
        end

        # SUBSTITUTION, not #failover!. failover! promotes a STANDBY off the
        # failover list and rotates the old head into it — the right move when
        # a live holder went silent and a designated backup exists. Here the
        # holder's INSTANCE is gone and its replacement is a different peer id
        # that was never on any failover list, so the correct write is to
        # replace the dead peer's id wherever it appears (holder set and
        # failover set alike) with the peer that inherited its workload.
        # Leaving the dead id in place would keep the VIP pinned to a peer row
        # that disappears with the reap.
        def move_vips!(peer_map:)
          moved  = []
          errors = []
          return [ moved, errors ] if peer_map.blank?

          ::Sdwan::VirtualIp.where(account_id: @account.id).find_each do |vip|
            holders  = Array(vip.holder_peer_ids)
            standbys = Array(vip.failover_holder_peer_ids)
            next if (holders + standbys).intersection(peer_map.keys).empty?

            vip.holder_peer_ids          = holders.map  { |id| peer_map[id] || id }.uniq
            vip.failover_holder_peer_ids = standbys.map { |id| peer_map[id] || id }.uniq

            if vip.save
              moved << vip.id
            else
              errors << { "step" => "move_vip", "virtual_ip_id" => vip.id,
                          "error" => vip.errors.full_messages.join("; ") }
            end
          end

          [ moved, errors ]
        end

        # ── the reap, gated on its own category ────────────────────────────

        def no_reap
          { reaped: false, reap_requested: false, reap_decision: "not_requested" }
        end

        # Hands the terminate to Ai::AutonomyGate under REAP_ACTION_CATEGORY,
        # naming ReapInstanceExecutor — NOT this class. The gate parks a
        # durable, resumable row on require_approval and replays THAT executor
        # when a person releases it, so the terminate is gated on
        # system.instance_reap on every path including the auto-execute one.
        # An auto-execute verdict runs the replay inline, which is the only
        # path on which this method returns reaped: true.
        def request_reap(failed:, operation_id:, reason:)
          result = ::Ai::AutonomyGate.evaluate(
            action_category: REAP_ACTION_CATEGORY,
            executor_class: ReapInstanceExecutor.name,
            params: { instance_id: failed.id, operation_id: operation_id, reason: reason },
            account: @account,
            agent: @agent,
            requested_by: @user,
            source_type: "System::NodeInstance",
            source_id: failed.id,
            description: "Terminate unrecoverable instance #{failed.name} after its workload " \
                         "moved to a pooled replacement"
          )

          case result.decision
          when :proceed
            { reaped: result.result.is_a?(Hash) ? result.result[:success] == true : false,
              reap_requested: true, reap_decision: "proceed" }
          when :pending
            { reaped: false, reap_requested: true, reap_decision: "pending",
              reap_approval_request_id: result.approval_request&.id,
              reap_deferred_operation_id: result.deferred_operation&.id }
          else
            { reaped: false, reap_requested: true, reap_decision: "blocked",
              reap_error: result.error }
          end
        end

        # ── lookups, plan and bounds ───────────────────────────────────────

        def stranded_volumes(failed)
          ::System::ProviderVolume.where(account_id: @account.id, node_instance_id: failed.id).to_a
        end

        def stranded_peers(failed)
          ::Sdwan::Peer.where(account_id: @account.id, node_instance_id: failed.id)
                       .includes(:network).to_a
        end

        # The PREVIEW System::Fleet::DecisionEngine stamps onto the approval
        # request (`dry_run_supported` on the binding). It must be a SUCCESS —
        # skill_metadata_payload reads `skill_result[:data]`, which #failure
        # does not carry, so a failure here would park a card that says nothing
        # about what is going to happen.
        def plan(failed, volumes, peers, reap, operation_id, pool_id: nil, pool_name: nil)
          # THE PREVIEW MUST ANSWER "CAN THIS RUN AT ALL". A plan that lists
          # volumes and VIPs while staying silent about whether any warm member
          # exists is the shape an operator approves and then watches fail at
          # its first step. The pool and its ready count are therefore resolved
          # HERE, read-only, and a pool that cannot supply a replacement is
          # reported as `blocked` in the plan — the same "refusal rides in the
          # preview" shape SdwanVipFailoverExecutor's dry_run branch uses,
          # rather than a #failure that would park a card carrying no data.
          pool  = resolve_pool_for_plan(failed, pool_id, pool_name)
          ready = pool&.node_instances&.where(pool_state: "ready")&.count

          # THE BOUND IS A REFUSAL LIKE ANY OTHER, and the preview has to name
          # it. A plan that describes the volumes and VIPs while the live run
          # is going to stop at #bounds_refusal is exactly the card an operator
          # approves and then watches fail at its first step. Gated on
          # #in_flight? the same way the live path is, so an in-flight
          # operation previews as runnable — because it is.
          bound = in_flight?(failed, operation_id) ? nil : bounds_refusal

          blocked_note =
            if bound
              bound
            elsif pool.nil?
              "No pool resolved: #{failed.name} is not a pool member and neither pool_id nor " \
              "pool_name was given. DR needs warm capacity declared up front."
            elsif !pool.active?
              "Pool '#{pool.name}' is #{pool.status} — a draining pool never hands out members."
            elsif ready.to_i.zero?
              "Pool '#{pool.name}' has no ready members (target=#{pool.target_size}); " \
              "the reaper must replenish it before this replace can run."
            end

          success(
            dry_run: true,
            failed_instance_id: failed.id,
            failed_instance_name: failed.name,
            instance_pool_id: failed.instance_pool_id,
            pool_id: pool&.id,
            pool_name: pool&.name,
            pool_ready_count: ready.to_i,
            blocked: blocked_note.present?,
            would_reattach_volume_ids: volumes.map(&:id),
            would_reenrol_network_ids: peers.filter_map { |p| p.network&.id }.uniq,
            would_move_virtual_ip_ids: planned_vip_ids(peers),
            reap_requested: reap == true,
            reap_action_category: REAP_ACTION_CATEGORY,
            note: blocked_note.presence ||
                  "The terminate of #{failed.name} is a SEPARATE approval on " \
                  "#{REAP_ACTION_CATEGORY}; approving this replace moves the workload only."
          )
        end

        # Read-only pool resolution for the preview. Deliberately NOT
        # InstancePoolService#resolve_pool!, which RAISES for an unknown pool
        # and has a lifecycle_class fallback the executor does not use: a
        # preview must describe the situation, including "there is no pool",
        # rather than blow up inside the plan the approval card is built from.
        def resolve_pool_for_plan(failed, pool_id, pool_name)
          scope = ::System::InstancePool.where(account_id: @account.id)
          return scope.find_by(id: pool_id) if pool_id.present?
          return scope.find_by(name: pool_name) if pool_name.present?
          return nil if failed.instance_pool_id.blank?

          scope.find_by(id: failed.instance_pool_id)
        end

        def planned_vip_ids(peers)
          peer_ids = peers.map(&:id)
          return [] if peer_ids.empty?

          ::Sdwan::VirtualIp.where(account_id: @account.id).select do |vip|
            (Array(vip.holder_peer_ids) + Array(vip.failover_holder_peer_ids))
              .intersection(peer_ids).any?
          end.map(&:id)
        end

        # Refuses the additive half once this account has already replaced
        # `max_per_window` instances inside the window. Counted off the
        # acquire events, which is the step that actually consumes pool
        # capacity — counting completed replaces would let a run that fails
        # after the acquire consume a member without counting against the bound.
        def bounds_refusal
          max    = positive_setting(MAX_PER_WINDOW_SETTING, DEFAULT_MAX_PER_WINDOW)
          window = positive_setting(WINDOW_MINUTES_SETTING, DEFAULT_WINDOW_MINUTES)

          recent = ::System::FleetEvent
                     .where(account_id: @account.id, kind: "#{EVENT_PREFIX}.acquire_replacement")
                     .where("emitted_at >= ?", window.minutes.ago)
                     .count
          return nil if recent < max

          "Replacement bound reached: #{recent} instances already replaced in the last " \
          "#{window} minutes (limit #{max}, SiteSetting #{MAX_PER_WINDOW_SETTING}). " \
          "Refusing rather than walking the pool — investigate whether the fleet is " \
          "genuinely losing instances before raising the bound."
        end

        # DB-resolved with a constant fallback. A missing, non-numeric or
        # non-positive override falls back rather than being taken literally:
        # a 0 here would refuse every replacement and silently disable DR.
        def positive_setting(key, default)
          raw = defined?(::SiteSetting) ? ::SiteSetting.get(key) : nil
          value = Integer(raw.to_s, exception: false)
          value&.positive? ? value : default
        rescue StandardError
          default
        end
      end
    end
  end
end
