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

        binds_to "Fleet Autonomy"

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
          # card (#build_plan), the cutover guard (#storage_unready?) and the
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

          if strategy == "drain"
            terminate_step!(source_ids: source_ids, terminated: terminated,
                            failures: failures, planned_actions: planned_actions)

            provision_data = provision_target!(template_id: template_id,
                                               count: count, to_region_id: to_region_id,
                                               provider_instance_type_id: provider_instance_type_id,
                                               network_id: network_id, with_storage_gb: with_storage_gb,
                                               failures: failures, planned_actions: planned_actions,
                                               mission: mission)
          else # blue_green
            provision_data = provision_target!(template_id: template_id,
                                               count: count, to_region_id: to_region_id,
                                               provider_instance_type_id: provider_instance_type_id,
                                               network_id: network_id, with_storage_gb: with_storage_gb,
                                               failures: failures, planned_actions: planned_actions,
                                               mission: mission)

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
            target_outputs      = provision_data.is_a?(Hash) ? (provision_data[:outputs] || {}) : {}
            target_instance_ids = Array(target_outputs[:node_instance_ids])
            attached_peer_ids   = Array(target_outputs[:sdwan_peer_ids])
            undersized = target_instance_ids.size < count
            off_fabric = network_id.present? && attached_peer_ids.size < target_instance_ids.size
            storage_unready = storage_unready?(
              with_storage_gb: with_storage_gb,
              target_instance_ids: target_instance_ids,
              volume_ids: Array(target_outputs[:storage_volume_ids])
            )

            if undersized || off_fabric || storage_unready
              # IMP-6b497651d670 — every refusal is a FAILURE with an
              # in-branch reclaim, not a success(partial: true): see
              # #refuse_blue_green_cutover! for why neither standard envelope
              # shape can delegate the reclaim to the runner.
              return refuse_blue_green_cutover!(
                mission: mission, network_id: network_id, count: count,
                with_storage_gb: with_storage_gb,
                provision_data: provision_data, step_failures: failures
              )
            else
              terminate_step!(source_ids: source_ids, terminated: terminated,
                              failures: failures, planned_actions: planned_actions)
            end
          end

          provision_outputs = provision_data ? (provision_data[:outputs] || {}) : empty_outputs
          # The inner executor reports per-leg failures in its own envelope and
          # keeps going; dropping them here left an enrollment or volume error
          # with nowhere to surface — the runner records only what we return.
          failures.concat(provision_data ? Array(provision_data[:failures]) : [])

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
        def refuse_blue_green_cutover!(mission:, network_id:, count:, with_storage_gb:,
                                       provision_data:, step_failures:)
          outputs     = provision_data.is_a?(Hash) ? (provision_data[:outputs] || {}) : {}
          node_ids    = Array(outputs[:node_ids])
          target_ids  = Array(outputs[:node_instance_ids])
          volume_ids  = Array(outputs[:storage_volume_ids])
          peer_ids    = Array(outputs[:sdwan_peer_ids])

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
          # Computed BEFORE the reclaim below, which detaches and deletes the
          # very rows this reads (IMP-e1903a42c1ab).
          if storage_declared?(with_storage_gb)
            with_disk = instances_with_attached_volume(volume_ids: volume_ids, target_instance_ids: target_ids)
            if with_disk.size < target_ids.size
              reasons << "target stack is storage-unready (#{with_disk.size}/#{target_ids.size} " \
                         "instances have #{declared_volume_phrase(with_storage_gb)} attached)"
            end
          end

          # The inner executor's own leg failures — the REASON the stack is
          # refused. step_failures covers the provision_data-nil shape (a
          # whole-step inner failure lands in run_execute's local failures,
          # not in an inner envelope).
          leg_failures = Array(step_failures) + (provision_data.is_a?(Hash) ? Array(provision_data[:failures]) : [])

          reclaim = rollback_relocate_workload(
            node_instance_ids: target_ids,
            storage_volume_ids: volume_ids,
            sdwan_peer_ids: peer_ids
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
            "node_instance"   => target_ids - survivors["node_instance"],
            "provider_volume" => volume_ids - survivors["provider_volume"],
            "sdwan_peer"      => peer_ids - survivors["sdwan_peer"]
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
              node_ids_left_for_inspection: node_ids,
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

        # Per-instance parity, matching what the approval card promises: the
        # plan lists one provision_storage + attach_volume pair PER target, so
        # a stack where only some targets got their disk is refused for the
        # same reason a partially-enrolled stack is off-fabric — the workload
        # cannot run on it, and the sources still hold the only copy.
        def storage_unready?(with_storage_gb:, target_instance_ids:, volume_ids:)
          return false unless storage_declared?(with_storage_gb)

          instances_with_attached_volume(
            volume_ids: volume_ids, target_instance_ids: target_instance_ids
          ).size < target_instance_ids.size
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
                              failures:, planned_actions:, mission:)
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
            clauses = [ "undersized (fewer instances than requested)" ]
            clauses << "off-fabric (not fully enrolled on network #{network_id})" if network_id.present?
            if storage_declared?(with_storage_gb)
              clauses << "storage-unready (#{declared_volume_phrase(with_storage_gb)} not " \
                         "attached to every target)"
            end
            condition = "skipped when the target stack comes up #{clauses.join(' or ')}; " \
                        "on refusal the fresh target stack is reclaimed and sources are left untouched"
            terminate_steps.each do |step|
              step[:conditional] = true
              step[:guard] = "blue_green_cutover"
              step[:condition] = condition
            end
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
