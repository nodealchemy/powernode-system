# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Adaptive evolution skill — relocate a project's workload from one
      # region to another. Two strategies:
      #
      #   blue_green — provision the full target stack first, then terminate
      #                source instances (zero overlap downtime; double-spend
      #                during cutover window)
      #   drain      — terminate source instances *first* (workload-aware
      #                drain), then provision target. Cheaper but with a
      #                gap window between teardown and bring-up. v0 issues
      #                terminate sequentially in source order.
      #
      # ONE readiness predicate (#cutover_refusal_reasons — undersized /
      # off-fabric / storage-unready), TWO dispositions, because the two
      # strategies differ in where the workload lives when it trips
      # (IMP-49b3e42d9423):
      #
      #   blue_green — the predicate GATES the teardown. The sources still
      #                hold the workload, so the refused target stack is
      #                reclaimed and the sources are left untouched.
      #   drain      — the predicate cannot gate anything: the sources are
      #                already gone by the time a target exists to measure.
      #                It gates the OUTCOME REPORT instead — the run fails
      #                rather than reporting success over a fleet that cannot
      #                serve — and the degraded stack is RETAINED, because it
      #                is the only live capacity left to retain.
      #
      # Composes:
      #   - ProvisionFullStackExecutor (target region) for the new stack
      #   - System::ProvisioningService.terminate_instance for source teardown
      #
      # Returns the standard {dry_run, count, planned_actions, outputs,
      # failures, partial} envelope. Outputs additionally surface
      # `terminated_instance_ids` so observability + rollback know which
      # source instances were torn down.
      #
      # Reference: AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
      class RelocateWorkloadExecutor < BaseSkillExecutor
        STRATEGIES = %w[blue_green drain].freeze
        MAX_COUNT  = 50

        skill_descriptor(
          name: "relocate_workload",
          description: "Relocate a project's compute workload from one region to another via blue/green or drain cutover. Composes ProvisionFullStackExecutor (target) + ProvisioningService.terminate_instance (source).",
          category: "devops",
          inputs: {
            project_id: { type: "string", required: true,
                          description: "Ai::Mission id (the provisioning project being relocated)" },
            from_region_id: { type: "string", required: true,
                              description: "System::ProviderRegion the workload is leaving (audit hint, no lookup)" },
            to_region_id: { type: "string", required: true,
                            description: "System::ProviderRegion the workload is moving to (target for new stack)" },
            cutover_strategy: { type: "string", required: true,
                                description: "One of: #{STRATEGIES.join(', ')}" },
            template_id: { type: "string", required: true,
                           description: "System::NodeTemplate to instantiate at the target region" },
            provider_instance_type_id: { type: "string", required: true,
                                         description: "Instance type for the target stack" },
            count: { type: "integer", required: true,
                     description: "Number of new instances to bring up at the target (1-#{MAX_COUNT})" },
            source_instance_ids: { type: "array", required: true,
                                   description: "System::NodeInstance ids in the source region to terminate during cutover" },
            network_id: { type: "string", required: false,
                          description: "Sdwan::Network — when present, target instances are wired into the SDWAN topology and peer ids returned" },
            with_storage_gb: { type: "integer", required: false,
                               description: "When present, provision a per-instance ProviderVolume of this size at the target" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — return projected actions without provisioning or terminating" }
          },
          outputs: {
            dry_run: :boolean,
            count: :integer,
            cutover_strategy: :string,
            planned_actions: [ :object ],
            outputs: {
              node_ids: [ :string ],
              node_instance_ids: [ :string ],
              sdwan_peer_ids: [ :string ],
              storage_volume_ids: [ :string ],
              terminated_instance_ids: [ :string ]
            },
            failures: [ :object ],
            partial: :boolean
          },
          requires_approval: true,
          rollback: :rollback_relocate_workload,
          blast_radius: :high
        )

        binds_to "capacity_manager"

        # Rollback contract: detach-and-delete the volumes provisioned for the
        # *new* (target-region) instances, then terminate those instances (see
        # the ordering note below). The source instances may
        # already be gone — we cannot un-terminate them — so they are not
        # in this kwargs-set. This is best-effort: a failed relocation
        # should be re-driven manually after rollback.
        def rollback_relocate_workload(node_instance_ids: [], storage_volume_ids: [],
                                       sdwan_peer_ids: [], **_extras)
          errors = []

          # VOLUMES BEFORE INSTANCES, detach-then-delete (IMP-093378034fb4).
          # These ids come straight from ProvisionFullStackExecutor's envelope
          # and relocate composes that executor WITH with_storage_gb, so the
          # volumes arrive ATTACHED. `VolumeManagementService#delete` refuses an
          # attached volume outright, and detaching one whose instance has
          # already been terminated asks the provider to detach from a machine
          # it no longer has. Terminate-first therefore failed every volume
          # with "Volume is attached, detach first" and left the row alive.
          # Same shape as ProvisionFullStackExecutor#rollback_provision_full_stack
          # and ScaleProjectExecutor#teardown_resources.
          Array(storage_volume_ids).reverse_each do |volume_id|
            volume = ::System::ProviderVolume.find_by(id: volume_id)
            next unless volume

            if volume.attached?
              detach = ::System::VolumeManagementService.detach(volume: volume)
              unless detach.success?
                errors << { resource: "provider_volume", id: volume_id, error: detach.error }
                next
              end
            end

            result = ::System::VolumeManagementService.delete(volume: volume)
            errors << { resource: "provider_volume", id: volume_id, error: result.error } unless result.success?
          rescue StandardError => e
            errors << { resource: "provider_volume", id: volume_id, error: e.message }
          end

          Array(node_instance_ids).reverse_each do |instance_id|
            instance = ::System::NodeInstance.find_by(id: instance_id)
            next unless instance

            result = ::System::ProvisioningService.terminate_instance(instance: instance)
            errors << { resource: "node_instance", id: instance_id, error: result.error } unless result.success?
          rescue StandardError => e
            errors << { resource: "node_instance", id: instance_id, error: e.message }
          end

          # IMP-94f778f92dba — these are now peers the target provisioning
          # actually enrolled (they used to be a read-back of the network's
          # pre-existing fleet, which is why this was a no-op). "Released when
          # the host instance is terminated" holds only when the terminate
          # SUCCEEDS: the auto-detach lives in
          # ProvisioningService#finalize_termination!, and five of
          # terminate_instance's exits never reach it — four return Result.err
          # and the fifth re-raises. Detach explicitly rather than assume.
          Array(sdwan_peer_ids).reverse_each do |peer_id|
            peer = ::Sdwan::Peer.where(account_id: @account.id).find_by(id: peer_id)
            next unless peer

            ::Sdwan::PeerDetacher.call(node_instance: peer.node_instance, network: peer.network)
          rescue StandardError => e
            errors << { resource: "sdwan_peer", id: peer_id, error: e.message }
          end

          { success: errors.empty?, errors: errors }
        end

        protected

        def perform(project_id:, from_region_id:, to_region_id:, cutover_strategy:,
                    template_id:, provider_instance_type_id:, count:, source_instance_ids:,
                    network_id: nil, with_storage_gb: nil, storage_gb: nil,
                    dry_run: false, **_extras)
          # IMP-01a774a80f7a — the ONE resolution site for this run's storage
          # declaration, and everything below reads its result: the approval
          # card (#build_plan), the cutover guard (#cutover_refusal_reasons) and the
          # forward to the executor that actually buys the disk
          # (#provision_target!). The inner executor tolerates `storage_gb` as
          # an alias and CostEstimatorService#declared_gb prices it, but this
          # executor declared no such keyword, so a declaration made under that
          # name landed in `**_extras` and was discarded — and because
          # `provision_target!` forwards only `with_storage_gb:`, the inner
          # executor was asked for nothing. Verified by execution before this
          # parameter existed: `storage_gb: 500` on a blue_green relocate
          # provisioned no volume, planned no storage steps, recorded NO
          # failure entry and disclosed no refusal clause, so the guard read
          # `storage_declared?(nil)` — false — skipped the storage arm and
          # TERMINATED the sources against a target with no disk, returning
          # success(partial: false) with an empty failures array and no
          # execution event. That is IMP-e1903a42c1ab's data loss through a
          # third input shape, and strictly worse than the unreadable one,
          # which at least leaves a provision_storage failure per node.
          #
          # Resolution is ProvisionFullStackExecutor's own (class scope), not a
          # copy: a re-derived order here is the card/actuator disagreement the
          # published reader exists to prevent, and this executor forwards the
          # resolved value on to that same reader, which re-resolves it
          # idempotently.
          with_storage_gb = ::System::Ai::Skills::ProvisionFullStackExecutor
                            .resolve_storage_gb(with_storage_gb, storage_gb)

          # REFUSED AT THE DOOR (IMP-f5532c5c5bd6), beside the other parameter
          # validations rather than deep in the run.
          #
          # ProvisionFullStackExecutor previews this input as failures because
          # its own comment refuses to let "a declaration the real run would
          # record failure entries for ... preview as a clean plan". Relocate
          # never composes PFSE for its preview — it builds its own plan — so
          # the operator's :high blast-radius card showed the storage steps
          # absent, a conditional storage-unready clause about a volume that
          # appears nowhere in the plan, and ZERO failures.
          #
          # WHY REFUSE RATHER THAN RECORD-AND-CONTINUE, since PFSE deliberately
          # chose the latter: the two executors end differently for this input.
          # PFSE's contract is to provision what it can and report per-node
          # failures, so continuing is useful there. Relocate's END STATE for an
          # unreadable declaration is already a refusal — the storage arm of
          # #cutover_refusal_reasons refuses it, the targets are reclaimed and the sources are
          # left alive (pinned by "refuses every declared-but-unreadable storage
          # shape"). Continuing therefore buys nothing and costs a full
          # provision-and-reclaim cycle for an input diagnosable before any work
          # starts. Nothing depended on the tolerance: no caller reaches a
          # SUCCESSFUL relocate with this value today.
          #
          # storage_unreadable? rather than !storage_requested?: a value that is
          # simply absent is a legitimate no-storage relocate, and only a
          # DECLARED value that cannot be read is an error. The message must not
          # quote a size — with_storage_gb.to_i renders an authoritative "0 GB"
          # for a value that was never read.
          if storage_unreadable?(with_storage_gb)
            return failure(
              "storage declared but unreadable: #{with_storage_gb.inspect.truncate(120)} — " \
              "with_storage_gb must be a positive integer count of GB"
            )
          end

          strategy = cutover_strategy.to_s
          return failure("cutover_strategy must be one of: #{STRATEGIES.join(', ')}") unless STRATEGIES.include?(strategy)

          count = count.to_i
          return failure("count must be between 1 and #{MAX_COUNT}") unless count.between?(1, MAX_COUNT)

          source_ids = Array(source_instance_ids).map(&:to_s).reject(&:empty?)
          return failure("source_instance_ids must contain at least one id") if source_ids.empty?

          mission = ::Ai::Mission.where(account_id: @account.id).find_by(id: project_id)
          return failure("project not found: #{project_id}") unless mission

          if dry_run
            return success(
              dry_run: true,
              count: count,
              cutover_strategy: strategy,
              planned_actions: build_plan(strategy: strategy, count: count,
                                          source_ids: source_ids,
                                          template_id: template_id,
                                          to_region_id: to_region_id,
                                          provider_instance_type_id: provider_instance_type_id,
                                          network_id: network_id,
                                          with_storage_gb: with_storage_gb),
              outputs: empty_outputs,
              failures: [],
              partial: false
            )
          end

          run_execute(strategy: strategy, count: count, source_ids: source_ids,
                      template_id: template_id, to_region_id: to_region_id,
                      provider_instance_type_id: provider_instance_type_id,
                      network_id: network_id, with_storage_gb: with_storage_gb,
                      mission: mission)
        end

        private

        def run_execute(strategy:, count:, source_ids:, template_id:, to_region_id:,
                        provider_instance_type_id:, network_id:, with_storage_gb:, mission:)
          planned_actions = [ { step: "relocate_workload", cutover_strategy: strategy,
                                source_count: source_ids.size, target_count: count } ]
          terminated = []
          failures = []
          provision_data = nil
          # IMP-5eb14352370a — out-param, same idiom as `failures` and
          # `planned_actions` above: what the inner target provisioning had
          # already created when it failed WHOLESALE (see #provision_target!).
          # Empty on every other path.
          orphaned = {}

          if strategy == "drain"
            # DRAIN'S SAFETY POSTURE, stated explicitly because iteration 275
            # left it neither guarded nor argued (IMP-49b3e42d9423).
            #
            # A pre-terminate readiness guard is STRUCTURALLY IMPOSSIBLE here,
            # and that is not a judgement — it is the ordering: the terminate
            # below runs before `provision_target!`, so at the moment the
            # sources are destroyed there is no target to measure. The
            # operator approves that ordering when they choose drain ("cheaper
            # but with a gap window"), and the approval card says so.
            #
            # What they do NOT approve is the run reporting SUCCESS when the
            # target it then brought up cannot carry the workload. Verified by
            # execution before the guard below existed: with count: 2 and a
            # network and storage declared, each of the three degradation arms
            # driven separately (1-of-2 instances / 1-of-2 peers / 0-of-2
            # volumes attached) returned `success: true, partial: true` with
            # the degradation visible only as an entry in `failures`, and in
            # every arm the first provider call of the run was
            # terminate_instance on the source.
            #
            # That envelope is acted on, not merely displayed:
            # SkillCompositionRunner#execute_step! branches on
            # `result_success?` and ignores `partial` entirely, so it marks the
            # step COMPLETED, dispatches successors and advances the mission
            # past a fleet that no longer serves. `partial` cannot stand in for
            # the guard either — a source whose terminate merely errored sets
            # it too, on a run that delivered a perfectly healthy target. The
            # predicate has to ask about the TARGET.
            terminate_step!(source_ids: source_ids, terminated: terminated,
                            failures: failures, planned_actions: planned_actions)

            provision_data = provision_target!(template_id: template_id,
                                               count: count, to_region_id: to_region_id,
                                               provider_instance_type_id: provider_instance_type_id,
                                               network_id: network_id, with_storage_gb: with_storage_gb,
                                               failures: failures, planned_actions: planned_actions,
                                               mission: mission, orphaned: orphaned)

            # THE SAME three-arm predicate blue_green gates on, in the same
            # words — one #cutover_refusal_reasons, so the two strategies can
            # never drift on what "ready" means.
            reasons = cutover_refusal_reasons(
              outputs: provision_data.is_a?(Hash) ? (provision_data[:outputs] || {}) : {},
              count: count, network_id: network_id, with_storage_gb: with_storage_gb
            )

            if reasons.any?
              return refuse_drain_outcome!(
                mission: mission, reasons: reasons, terminated: terminated,
                planned_actions: planned_actions,
                provision_data: provision_data, step_failures: failures,
                orphaned_outputs: orphaned
              )
            end
          else # blue_green
            provision_data = provision_target!(template_id: template_id,
                                               count: count, to_region_id: to_region_id,
                                               provider_instance_type_id: provider_instance_type_id,
                                               network_id: network_id, with_storage_gb: with_storage_gb,
                                               failures: failures, planned_actions: planned_actions,
                                               mission: mission, orphaned: orphaned)

            # Only tear down the source if we actually have a healthy target.
            #
            # IMP-94f778f92dba — "healthy" has to include the fabric.
            #
            # This gap is PRE-EXISTING, not something the enrollment change
            # introduced: the old network leg called compile_for_network,
            # which maps the network's existing peers and enrols nothing, so
            # every blue/green relocate with a network_id already terminated
            # the source while the targets sat off-fabric — and it reported
            # success, because a leg that does nothing cannot fail. The bare
            # instance-count check has never covered the network leg.
            #
            # What changed is that the failure is now KNOWABLE: attach_sdwan_peer
            # entries are real data this executor can gate on. Reading them
            # here is the whole point of producing them.
            #
            # IMP-bb73f7154f27 — "healthy" has to include the SIZE, too: the
            # old empty-check let a 1-of-2 shortfall through, terminating
            # every source against half the requested capacity. Undersized
            # (which subsumes empty) and off-fabric are one guard with one
            # refusal shape.
            #
            # IMP-e1903a42c1ab — and it has to include the STORAGE, because
            # this executor composes THREE legs and the readiness predicate
            # covered two. blue_green exists to move a workload, and until the
            # target is serving, the SOURCES hold the only copy of the data —
            # so a target whose data volume never attached is "not ready" in
            # precisely the sense the other two arms refuse, and worse for a
            # data-bearing workload. Verified by execution before this arm
            # existed: a failing volume attach left undersized=false and
            # off_fabric=false, the guard passed, the sources were terminated,
            # and the run reported success(partial: true).
            #
            # IMP-49b3e42d9423 — the three arms now live in ONE
            # #cutover_refusal_reasons, which both strategies gate on and both
            # refusals quote. The guard used to compute three booleans here and
            # #refuse_blue_green_cutover! re-derived the matching reason strings
            # from the same inputs a few lines later: two mechanisms for one
            # property, free to drift, and the drain branch could not reuse
            # either without copying both.
            reasons = cutover_refusal_reasons(
              outputs: provision_data.is_a?(Hash) ? (provision_data[:outputs] || {}) : {},
              count: count, network_id: network_id, with_storage_gb: with_storage_gb
            )

            if reasons.any?
              # IMP-6b497651d670 — every refusal is a FAILURE with an
              # in-branch reclaim, not a success(partial: true): see
              # #refuse_blue_green_cutover! for why neither standard envelope
              # shape can delegate the reclaim to the runner.
              return refuse_blue_green_cutover!(
                mission: mission, network_id: network_id, count: count,
                reasons: reasons,
                provision_data: provision_data, step_failures: failures,
                orphaned_outputs: orphaned
              )
            else
              terminate_step!(source_ids: source_ids, terminated: terminated,
                              failures: failures, planned_actions: planned_actions)
            end
          end

          # `provision_data` is non-nil by construction from here on: a
          # WHOLESALE inner failure returns nil, which makes the delivered
          # outputs empty, which makes #cutover_refusal_reasons say "target
          # stack is empty" — and BOTH strategies now return a refusal above
          # on that. So this success envelope is only ever built over a real
          # inner envelope (IMP-49b3e42d9423).
          #
          # IMP-5eb14352370a's out-param survives that change and is still
          # load-bearing — it is just consumed one level up now. Its rationale
          # said the orphans had to ride THIS envelope's outputs so a later
          # rollback and ProjectSloSensor's replica_count could reach them,
          # which was true while drain reported success(partial: true) on a
          # wholesale failure. That path is now a refusal, so the orphan ids
          # are consumed by #refuse_drain_outcome! (recorded as RETAINED) and
          # by #refuse_blue_green_cutover! (reclaimed as debris) instead. See
          # #refuse_drain_outcome! for what that costs replica_count.
          provision_outputs = provision_data[:outputs] || {}
          # The inner executor reports per-leg failures in its own envelope and
          # keeps going; dropping them here left an enrollment or volume error
          # with nowhere to surface — the runner records only what we return.
          failures.concat(Array(provision_data[:failures]))

          success(
            dry_run: false,
            count: count,
            cutover_strategy: strategy,
            planned_actions: planned_actions,
            outputs: {
              node_ids: Array(provision_outputs[:node_ids]),
              node_instance_ids: Array(provision_outputs[:node_instance_ids]),
              sdwan_peer_ids: Array(provision_outputs[:sdwan_peer_ids]),
              storage_volume_ids: Array(provision_outputs[:storage_volume_ids]),
              terminated_instance_ids: terminated
            },
            failures: failures,
            partial: failures.any?
          )
        end

        # IMP-6b497651d670 — a blue_green refusal (undersized OR off-fabric
        # target stack) reclaims the refused targets itself, then reports
        # failure. Neither standard envelope could hand the reclaim to the
        # runner:
        #
        #   - success(partial: true) abandoned the entire stack (VMs + volumes
        #     + enrolled peers, unowned): SkillCompositionRunner reaches
        #     rollback_step! only from handle_failure, so a completed-partial
        #     step never dispatches the rollback that holds these ids. STILL
        #     TRUE — this is a property of the runner's control flow, not of
        #     the envelope.
        #   - a bare failure(...) reclaimed nothing either: the runner's
        #     rollback kwargs came from metadata["last_outputs"], which only
        #     mark_completed writes, so on a first-run failure the hook fired
        #     with empty kwargs, no-opped, and stamped rolled_back over live
        #     resources. NO LONGER TRUE as of IMP-1ee509d12a0a (runner half)
        #     + IMP-2182fd8fcdee (executor half): handle_failure now records
        #     the failing envelope's own outputs into
        #     metadata["failure_outputs"], rollback_step! prefers them, and
        #     this executor hands its survivors up on the failure envelope
        #     (see the survivor_kwargs below).
        #
        # The reclaim still runs HERE, and deliberately so — but as
        # BELT-AND-BRACES now rather than because the seam is unavailable.
        # Reclaiming in-branch keeps the refusal self-contained: it does not
        # depend on the composer having stamped on_failure: "rollback", which
        # is a default a plan author can override. It reuses the rollback
        # contract this executor already owns. That contract is target-only by construction:
        # its kwargs are the ids from the target provisioning envelope, and
        # the sources are not in its kwargs-set (terminated_instance_ids is
        # swallowed by **_extras) — so a refused cutover can never reach the
        # workload it declined to tear down. If the runner rolls back again
        # after this failure (composers stamp on_failure: "rollback" by
        # default), the hook is idempotent: every id it re-resolves is
        # already gone. The System::Node shells are deliberately NOT
        # reclaimed — they stay for inspection, the same rationale as
        # ProvisionFullStackExecutor's rollback.
        def refuse_blue_green_cutover!(mission:, network_id:, count:, reasons:,
                                       provision_data:, step_failures:, orphaned_outputs:)
          outputs     = provision_data.is_a?(Hash) ? (provision_data[:outputs] || {}) : {}
          node_ids    = Array(outputs[:node_ids])
          target_ids  = Array(outputs[:node_instance_ids])
          volume_ids  = Array(outputs[:storage_volume_ids])
          peer_ids    = Array(outputs[:sdwan_peer_ids])

          # IMP-5eb14352370a — a WHOLESALE inner failure returns no envelope at
          # all, so the four sets above are empty even when the inner run had
          # created real rows for the earlier targets. Those rows are this
          # operation's own debris (#provision_target! sources them from the
          # inner executor instance this call built), and they are exactly what
          # this branch exists to reclaim. They are DELIBERATELY kept out of the
          # readiness sets above: `reasons` describes what was DELIVERED, and a
          # raise delivered nothing — so "target stack is empty" stays the
          # refusal, unchanged, while the debris gets torn down instead of
          # billing forever with its ids recorded nowhere.
          orphan_node_ids   = Array(orphaned_outputs[:node_ids])
          orphan_target_ids = Array(orphaned_outputs[:node_instance_ids])
          orphan_volume_ids = Array(orphaned_outputs[:storage_volume_ids])
          orphan_peer_ids   = Array(orphaned_outputs[:sdwan_peer_ids])

          reclaim_target_ids = target_ids | orphan_target_ids
          reclaim_volume_ids = volume_ids | orphan_volume_ids
          reclaim_peer_ids   = peer_ids   | orphan_peer_ids

          # `reasons` arrives from #run_execute's guard, computed BEFORE the
          # reclaim below — which detaches and deletes the very rows the
          # storage arm reads (IMP-e1903a42c1ab). Re-deriving them here would
          # read a stack this method has already torn down.

          # The inner executor's own leg failures — the REASON the stack is
          # refused. step_failures covers the provision_data-nil shape (a
          # whole-step inner failure lands in run_execute's local failures,
          # not in an inner envelope).
          leg_failures = Array(step_failures) + (provision_data.is_a?(Hash) ? Array(provision_data[:failures]) : [])

          reclaim = rollback_relocate_workload(
            node_instance_ids: reclaim_target_ids,
            storage_volume_ids: reclaim_volume_ids,
            sdwan_peer_ids: reclaim_peer_ids
          )
          reclaim_errors = Array(reclaim[:errors])

          # Per-class truth: an id that errored during reclaim SURVIVES —
          # billing, still on the provider — and everything else attempted is
          # reclaimed (ids that no longer resolved were already gone).
          survivors = {
            "node_instance"   => reclaim_errors.select { |e| e[:resource] == "node_instance" }.map { |e| e[:id] },
            "provider_volume" => reclaim_errors.select { |e| e[:resource] == "provider_volume" }.map { |e| e[:id] },
            "sdwan_peer"      => reclaim_errors.select { |e| e[:resource] == "sdwan_peer" }.map { |e| e[:id] }
          }
          reclaimed = {
            "node_instance"   => reclaim_target_ids - survivors["node_instance"],
            "provider_volume" => reclaim_volume_ids - survivors["provider_volume"],
            "sdwan_peer"      => reclaim_peer_ids - survivors["sdwan_peer"]
          }

          # Machine-readable diagnosis, durable on purpose: composers stamp
          # on_failure: "rollback" by default, so after this failure returns
          # the runner rolls back and mark_rolled_back OVERWRITES the step's
          # result_summary. The human message below does not survive that;
          # this event does. Recorder self-rescues, so it can never turn a
          # refusal into a raise.
          #
          # The parenthetical this comment used to carry — "a no-op,
          # recorded_outputs_for is empty on a first-run failure" — is no
          # longer true (IMP-1ee509d12a0a + IMP-2182fd8fcdee): the rollback
          # now receives this executor's survivors. That makes the event MORE
          # load-bearing, not less. The overwrite of result_summary is what
          # destroys the diagnosis, and it happens whether the rollback did
          # something or nothing.
          ::Ai::Introspection::ExecutionEventRecorder.record(
            source: mission,
            event_type: "relocate_cutover_refusal",
            status: reclaim[:success] ? "target_stack_reclaimed" : "reclaim_incomplete",
            metadata: {
              cutover_strategy: "blue_green",
              refusal_reasons: reasons,
              network_id: network_id,
              requested_count: count,
              node_ids_left_for_inspection: node_ids | orphan_node_ids,
              reclaimed: reclaimed,
              survivors: survivors,
              reclaim_errors: reclaim_errors,
              provisioning_leg_failures: leg_failures
            }.compact
          )

          message = "blue_green cutover refused: #{reasons.join('; ')}; source instances not terminated"

          # The failure envelope carries no failures array, so the leg
          # failures ride in the message too (bounded; the event above is the
          # complete record) — the runner records only what we return.
          message += "; provisioning-leg failures: #{summarize_entries(leg_failures)}" if leg_failures.any?

          message += if reclaim[:success]
            "; refused target stack reclaimed"
          else
            "; refused target stack reclaim INCOMPLETE: #{summarize_entries(reclaim_errors)}"
          end

          # IMP-2182fd8fcdee — hand the SURVIVORS to the runner's failure-time
          # rollback seam, keyed by rollback_relocate_workload's own kwarg
          # names. The durable event above records them for a human, but the
          # runner cannot act on an event: composers stamp on_failure:
          # "rollback" by default, so rollback_step! runs next and reads its
          # kwargs off this envelope. Returning a bare failure here rolled back
          # nothing and then stamped `rolled_back` over resources that are
          # still live and billing — the exact state the note above describes
          # as "a no-op".
          #
          # Only classes that ACTUALLY have survivors are included. An outputs
          # hash that is "present" while holding no ids displaces a retried
          # step's genuine last_outputs and fakes compensation in one move —
          # the runner's own failure_outputs_from warns about this shape. A
          # clean reclaim therefore still returns a bare failure, which is
          # correct: there is nothing left to compensate.
          survivor_kwargs = {
            node_instance_ids: survivors["node_instance"],
            storage_volume_ids: survivors["provider_volume"],
            sdwan_peer_ids: survivors["sdwan_peer"]
          }.reject { |_key, ids| ids.blank? }

          failure(message, **survivor_kwargs)
        end

        # IMP-e1903a42c1ab — the storage leg's readiness oracle is ATTACHMENT,
        # not the id count, and that distinction is the whole finding: the
        # inner executor pushes a volume id onto `storage_volume_ids` BEFORE
        # it attempts the attach (ProvisionFullStackExecutor#run_execute), so
        # a failed attach yields full count parity over a volume whose
        # `node_instance_id` is nil. A `volume_ids.size < target_ids.size`
        # check — the shape the other two arms use — would refuse the
        # provision-failure case and wave the attach-failure case through,
        # which is the more insidious of the two: the volume exists, it bills,
        # and nothing on the target can read it.
        #
        # Scoped to THIS run's volumes AND this run's targets: a volume
        # attached to something else is not this stack's disk, and the account
        # scope keeps the readiness question inside the tenant like every
        # other read in this executor.
        def instances_with_attached_volume(volume_ids:, target_instance_ids:)
          return [] if volume_ids.empty? || target_instance_ids.empty?

          ::System::ProviderVolume
            .where(account_id: @account.id, id: volume_ids, node_instance_id: target_instance_ids)
            .distinct.pluck(:node_instance_id)
        end

        # Both predicates are ProvisionFullStackExecutor's own (class scope),
        # not copies: the leg that provisions the volume and the guard that
        # refuses its absence must answer identically, or an explicit
        # `with_storage_gb: 0` — a legitimate "no storage" (IMP-33fa6c51f05d)
        # — would be read as a missing disk and strand every zero-storage
        # blue_green relocate.
        def storage_requested?(with_storage_gb)
          ::System::Ai::Skills::ProvisionFullStackExecutor.storage_requested?(with_storage_gb)
        end

        def storage_unreadable?(with_storage_gb)
          ::System::Ai::Skills::ProvisionFullStackExecutor.storage_unreadable?(with_storage_gb)
        end

        # The gate question is "was storage DECLARED?", not "was a positive
        # size requested?" (review F1). A declared-but-unreadable value
        # ("plenty", true, {gb: 50}) takes the inner executor's LOUD lane: it
        # records a provision_storage failure per node and creates NO volume,
        # so the envelope returns the instances up and storage_volume_ids
        # empty. Gated on `storage_requested?` alone, that shape reproduced
        # this task's exact failure — guard passes, sources torn down against
        # a diskless target — through a different input. relocate forwards the
        # raw value with no validation of its own, and IMP-f85254148755 judged
        # the shape reachable from hand-authored plan_data, MissionComposer
        # output and operator input. Verified red by execution before this
        # union existed.
        def storage_declared?(with_storage_gb)
          storage_requested?(with_storage_gb) || storage_unreadable?(with_storage_gb)
        end

        # IMP-49b3e42d9423 — drain's half of the refusal. Same predicate, same
        # reason strings, same event type as blue_green; the DISPOSITION is
        # deliberately the opposite, and this is a considered departure from
        # "reuse the fail-and-reclaim path", not an oversight.
        #
        # WHY NOT RECLAIM. #refuse_blue_green_cutover! can tear the refused
        # stack down because under blue_green the sources are still alive and
        # still hold the workload — the reclaim costs nothing but the target's
        # bill. Under drain they are gone: `terminate_step!` ran before the
        # target existed. The same reclaim here would destroy the mission's
        # ONLY live capacity and turn a degraded fleet into no fleet at all.
        # So the stack is RETAINED, its ids are recorded, and an operator
        # decides — repair it, or relocate again from it.
        #
        # WHY A BARE failure(). The runner's rollback_step! reads its kwargs
        # off this envelope and hands them to #rollback_relocate_workload,
        # which terminates instances and deletes volumes. Every id this branch
        # could hand up is capacity that must survive, so the one correct
        # payload is none. Composers stamp on_failure: "rollback" by default,
        # so the runner will still call the hook — with empty kwargs, where it
        # no-ops (verified in the runner: rollback_outputs_for falls back to
        # `last_outputs`, which a first-run failure never wrote), then stamps
        # `rolled_back(noop: true)` carrying the failure message forward. The
        # durable diagnosis is the event below.
        #
        # THAT SAFETY HAS A DEPENDENCY, named here so it is not lost: it holds
        # because `last_outputs` is empty, and `last_outputs` is empty because
        # a GoalPlanStep can never re-enter execute_step! once it has run
        # (CLAIMABLE_STATUSES is %w[pending]; nothing resets a step to
        # pending). The day a retry path is added, a drain refusal on a step
        # that previously COMPLETED would fall back to the prior run's ids and
        # terminate the mission's live fleet. Anyone adding that retry must
        # give this branch an explicit empty rollback payload rather than
        # relying on the fallback being empty.
        #
        # WHAT THIS COSTS, stated because it IS a behaviour change: a failed
        # step is not `completed`, so the runner never writes
        # metadata["last_outputs"], and System::ProjectMetricsCollector
        # #resolvable_instance_ids — which reads only completed steps —
        # resolves nothing for this mission. replica_count then reports
        # `unavailable` rather than the retained stack's size. That is the
        # honest reading for a relocate that failed, and unavailable is
        # explicitly not the "false zero" IMP-5eb14352370a guarded against;
        # the ids themselves stay findable in the event.
        def refuse_drain_outcome!(mission:, reasons:, terminated:, planned_actions:,
                                  provision_data:, step_failures:, orphaned_outputs:)
          outputs    = provision_data.is_a?(Hash) ? (provision_data[:outputs] || {}) : {}
          node_ids   = Array(outputs[:node_ids])   | Array(orphaned_outputs[:node_ids])
          target_ids = Array(outputs[:node_instance_ids]) | Array(orphaned_outputs[:node_instance_ids])
          volume_ids = Array(outputs[:storage_volume_ids]) | Array(orphaned_outputs[:storage_volume_ids])
          peer_ids   = Array(outputs[:sdwan_peer_ids]) | Array(orphaned_outputs[:sdwan_peer_ids])

          # Orphans from a WHOLESALE inner failure are unioned in here, unlike
          # in the blue_green refusal which keeps them out of the DELIVERED
          # sets: there they are debris to reclaim, here they are live rows
          # nobody is going to tear down, so an operator needs their ids in
          # the same place as the rest. `reasons` is unaffected — it was
          # computed from the delivered outputs alone, so a raise still reads
          # "target stack is empty".
          leg_failures = Array(step_failures) + (provision_data.is_a?(Hash) ? Array(provision_data[:failures]) : [])

          ::Ai::Introspection::ExecutionEventRecorder.record(
            source: mission,
            event_type: "relocate_cutover_refusal",
            status: "target_stack_retained",
            metadata: {
              cutover_strategy: "drain",
              refusal_reasons: reasons,
              terminated_instance_ids: Array(terminated),
              # NOT `reclaimed`/`survivors`: nothing was reclaimed, and those
              # keys present-and-empty read as a clean unwind that never
              # happened. A different disposition gets a different word.
              retained: {
                "node_instance" => target_ids,
                "provider_volume" => volume_ids,
                "sdwan_peer" => peer_ids
              },
              node_ids_left_for_inspection: node_ids,
              # Includes the terminate_source entries (they land in
              # run_execute's `failures`, which arrives as step_failures), so
              # the branch where NOTHING was terminated is diagnosable: those
              # entries are the only record of which sources survived and why.
              provisioning_leg_failures: leg_failures,
              # The RUN TRACE, carried here because a failure envelope has no
              # `data` to carry it — and under drain the run really did tear
              # the sources down and create rows, so this is the operator's
              # only step-by-step record of what happened to them. The
              # blue_green refusal needs no equivalent: it reclaims everything
              # it made, so there is no surviving state to trace.
              planned_actions: planned_actions
            }.compact
          )

          message = "drain cutover degraded: #{reasons.join('; ')}"
          message += if Array(terminated).any?
            "; source instances ALREADY terminated (#{Array(terminated).join(', ')}) — " \
            "drain tears them down before the target exists, so no readiness guard can protect them; " \
            "#{target_ids.size} target instance(s) RETAINED and NOT reclaimed — they are the only " \
            "live capacity for this workload"
          else
            # Review finding #1 — the disposition is the same, but the reason
            # for it is NOT, and the message must not claim the sources are
            # gone when `terminated` is empty. It can be empty two ways and
            # they look identical from here: `terminate_step!` records a
            # failure both when the row does not resolve ("instance not found"
            # — the source is already gone, so there is no fallback capacity
            # at all) and when the provider rejected or half-completed the
            # teardown (state unknown). Retaining is the conservative answer
            # to BOTH, which is why the disposition does not branch: the
            # target is the only capacity whose state this run actually
            # observed, and reclaiming it on the strength of an unverified
            # source would be the irreversible move.
            "; NO source instance was successfully terminated (see the terminate_source failures) — " \
            "their state is UNVERIFIED, so the #{target_ids.size} target instance(s) are RETAINED " \
            "and NOT reclaimed rather than destroying the only capacity this run can vouch for"
          end
          message += "; provisioning-leg failures: #{summarize_entries(leg_failures)}" if leg_failures.any?

          failure(message)
        end

        # THE readiness predicate — the single one, for both strategies
        # (IMP-49b3e42d9423). Empty means the delivered target stack can carry
        # the workload; every entry is a reason it cannot, phrased for an
        # operator and reused verbatim in the refusal message and the
        # execution event.
        #
        # It answers ONLY about the target, deliberately. `failures.any?` /
        # `partial` are not substitutes: a source whose terminate errored sets
        # both on a run that delivered a flawless stack, and refusing there
        # would be the mirror of the bug this closes.
        #
        # The storage arm's oracle is ATTACHMENT, not the id count
        # (IMP-e1903a42c1ab): ProvisionFullStackExecutor pushes a volume id
        # onto `storage_volume_ids` before it attempts the attach, so a failed
        # attach yields full count parity over a volume whose
        # `node_instance_id` is nil. Per-instance parity, matching what the
        # approval card promises — the plan lists one provision_storage +
        # attach_volume pair PER target.
        #
        # Callers must evaluate this BEFORE any reclaim: the storage arm reads
        # rows a reclaim detaches and deletes.
        def cutover_refusal_reasons(outputs:, count:, network_id:, with_storage_gb:)
          target_ids = Array(outputs[:node_instance_ids])
          peer_ids   = Array(outputs[:sdwan_peer_ids])
          volume_ids = Array(outputs[:storage_volume_ids])

          reasons = []
          if target_ids.empty?
            reasons << "target stack is empty"
          elsif target_ids.size < count
            reasons << "target stack is undersized (#{target_ids.size}/#{count} instances provisioned)"
          end
          if network_id.present? && peer_ids.size < target_ids.size
            reasons << "target stack is off-fabric (#{peer_ids.size}/#{target_ids.size} " \
                       "instances enrolled on network #{network_id})"
          end
          if storage_declared?(with_storage_gb)
            with_disk = instances_with_attached_volume(volume_ids: volume_ids, target_instance_ids: target_ids)
            if with_disk.size < target_ids.size
              reasons << "target stack is storage-unready (#{with_disk.size}/#{target_ids.size} " \
                         "instances have #{declared_volume_phrase(with_storage_gb)} attached)"
            end
          end
          reasons
        end

        # The card's rendering of #cutover_refusal_reasons' three arms, shared
        # by both strategies' terminate steps (IMP-49b3e42d9423) so the card
        # cannot describe a different guard from the one that runs. The storage
        # clause tracks the GUARD's predicate (`storage_declared?`), which is
        # deliberately WIDER than the provision_storage steps: an unreadable
        # declaration plans no volume steps yet still trips the arm, so a card
        # silent about it would understate the guard on exactly the input that
        # reaches it. An explicit 0 is declared-as-none and stays out of both.
        def readiness_clauses(network_id:, with_storage_gb:)
          clauses = [ "undersized (fewer instances than requested)" ]
          clauses << "off-fabric (not fully enrolled on network #{network_id})" if network_id.present?
          if storage_declared?(with_storage_gb)
            clauses << "storage-unready (#{declared_volume_phrase(with_storage_gb)} not " \
                       "attached to every target)"
          end
          clauses
        end

        # The unreadable branch must NOT quote a size: `with_storage_gb.to_i`
        # renders an authoritative "0 GB" for a value that was never read.
        def declared_volume_phrase(with_storage_gb)
          return "its declared data volume" unless storage_requested?(with_storage_gb)

          "its #{with_storage_gb.to_i} GB data volume"
        end

        # F6 (IMP-6b497651d670 review) — bounded but never truncated
        # mid-identifier: whole entries are rendered (step/resource + id +
        # error) and overflow is COUNTED, not sliced, so an operator reading
        # a failed step never loses an id to a byte cap.
        MESSAGE_DETAIL_LIMIT = 3

        def summarize_entries(entries)
          shown = entries.first(MESSAGE_DETAIL_LIMIT).map do |e|
            label = e[:step] || e["step"] || e[:resource] || e["resource"]
            id    = e[:instance_id] || e["instance_id"] || e[:node_id] || e["node_id"] || e[:id] || e["id"]
            error = e[:error] || e["error"]
            [ label, id ? "(#{id})" : nil, error ? ": #{error}" : nil ].compact.join
          end
          overflow = entries.size - shown.size
          shown.join("; ") + (overflow.positive? ? " (+#{overflow} more)" : "")
        end

        # IMP-df4e3a7d71e5 — the target stack is still the MISSION's fleet, and
        # has to be created saying so.
        #
        # ProvisionFullStackExecutor stamps two independent ownership markers
        # when it is told about the mission: `node.config["mission_id"]` (what
        # ScaleProjectExecutor#mission_replicas resolves scale-in victims by)
        # and the mission's blast-radius prefix on the node name (what that
        # executor's containment rail vouches those victims against). Relocate
        # composes the very same primitive over a mission it has already
        # resolved in #perform, so forwarding neither handed back capacity
        # nothing could address: the source instances it terminates carry the
        # provenance, the targets it creates did not, and after a relocate the
        # mission's live fleet was entirely unstamped — a later scale-in
        # resolved zero victims for it, and every provenance query (the
        # dryrun blast-radius prefix included) missed the fleet.
        #
        # Both markers travel together on purpose. mission_id alone would make
        # the new instances resolvable but nameless to the rail, which refuses
        # the whole removal on a prefix mismatch rather than skipping the
        # stray — strictly worse than the miss it replaces.
        #
        # That rail has a SECOND half, and this leg satisfies it only by
        # inheritance: a scale-in also hard-refuses when any attached volume's
        # name lacks the prefix (ScaleProjectExecutor#run_remove_replicas), and
        # the volumes this leg provisions are named "#{node.name}-data" by
        # ProvisionFullStackExecutor — so they carry the prefix because the node
        # does, not because anything here says so. The coupling is worth
        # naming: were volume names to stop deriving from the node's, a
        # relocated fleet would flip from invisible-to-scale-in straight to
        # every-scale-in-refuses — the strictly-worse outcome above, arriving
        # through the volume rail instead of the mission one.
        #
        # Sourced from the mission itself (ScaleProjectExecutor's fallback when
        # its caller names no prefix) rather than a new skill input: relocate
        # advertises no prefix of its own, and `Ai::Mission#provenance_name_prefix`
        # is the single derivation both sides of the rail already read.
        def provision_target!(template_id:, count:, to_region_id:,
                              provider_instance_type_id:, network_id:, with_storage_gb:,
                              failures:, planned_actions:, mission:, orphaned:)
          inner = executor(::System::Ai::Skills::ProvisionFullStackExecutor)
          result = inner.execute(
            template_id: template_id, count: count,
            provider_region_id: to_region_id,
            provider_instance_type_id: provider_instance_type_id,
            network_id: network_id, with_storage_gb: with_storage_gb,
            mission_id: mission.id,
            name_prefix: mission.provenance_name_prefix,
            dry_run: false
          )

          if result[:success]
            data = result[:data] || {}
            # IMP-666a6e904650 — lift the inner executor's own planned_actions
            # into this envelope (detail steps in execution order, then the
            # provision_target_stack rollup for the leg). The envelope used to
            # carry only the inner outputs and failures, so the run never
            # recorded the create_node/provision_instance/attach_* steps the
            # approval card promised — plan-vs-run grading was structurally
            # impossible.
            planned_actions.concat(Array(data[:planned_actions]))
            planned_actions << { step: "provision_target_stack",
                                 to_region_id: to_region_id,
                                 instance_count: Array(data.dig(:outputs, :node_instance_ids)).size }
            data
          else
            failures << { step: "provision_target_stack", error: result[:error] }

            # IMP-5eb14352370a — d44b0300 (IMP-666a6e904650) lifted the inner
            # steps on the SUCCESS path only. A WHOLESALE inner failure — an
            # unguarded raise mid-loop, `Node.create!` RecordInvalid on target
            # 3 of 3 being the recorded shape — is turned into a bare
            # `failure(message)` by BaseSkillExecutor#execute and carries no
            # `:data`, so the nodes, instances, volumes and peers already
            # created for the EARLIER targets landed in neither
            # planned_actions nor outputs. Rollback kwargs are read off this
            # envelope, which made them invisible to rollback, to grading and
            # to the operator at once — in precisely the run where the graded
            # record matters most.
            #
            # ORPHANS, not delivered targets, and the distinction is
            # load-bearing: the inner executor never returned an envelope, so
            # nothing here attests that any of these is complete or healthy.
            # They are recorded and reclaimed as debris, while the blue_green
            # readiness guard downstream keeps reading `provision_data` (nil ⇒
            # "target stack is empty"), which stays the honest description of
            # what was DELIVERED. Counting them as provisioned targets would
            # assert a health this path cannot observe.
            #
            # Scoped by construction: `inner` is this call's own executor
            # instance, so its in-flight progress can only hold what THIS
            # provisioning attempt created — never a sibling step's resources,
            # never a prior relocate's.
            progress = inner.in_flight_progress
            planned_actions.concat(Array(progress[:planned_actions]))
            orphaned.merge!(progress[:outputs])
            if orphaned.any? { |_class, ids| ids.present? }
              planned_actions << { step: "provision_target_stack_orphaned",
                                   to_region_id: to_region_id,
                                   node_count: Array(orphaned[:node_ids]).size,
                                   instance_count: Array(orphaned[:node_instance_ids]).size,
                                   sdwan_peer_count: Array(orphaned[:sdwan_peer_ids]).size,
                                   volume_count: Array(orphaned[:storage_volume_ids]).size }
            end
            nil
          end
        end

        def terminate_step!(source_ids:, terminated:, failures:, planned_actions:)
          source_ids.each do |instance_id|
            instance = ::System::NodeInstance.find_by(id: instance_id)
            unless instance
              failures << { step: "terminate_source", id: instance_id, error: "instance not found" }
              next
            end

            result = ::System::ProvisioningService.terminate_instance(instance: instance)
            if result.success?
              terminated << instance_id
              planned_actions << { step: "terminate_source", instance_id: instance_id }
            else
              failures << { step: "terminate_source", id: instance_id, error: result.error }
            end
          rescue StandardError => e
            failures << { step: "terminate_source", id: instance_id, error: e.message }
          end
        end

        def build_plan(strategy:, count:, source_ids:, template_id:, to_region_id:,
                       provider_instance_type_id:, network_id:, with_storage_gb:)
          steps = [
            { step: "relocate_workload", cutover_strategy: strategy,
              source_count: source_ids.size, target_count: count }
          ]
          # One peer attach and one storage pair per target, inside the
          # provisioning run rather than trailing the whole plan: the real path
          # enrols each instance and provisions-then-attaches its volume as that
          # instance comes up (ProvisionFullStackExecutor#run_execute), so under
          # blue_green all of it completes BEFORE the source is terminated. This
          # is the operator's approval card for a :high blast-radius skill — a
          # single trailing step understated the peer count, and trailing
          # storage placed the volumes after a terminate_source that blue_green
          # does not reach until provisioning is done (IMP-9fff24306a2c). Under
          # drain the trailing placement was order-correct by accident, but
          # still listed the volumes apart from the targets they belong to.
          #
          # Every per-target step uses the inner executor's own emitted step
          # name: creating the Node and provisioning its instance are two state
          # changes, so they are two steps (a collapsed provision_target_instance
          # understated the run by one step per target, IMP-666a6e904650), and
          # the attach is its own step because it is its own state change
          # (IMP-093378034fb4). Since #run_execute concatenates the inner
          # envelope's planned_actions into this executor's own
          # (#provision_target!), a relocate plan and a relocate run CAN be
          # graded step-for-step. The run additionally records one
          # provision_target_stack rollup after the provisioning leg, and
          # records terminate_source only for sources actually terminated —
          # every blue_green refusal (undersized, off-fabric or
          # storage-unready) fails the whole step after reclaiming the refused
          # targets (IMP-6b497651d670, IMP-bb73f7154f27, IMP-e1903a42c1ab).
          # The terminate steps below carry that guard.
          provision_steps = []
          count.times do |i|
            provision_steps << { step: "create_node", index: i, template_id: template_id }
            provision_steps << { step: "provision_instance", index: i,
                                 to_region_id: to_region_id,
                                 provider_instance_type_id: provider_instance_type_id }
            provision_steps << { step: "attach_sdwan_peer", index: i, network_id: network_id } if network_id.present?
            # Non-positive is "no volume", matching the executor that actually
            # provisions it (ProvisionFullStackExecutor#storage_requested?,
            # IMP-33fa6c51f05d). `blank?` did not screen a 0 — and once the
            # inner executor screens one, listing the pair here would promise a
            # volume the run will not create, on the approval card of a :high
            # blast-radius skill.
            next unless storage_requested?(with_storage_gb)

            provision_steps << { step: "provision_storage", index: i, size_gb: with_storage_gb.to_i }
            provision_steps << { step: "attach_volume", index: i }
          end
          terminate_steps = source_ids.map { |id| { step: "terminate_source", instance_id: id } }
          if strategy == "blue_green"
            # IMP-666a6e904650 — blue_green refuses the teardown when the
            # target stack comes up undersized, off-fabric or storage-unready
            # (the blue_green_cutover guard in #run_execute), so an unconditional
            # entry promised a destruction the run may (correctly) decline.
            # The step stays — the operator consents to the intent — marked
            # with the guard that may refuse it, so the card shows both the
            # intent and the safety. IMP-6b497651d670 — the card also
            # discloses the refusal's OTHER side: the fresh target stack is
            # reclaimed and sources stay untouched, because a :high
            # blast-radius approval must cover every destruction the run can
            # perform, including the compensating one.
            #
            # IMP-e1903a42c1ab — the guard grew a third arm, so the card
            # enumerates all of them. The storage clause tracks the GUARD's
            # own predicate (`storage_declared?`), which is deliberately WIDER
            # than the provision_storage steps above: an unreadable
            # declaration plans no volume steps — the inner executor creates
            # nothing — yet still refuses the cutover, so a card silent about
            # it would understate the guard on exactly the input that reaches
            # it. An explicit 0 is declared-as-none and stays out of both:
            # promising a storage refusal there would describe a refusal the
            # run cannot reach, the mirror of the same understatement.
            condition = "skipped when the target stack comes up " \
                        "#{readiness_clauses(network_id: network_id, with_storage_gb: with_storage_gb).join(' or ')}; " \
                        "on refusal the fresh target stack is reclaimed and sources are left untouched"
            terminate_steps.each do |step|
              step[:conditional] = true
              step[:guard] = "blue_green_cutover"
              step[:condition] = condition
            end
          else # drain
            # IMP-49b3e42d9423 — the card's statement of drain's safety
            # posture, and deliberately NOT a `conditional`/`guard` marker: the
            # teardown really is unconditional, and a marker would promise a
            # protection the run does not have. What the card was missing is
            # the TERMINAL STATE the same three arms now produce here — the
            # run can end with these sources destroyed and a target that
            # cannot carry the workload, which an operator approving a :high
            # blast-radius destruction has to be told before they approve it.
            clauses = readiness_clauses(network_id: network_id, with_storage_gb: with_storage_gb)
            note = "UNCONDITIONAL — the source is torn down before any target exists, so no " \
                   "readiness guard can protect it; if the target then comes up " \
                   "#{clauses.join(' or ')} the run FAILS with these sources already torn down (or, " \
                   "where a teardown itself failed, in an unverified state) and the degraded target " \
                   "RETAINED — never reclaimed, because it is the only capacity the run can vouch for"
            terminate_steps.each { |step| step[:note] = note }
          end

          steps.concat(strategy == "drain" ? terminate_steps + provision_steps : provision_steps + terminate_steps)
          steps
        end

        def empty_outputs
          { node_ids: [], node_instance_ids: [], sdwan_peer_ids: [],
            storage_volume_ids: [], terminated_instance_ids: [] }
        end
      end
    end
  end
end
