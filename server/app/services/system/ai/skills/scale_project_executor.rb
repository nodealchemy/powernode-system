# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Adaptive evolution skill — scale a provisioning project (Ai::Mission)
      # along one of four axes:
      #
      #   add_replicas      — add N new instances of the project's existing
      #                       template + region (composes ProvisionFullStackExecutor
      #                       in its compute-only mode)
      #   remove_replicas   — scale IN: terminate the N newest replicas of the
      #                       mission's OWN set, never below the project's
      #                       declared replica floor (APO 3a — see
      #                       #replica_floor_for), through the same teardown
      #                       the rollback uses
      #   vertical_resize   — plan a rolling module upgrade or instance-type
      #                       swap (composes RollingModuleUpgradeExecutor —
      #                       returns a batched plan, not in-band mutation)
      #   add_region        — provision a parallel stack in a new region
      #                       (composes ProvisionFullStackExecutor with
      #                       optional network + storage for the new region)
      #
      # Executor returns the same {dry_run, count, planned_actions, outputs,
      # failures, partial} envelope as ProvisionFullStackExecutor so the
      # AdaptationProposer + the runner's rollback dispatch can treat all
      # provisioning skills uniformly.
      #
      # REMOVAL IS IRREVERSIBLE, and the envelope says so. Its victims are
      # recorded under `removed_node_instance_ids` — deliberately NOT in
      # `node_instance_ids`, which means "instances this step brought into
      # existence" to every reader: the rollback dispatch would try to
      # terminate them a second time, and VerificationService would grade the
      # step with an instance-CREATION oracle it can never satisfy. There is
      # nothing to roll a removal back to, which is exactly why removals never
      # auto-apply (ratified §4) — see AdaptationProposerService#auto_apply?.
      #
      # KNOWN LIMITS OF THE SCALE-IN STORAGE TEARDOWN, stated plainly so
      # neither is read as a guarantee:
      #
      #   1. It reaches a victim's volumes through `ProviderVolume#node_instance_id`.
      #      As of IMP-093378034fb4 `ProvisionFullStackExecutor` ATTACHES the
      #      per-instance volumes it provisions for `with_storage_gb`, so they
      #      carry that FK and this teardown covers them — which it did not
      #      before: a nil FK put them out of reach of the teardown AND of the
      #      orphan sweep below, so a scale-in reported zero orphans while the
      #      volumes billed on. The residual: a volume whose ATTACH failed
      #      still carries a nil FK and is still out of reach here, and nothing
      #      reclaims it automatically. It is not SILENT, though — the creating
      #      step records an `attach_volume` failure and returns `partial`,
      #      which VerificationService grades as a failing step_N_failures
      #      check.
      #   2. Volume ownership is judged by NAME, the same rail as instances:
      #      a mission's volume is named after its node and so carries the
      #      prefix. That bounds the damage where a prefix exists — but a
      #      mission that declares none has no volume rail either, and there
      #      everything attached to a victim is still deleted, mission-owned
      #      or not. `outputs.prefix_enforced` records which case ran.
      #
      # THE BACKEND SET TRAVELS WITH THE REPLICAS (APO-3d, IMP-0c10b9fd5596).
      # A published Sdwan::Service dials ONE backend unless it has an explicit
      # Sdwan::ServiceBackend set, and APO-3c shipped that set with no
      # producer — so add_replicas minted instances no service ever dialled,
      # and remove_replicas terminated instances whose member rows would have
      # kept Traefik dialling a dead host. Both arms now maintain the set for
      # every service that routes to the mission's replicas
      # (Sdwan::ServiceBackend.services_routed_to) and regenerate the proxy:
      # the PROVISION arm joins each new replica, remove_replicas (and the
      # rollback, through the same teardown) removes each victim's rows BEFORE
      # the terminate takes its addresses away. A join that fails is a recorded
      # step failure (`partial`), never a silent one.
      #
      # The join belongs to #run_provision, so BOTH add_replicas and add_region
      # do it — they differ only in region semantics and compose the same
      # primitive. That is deliberate: a cross-region replica no service dials
      # is the same defect as a same-region one, and .address_for keeps the
      # newcomer on the fabric the service's existing backends already use.
      #
      # Reference: AI-Driven Provisioning plan — slice 8 (M2 adaptive
      # evolution); scale-in from the platform-evolution-loop charter (INC-4).
      class ScaleProjectExecutor < BaseSkillExecutor
        STRATEGIES = %w[add_replicas vertical_resize add_region remove_replicas].freeze
        MAX_DELTA  = 50

        # The HARD platform minimum — never scale a project to zero. A removal
        # that would empty the mission is clamped to leave at least this many
        # replicas standing, converging toward the request instead of refusing
        # it outright, the same way the composer clamps an oversized scale-out
        # delta.
        #
        # This is a FLOOR ON THE FLOOR, not the whole answer: the effective
        # floor is the project's own declared one (`Ai::Mission#scaling_bounds`,
        # APO 3a), which a mission may raise above this and can never lower
        # below it. See #replica_floor_for.
        MIN_REPLICAS = 1

        skill_descriptor(
          name: "scale_project",
          description: "Adapt a provisioning project's footprint — add replicas in-region, remove the newest replicas, plan a vertical resize, or expand into a new region. Composes ProvisionFullStackExecutor + RollingModuleUpgradeExecutor.",
          category: "devops",
          inputs: {
            project_id: { type: "string", required: true,
                          description: "Ai::Mission id (the provisioning project being scaled)" },
            target_count: { type: "integer", required: true,
                            description: "Number of instances to add (add_replicas / add_region) or remove (remove_replicas) — bounded 1..#{MAX_DELTA}. Ignored for vertical_resize." },
            scaling_strategy: { type: "string", required: true,
                                description: "One of: #{STRATEGIES.join(', ')}" },
            template_id: { type: "string", required: false,
                           description: "System::NodeTemplate to instantiate (add_replicas / add_region) or whose fleet is being resized (vertical_resize)" },
            provider_region_id: { type: "string", required: false,
                                  description: "Region for new instances (add_replicas: same as project; add_region: NEW region)" },
            provider_instance_type_id: { type: "string", required: false,
                                         description: "Instance type for new instances" },
            module_id: { type: "string", required: false,
                         description: "vertical_resize: System::NodeModule whose target_version replaces in-place" },
            target_version_id: { type: "string", required: false,
                                 description: "vertical_resize: target System::NodeModuleVersion id" },
            network_id: { type: "string", required: false,
                          description: "add_region: optional Sdwan::Network to attach new instances to" },
            with_storage_gb: { type: "integer", required: false,
                               description: "add_region: optional per-instance volume size" },
            name_prefix: { type: "string", required: false,
                           description: "Blast-radius marker. add_replicas/add_region stamp it onto new node names; remove_replicas refuses any victim whose name lacks it (hard error). Defaults to the mission's own prefix — when the mission declares none the rail is not applied, and outputs.prefix_enforced says so." },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — return projected actions without creating any cloud resources" }
          },
          outputs: {
            dry_run: :boolean,
            count: :integer,
            scaling_strategy: :string,
            planned_actions: [ :object ],
            outputs: {
              node_ids: [ :string ],
              node_instance_ids: [ :string ],
              sdwan_peer_ids: [ :string ],
              storage_volume_ids: [ :string ],
              rolling_upgrade_plan: :object,
              # APO-3d — the published services the new replicas joined and
              # the Sdwan::ServiceBackend rows this step minted for them.
              sdwan_service_ids: [ :string ],
              sdwan_service_backend_ids: [ :string ],
              # remove_replicas only — what this step DESTROYED, kept out of
              # the creation keys above so no reader mistakes a teardown for a
              # provision. `orphans` is the post-teardown ground-truth sweep.
              removed_node_instance_ids: [ :string ],
              detached_sdwan_peer_ids: [ :string ],
              deleted_storage_volume_ids: [ :string ],
              removed_sdwan_service_backend_ids: [ :string ],
              orphans: [ :object ],
              floor_reached: :boolean,
              # Which containment rail actually applied — nil when the mission
              # declares no prefix, so an unmeasured rail is never read as a
              # clean one.
              prefix_enforced: :string
            },
            failures: [ :object ],
            partial: :boolean
          },
          rollback: :rollback_scale_project,
          blast_radius: :medium
        )

        binds_to "Fleet Autonomy"

        # Instance-method rollback. Reverses the side effects recorded in the
        # outputs envelope. vertical_resize returns a plan — it has no side
        # effects to reverse, so its outputs are empty and rollback no-ops.
        def rollback_scale_project(node_instance_ids: [], storage_volume_ids: [], **_extras)
          result = teardown_resources(node_instance_ids: node_instance_ids,
                                      storage_volume_ids: storage_volume_ids)
          # One regen for the whole rollback — #teardown_resources leaves it to
          # its caller so an N-instance teardown reloads Traefik once.
          regen_service_exposure!(result[:errors]) if result[:removed_backends].any?

          { success: result[:errors].empty?, errors: result[:errors] }
        end

        protected

        # `**_extras` swallows context kwargs (notably `brief`) that
        # PlanComposerService injects into every step's inputs.
        def perform(project_id:, target_count:, scaling_strategy:,
                    template_id: nil, provider_region_id: nil,
                    provider_instance_type_id: nil, module_id: nil,
                    target_version_id: nil, network_id: nil,
                    with_storage_gb: nil, storage_gb: nil,
                    name_prefix: nil, dry_run: false, **_extras)
          # IMP-01a774a80f7a — same alias drop as RelocateWorkloadExecutor's,
          # non-destructive but live and metered: `scale_project` IS in
          # CostEstimatorService::COMPUTE_SKILLS, and that service reads
          # [with_storage_gb, storage_gb] — so a scale-out declaring only
          # `storage_gb: 500` was QUOTED 500 GB per replica and provisioned
          # none, the quote-vs-actuator disagreement IMP-051509357291 and
          # IMP-f85254148755 exist to eliminate. Resolved ONCE here, in
          # ProvisionFullStackExecutor's published order (class scope, not a
          # copy), and forwarded to the arm that composes it — which is both
          # the plan surface and the provisioning surface for this skill.
          with_storage_gb = ::System::Ai::Skills::ProvisionFullStackExecutor
                            .resolve_storage_gb(with_storage_gb, storage_gb)

          strategy = scaling_strategy.to_s
          return failure("scaling_strategy must be one of: #{STRATEGIES.join(', ')}") unless STRATEGIES.include?(strategy)

          mission = ::Ai::Mission.where(account_id: @account.id).find_by(id: project_id)
          return failure("project not found: #{project_id}") unless mission

          case strategy
          when "add_replicas", "add_region"
            count = target_count.to_i
            return failure("target_count must be between 1 and #{MAX_DELTA}") unless count.between?(1, MAX_DELTA)
            return failure("template_id is required for #{strategy}") if template_id.blank?
            return failure("provider_region_id is required for #{strategy}") if provider_region_id.blank?
            return failure("provider_instance_type_id is required for #{strategy}") if provider_instance_type_id.blank?

            run_provision(strategy: strategy, mission: mission, count: count, template_id: template_id,
                          provider_region_id: provider_region_id,
                          provider_instance_type_id: provider_instance_type_id,
                          network_id: network_id, with_storage_gb: with_storage_gb,
                          name_prefix: name_prefix, dry_run: dry_run)

          when "remove_replicas"
            count = target_count.to_i
            return failure("target_count must be between 1 and #{MAX_DELTA}") unless count.between?(1, MAX_DELTA)

            run_remove_replicas(mission: mission, requested: count,
                                name_prefix: name_prefix, dry_run: dry_run)

          when "vertical_resize"
            return failure("template_id is required for vertical_resize") if template_id.blank?
            return failure("module_id is required for vertical_resize") if module_id.blank?
            return failure("target_version_id is required for vertical_resize") if target_version_id.blank?

            run_vertical_resize(template_id: template_id, module_id: module_id,
                                target_version_id: target_version_id, dry_run: dry_run)
          end
        end

        private

        # add_replicas + add_region both compose the M0 ProvisionFullStackExecutor.
        # The strategies differ only in semantics (same vs. new region) —
        # both delegate to the same primitive and re-shape the result.
        #
        # `mission_id` + `name_prefix` are threaded through so the replicas THIS
        # skill adds carry the same provenance PlanComposerService stamps on the
        # mission's original ones. Without them the two arms address different
        # fleets: a later remove_replicas resolves victims by that provenance,
        # so it would skip everything a scale-out added and eat the mission's
        # original capacity instead — the inverse of undoing the newest change.
        def run_provision(strategy:, mission:, count:, template_id:, provider_region_id:,
                          provider_instance_type_id:, network_id:, with_storage_gb:,
                          name_prefix:, dry_run:)
          inner = executor(::System::Ai::Skills::ProvisionFullStackExecutor)
          inner_result = inner.execute(
            template_id: template_id,
            count: count,
            provider_region_id: provider_region_id,
            provider_instance_type_id: provider_instance_type_id,
            network_id: network_id,
            with_storage_gb: with_storage_gb,
            mission_id: mission.id,
            name_prefix: name_prefix.presence || mission.provenance_name_prefix,
            dry_run: dry_run
          )
          return inner_result unless inner_result[:success]

          inner_data = inner_result[:data] || {}
          inner_outputs = inner_data[:outputs] || {}
          new_instance_ids = Array(inner_outputs[:node_instance_ids])

          joined = join_service_backends(mission: mission, new_instance_ids: new_instance_ids,
                                         dry_run: dry_run)
          failures = Array(inner_data[:failures]) + joined[:failures]

          success(
            dry_run: dry_run ? true : false,
            count: count,
            scaling_strategy: strategy,
            planned_actions: prepend_strategy_marker(strategy,
                                                     Array(inner_data[:planned_actions]) + joined[:actions]),
            outputs: {
              node_ids: Array(inner_outputs[:node_ids]),
              node_instance_ids: new_instance_ids,
              sdwan_peer_ids: Array(inner_outputs[:sdwan_peer_ids]),
              storage_volume_ids: Array(inner_outputs[:storage_volume_ids]),
              rolling_upgrade_plan: nil,
              sdwan_service_ids: joined[:service_ids],
              sdwan_service_backend_ids: joined[:backend_ids]
            },
            failures: failures,
            partial: inner_data[:partial] == true || joined[:failures].any?
          )
        end

        # APO-3d — put the new replicas INTO the published services the
        # mission's existing replicas already back.
        #
        # The services are discovered from the replicas that were there
        # BEFORE this scale-out (the new ones cannot yet be routed to), so the
        # operator's approval of "add N replicas to this project" is exactly
        # what widens the set: nothing is joined that the project was not
        # already serving. A dry run names the services and writes nothing.
        #
        # One proxy regen at the end, and only when a row was actually written
        # — Traefik reloads on every write to the dynamic dir.
        def join_service_backends(mission:, new_instance_ids:, dry_run:)
          services = mission_services(mission, excluding: new_instance_ids)
          result = { service_ids: [], backend_ids: [], actions: [], failures: [] }
          return result if services.empty?

          if dry_run
            result[:actions] = services.map do |svc|
              { step: "join_service_backends", service_id: svc.id, slug: svc.slug,
                node_instance_ids: [] }
            end
            return result
          end

          instances = ::System::NodeInstance.where(id: new_instance_ids).index_by(&:id)
          services.each do |svc|
            joined_ids = []
            before = svc.backends.pluck(:id)
            new_instance_ids.each do |instance_id|
              instance = instances[instance_id]
              next unless instance

              ::Sdwan::ServiceBackend.add_instance!(service: svc, instance: instance)
              joined_ids << instance_id
            rescue StandardError => e
              result[:failures] << { step: "join_service_backends", service_id: svc.id,
                                     node_instance_id: instance_id, error: e.message }
            end
            # Rows this step MINTED — the materialised legacy member included
            # — never the whole set, so a re-read of the outputs cannot claim
            # rows an earlier scale-out created.
            result[:backend_ids].concat(svc.backends.reload.pluck(:id) - before)
            next if joined_ids.empty?

            result[:service_ids] << svc.id
            result[:actions] << { step: "join_service_backends", service_id: svc.id, slug: svc.slug,
                                  node_instance_ids: joined_ids }
          end

          regen_service_exposure!(result[:failures]) if result[:backend_ids].any?
          result
        end

        # Every published service that routes to one of the mission's replicas
        # BY ADDRESS — the set the arms maintain. `excluding:` drops instances
        # this very step created, which by construction no service routes to
        # yet.
        #
        # .host_routed_services, not .services_routed_to: a service that
        # reaches the mission only through a backend VIP is left alone, the
        # same rule ReplaceInstanceExecutor#rehome_service_backends! applies.
        # A host-form row for a new replica beside a VIP row would count one
        # machine twice — and hand it the whole round robin the moment the VIP
        # failed over onto it.
        def mission_services(mission, excluding: [])
          mission_replicas(mission).reject { |instance| excluding.include?(instance.id) }
                                   .flat_map { |instance| ::Sdwan::ServiceBackend.host_routed_services(account: @account, instance: instance) }
                                   .uniq(&:id)
        end

        # Re-emit the account's Traefik YAML so a changed set is what Traefik
        # dials. A regen failure is a recorded failure, never a raise: the DB
        # already reflects the fleet, and the stale on-disk file is what the
        # failure entry tells the operator to regenerate
        # (system_reverse_proxy_compose).
        def regen_service_exposure!(failures)
          ::Sdwan::ServiceExposureWriter.write!(account: @account)
        rescue ::Sdwan::ServiceExposureWriter::WriteError => e
          failures << { step: "regenerate_service_exposure", error: e.message }
        end

        # remove_replicas — the scale-IN arm (INC-4).
        #
        # Victims are the NEWEST replicas of the mission's own set, so a
        # scale-in undoes the most recent scale-out first and long-lived
        # capacity is the last thing to go.
        def run_remove_replicas(mission:, requested:, name_prefix:, dry_run:)
          replicas = mission_replicas(mission)
          floor = replica_floor_for(mission)
          removable = [ requested, replicas.size - floor ].min
          prefix = name_prefix.presence || mission.provenance_name_prefix

          # At (or below) the floor there is nothing this strategy may do. A
          # recorded no-op, not a failure: failing the step would trigger the
          # composed plan's `on_failure: rollback` over a mission that is
          # simply already as small as it is allowed to be.
          if removable < 1
            return success(removal_envelope(
              dry_run: dry_run, count: 0,
              actions: [ { step: "remove_replicas_floor", requested: requested,
                           live_replicas: replicas.size, floor: floor } ],
              outputs: removal_outputs(prefix: prefix, floor_reached: true)
            ))
          end

          victims = replicas.first(removable)

          # CONTAINMENT RAIL — checked across ALL victims BEFORE anything is
          # torn down, and a hard error rather than a skip.
          #
          # The mission-provenance query above and the mission's blast-radius
          # prefix are two independent markers of the same ownership. When they
          # disagree we do not know which one is lying, and the failure mode of
          # guessing is terminating something that belongs to somebody else —
          # so refuse the whole removal and leave the fleet exactly as it is.
          # Skipping the stray would silently substitute a different victim.
          #
          # A mission that declares NO prefix leaves this rail unmeasured, not
          # satisfied — provenance is then the sole ownership marker. Which of
          # the two it was is recorded as `outputs.prefix_enforced` so a reader
          # can never mistake "no prefix to check" for "checked and clean".
          if prefix.present?
            stray = victims.reject { |instance| instance.name.to_s.start_with?(prefix) }
            if stray.any?
              return failure(
                "refusing to remove #{stray.size} instance(s) outside the mission's " \
                "`#{prefix}` prefix: #{stray.map(&:name).join(', ')}"
              )
            end
          end

          # The SAME rail, applied to the other destroyable resource class.
          # A volume this mission provisioned is named after its node, so it
          # inherits the prefix; one that does not is somebody else's — an
          # operator's data disk hand-attached to a replica — and deleting it
          # is irreversible under an approval that only ever described
          # removing replicas. Refuse the removal rather than destroy
          # something the rail cannot vouch for.
          volumes = victim_volumes(victims)
          if prefix.present?
            foreign = volumes.reject { |v| v.name.to_s.start_with?(prefix) }
            if foreign.any?
              return failure(
                "refusing to remove: #{foreign.size} attached volume(s) outside the mission's " \
                "`#{prefix}` prefix would be deleted: #{foreign.map(&:name).join(', ')}"
              )
            end
          end

          if dry_run
            return success(removal_envelope(
              dry_run: true, count: victims.size,
              actions: victims.map { |i| { step: "remove_replica", node_instance_id: i.id, name: i.name } } +
                       planned_service_backend_removals(victims),
              outputs: removal_outputs(prefix: prefix)
            ))
          end

          actuate_removal(victims: victims, prefix: prefix, volumes: volumes)
        end

        # Tears victims down one at a time through the shared teardown, then
        # re-reads the rows to prove the teardown actually happened.
        def actuate_removal(victims:, prefix:, volumes:)
          actions = []
          removed = []
          detached_peers = []
          deleted_volumes = []
          removed_backends = []
          failures = []
          orphans = []

          victims.each do |instance|
            peer_ids = ::Sdwan::Peer.where(node_instance_id: instance.id).pluck(:id)
            # The vetted snapshot INTERSECTED with where each volume actually
            # sits now. The snapshot alone bounds what may be deleted to what
            # the rail vouched for; re-reading alone would delete whatever got
            # attached since, unchecked. Both matter, and in opposite
            # directions: a volume that MOVED to a surviving instance between
            # selection and now must not be deleted off it, and one that
            # arrived in that window survives its instance for the orphan
            # sweep below to report.
            volume_ids = volumes.select { |v|
              v.node_instance_id == instance.id &&
                ::System::ProviderVolume.where(id: v.id, node_instance_id: instance.id).exists?
            }.map(&:id)

            result = teardown_resources(node_instance_ids: [ instance.id ],
                                        storage_volume_ids: volume_ids)
            failures.concat(result[:errors].map { |e| e.merge(step: "remove_replica") })
            removed.concat(result[:terminated])
            deleted_volumes.concat(result[:deleted_volumes])
            removed_backends.concat(result[:removed_backends])
            # Ground truth, not "the detacher returned": a peer counts as
            # detached only once its row is actually gone.
            detached_peers.concat(peer_ids - ::Sdwan::Peer.where(id: peer_ids).pluck(:id))
            actions << { step: "remove_replica", node_instance_id: instance.id, name: instance.name }

            # A victim that would not terminate is a FAILED removal, not a
            # leak, and the two must not be conflated: an orphan means the
            # instance is gone while its resources survived. Halt either way —
            # something is wrong with this fleet and the next teardown would
            # only widen the damage before anyone looks.
            unless result[:terminated].include?(instance.id)
              break
            end

            found = orphans_for(instance, expected_gone_volume_ids: volume_ids)
            next if found.empty?

            # STOP CONDITION — an orphan halts the removal before the next
            # victim is touched, so the operator sees the leak against a fleet
            # that still matches the plan instead of one already three
            # teardowns further along.
            orphans.concat(found)
            failures << { step: "remove_replica", node_instance_id: instance.id,
                          error: "orphaned resources survived teardown: #{found.inspect[0, 300]}" }
            break
          end

          # ONE proxy regen for the whole removal, after the last victim — the
          # teardown deliberately does not regen per call.
          regen_service_exposure!(failures) if removed_backends.any?

          # Nothing removed: report a FAILED step. Returning the
          # partial-success envelope here would have the runner mark the step
          # completed, skip its `on_failure: rollback`, and dispatch
          # successors as though capacity had gone away. This covers a victim
          # that vanished between selection and teardown too — that path
          # records neither an error nor a termination, so keying on
          # `failures.any?` alone would call it a clean removal of zero.
          #
          # Volumes are torn down BEFORE the instance, so a failure here can
          # sit on top of disks that are already irreversibly gone. Name them:
          # a bare error message would leave no trace of what was destroyed,
          # and the step records no outputs when it fails.
          if removed.empty?
            destroyed = "destroyed before the failure: " \
                        "volumes=#{deleted_volumes.inspect} peers=#{detached_peers.inspect} " \
                        "service_backends=#{removed_backends.inspect}"
            return failure("remove_replicas removed nothing (#{destroyed}): " \
                           "#{failures.inspect[0, 300]}")
          end

          success(removal_envelope(
            dry_run: false, count: removed.size, actions: actions,
            outputs: removal_outputs(prefix: prefix, removed: removed,
                                     detached_peers: detached_peers,
                                     deleted_volumes: deleted_volumes,
                                     removed_backends: removed_backends, orphans: orphans),
            failures: failures
          ))
        end

        # The dry-run twin of the teardown's backend-set leg: which member
        # rows each victim would leave, so the approval card names the
        # services a scale-in narrows.
        def planned_service_backend_removals(victims)
          victims.flat_map do |instance|
            ::Sdwan::ServiceBackend.host_routed_services(account: @account, instance: instance).map do |svc|
              { step: "leave_service_backends", service_id: svc.id, slug: svc.slug,
                node_instance_id: instance.id }
            end
          end
        end

        # The mission's OWN replicas, newest first.
        #
        # Resolved through the provenance ProvisionFullStackExecutor stamps
        # (`node.config["mission_id"]`), never a fleet-wide instance query: a
        # bare "newest instances" lookup would happily hand back another
        # mission's — or another tenant's — machines to terminate. Account
        # scoping rides along on the node join because that is where the
        # mission marker lives.
        def mission_replicas(mission)
          ::System::NodeInstance
            .joins(:node)
            .where(system_nodes: { account_id: @account.id })
            .where("system_nodes.config @> ?", { mission_id: mission.id }.to_json)
            .active
            .order(created_at: :desc, id: :desc)
            .to_a
        end

        # Volumes currently attached to the victims — what a removal would
        # delete. Read ONCE: the same list the rail checks is the list the
        # teardown acts on, so nothing can slip in between the two and be
        # deleted unvetted.
        def victim_volumes(victims)
          ::System::ProviderVolume.where(node_instance_id: victims.map(&:id)).to_a
        end

        # Post-teardown ground-truth sweep for ONE victim — the zero-orphan
        # invariant, asserted rather than assumed. Every resource class here
        # has produced a real orphan before: the Sdwan::Peer FK orphan whose
        # instance was gone, the membership mirror left pointing at a dead
        # peer, and volumes whose optional FK is nullified on cascade rather
        # than cleaned up.
        def orphans_for(instance, expected_gone_volume_ids: [])
          found = []

          row = ::System::NodeInstance.find_by(id: instance.id)
          if row && row.status.to_s != "terminated"
            found << { resource: "node_instance", id: instance.id, detail: "status=#{row.status}" }
          end

          peers = ::Sdwan::Peer.where(node_instance_id: instance.id).pluck(:id)
          found << { resource: "sdwan_peer", ids: peers } if peers.any?

          # BY ID, not by FK. ProviderVolume#detach! nulls node_instance_id, so
          # a volume whose delete then failed is orphaned with nothing left
          # pointing at the instance — re-querying the FK would find zero rows
          # and bless the leak. The ids captured before teardown are the only
          # handle that survives the detach. The FK query stays as well, to
          # catch anything attached after that snapshot.
          survivors = ::System::ProviderVolume.where(id: expected_gone_volume_ids).pluck(:id)
          still_attached = ::System::ProviderVolume.where(node_instance_id: instance.id).pluck(:id)
          leaked = (survivors + still_attached).uniq
          found << { resource: "provider_volume", ids: leaked } if leaked.any?

          central = ::System::NodeInstancePeer.find_by(node_instance_id: instance.id)
          if central && central.capabilities.is_a?(Hash) && central.capabilities["sdwan"].present?
            found << { resource: "node_instance_peer_membership", id: central.id }
          end

          found
        end

        # This project's replica floor (APO 3a). The mission owns it —
        # `Ai::Mission#scaling_bounds` resolves the declaration DB-first
        # (mission `watch_policies` → the mission template's
        # default_configuration → Account#settings → SiteSetting → core's
        # constant), so a project that must never drop below N replicas can say
        # so instead of every project sharing this executor's one number.
        #
        # MIN_REPLICAS stays the hard platform minimum: a project may RAISE its
        # floor, never lower it, so no configuration path reaches scale-to-zero
        # through this arm. The rescue is the only fallback that can actually
        # fire — #run resolves the mission through ::Ai::Mission before it ever
        # dispatches a strategy, so the reader is always there; what it cannot
        # promise is that resolving the declaration (a settings read, a
        # template load) succeeds.
        def replica_floor_for(mission)
          [ mission.scaling_bounds.min.to_i, MIN_REPLICAS ].max
        rescue StandardError => e
          Rails.logger.warn("[ScaleProjectExecutor] replica floor unresolved (#{e.class}); " \
                            "using platform minimum #{MIN_REPLICAS}")
          MIN_REPLICAS
        end

        def removal_outputs(prefix: nil, removed: [], detached_peers: [], deleted_volumes: [],
                            removed_backends: [], orphans: [], floor_reached: false)
          empty_outputs.merge(
            removed_node_instance_ids: removed,
            detached_sdwan_peer_ids: detached_peers,
            deleted_storage_volume_ids: deleted_volumes,
            removed_sdwan_service_backend_ids: removed_backends,
            orphans: orphans,
            floor_reached: floor_reached,
            prefix_enforced: prefix
          )
        end

        # `irreversible` + `requires_approval` travel with the RESULT because
        # the descriptor is class-level and this executor's other three
        # strategies are neither. They are a classification for the gate and
        # the audit trail, not the enforcement — that is core's allowlist in
        # AdaptationProposerService#auto_apply?, which admits only the additive
        # strategy and so can never approve a removal.
        def removal_envelope(dry_run:, count:, actions:, outputs:, failures: [])
          {
            dry_run: dry_run ? true : false,
            count: count,
            scaling_strategy: "remove_replicas",
            irreversible: true,
            requires_approval: true,
            planned_actions: prepend_strategy_marker("remove_replicas", actions),
            outputs: outputs,
            failures: failures,
            partial: failures.any? && count.positive?
          }
        end

        # vertical_resize produces a plan only, and NOTHING EXECUTES IT.
        # RollingModuleUpgradeExecutor names the affected instances and
        # returns; there is no batch advancer, health check, or circuit
        # breaker for module upgrades anywhere in the platform (pinned by
        # spec/docs/rolling_upgrade_docs_accuracy_spec.rb). There are no
        # batches to advance either: the upgrade is FLEET-ATOMIC, because the
        # served version is a per-module pointer (IMP-b948ea7fa382).
        # This comment used
        # to explain the plan-only shape as deliberate, by naming a milestone
        # reconciler that would walk the batches through ApprovalRequest —
        # that reconciler was never built, and repeating the promise here made
        # a second caller look supervised. We surface the plan in
        # outputs.rolling_upgrade_plan and leave the side-effect outputs empty;
        # an operator has to perform the upgrade themselves (see
        # docs/tutorials/06-rolling-upgrade.md, "What to do instead").
        def run_vertical_resize(template_id:, module_id:, target_version_id:, dry_run:)
          if dry_run
            return success(
              dry_run: true,
              count: 0,
              scaling_strategy: "vertical_resize",
              planned_actions: [ {
                step: "rolling_module_upgrade_plan",
                template_id: template_id, module_id: module_id, target_version_id: target_version_id
              } ],
              outputs: empty_outputs,
              failures: [],
              partial: false
            )
          end

          inner = executor(::System::Ai::Skills::RollingModuleUpgradeExecutor)
          inner_result = inner.execute(
            template_id: template_id, module_id: module_id,
            target_version_id: target_version_id
          )
          return inner_result unless inner_result[:success]

          plan = inner_result[:data] || {}
          success(
            dry_run: false,
            count: plan[:total_instances].to_i,
            scaling_strategy: "vertical_resize",
            # IMP-b948ea7fa382 — batch_count/batch_size used to be re-exported
            # here. The plan no longer carries them (module upgrades are
            # fleet-atomic), and reading absent keys would have re-published
            # them as nil — a batch story told in nils. Surface the atomic set
            # instead, which is what the plan now means.
            planned_actions: [ { step: "rolling_module_upgrade_plan",
                                 fleet_atomic: true,
                                 affected_instance_ids: plan[:affected_instance_ids],
                                 estimated_total_seconds: plan[:estimated_total_seconds] } ],
            outputs: empty_outputs.merge(rolling_upgrade_plan: plan),
            failures: [],
            partial: false
          )
        end

        def empty_outputs
          { node_ids: [], node_instance_ids: [], sdwan_peer_ids: [],
            storage_volume_ids: [], rolling_upgrade_plan: nil,
            sdwan_service_ids: [], sdwan_service_backend_ids: [] }
        end

        # THE teardown path — the only one in this executor. Both the rollback
        # contract and the remove_replicas strategy go through it, so a fix to
        # either (a missed detach, a swallowed provider error) lands on both;
        # a second teardown written for the scale-in arm is exactly how the
        # rollback path would quietly drift into leaking what the removal path
        # cleans up.
        #
        # VOLUMES FIRST, then instances. VolumeManagementService#delete refuses
        # an attached volume, and after the instance is gone there is nothing
        # left to detach from — so detach-then-delete has to happen while the
        # instance still exists. The rollback path only ever recorded
        # unattached volumes, so this is a no-op reordering there and the
        # correct order the moment storage attach is threaded through a
        # scale-out.
        #
        # BACKEND ROWS BEFORE THE INSTANCE, too (APO-3d). A victim's
        # Sdwan::ServiceBackend rows are resolved from its addresses, and the
        # terminate detaches its overlay peer — so the rows have to go while
        # the instance can still be found by them. Left behind, they keep
        # Traefik dialling a host that no longer exists. The proxy regen is the
        # CALLER's, once per run: this method is called once per victim, and
        # regenerating here would write and reload the dynamic dir N times for
        # an N-victim scale-in.
        #
        # Never raises: both callers collect errors into the outputs envelope.
        # Returns { errors:, terminated:, deleted_volumes:, removed_backends: }
        # — the terminated / deleted / removed lists are what actually
        # succeeded, so the caller reports ground truth rather than what it
        # intended.
        def teardown_resources(node_instance_ids: [], storage_volume_ids: [])
          errors = []
          terminated = []
          deleted_volumes = []
          removed_backends = []

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
            if result.success?
              deleted_volumes << volume_id
            else
              errors << { resource: "provider_volume", id: volume_id, error: result.error }
            end
          rescue StandardError => e
            errors << { resource: "provider_volume", id: volume_id, error: e.message }
          end

          Array(node_instance_ids).reverse_each do |instance_id|
            instance = ::System::NodeInstance.find_by(id: instance_id)
            next unless instance

            removed_backends.concat(leave_service_backends!(instance, errors))

            result = ::System::ProvisioningService.terminate_instance(instance: instance)
            if result.success?
              terminated << instance_id
            else
              errors << { resource: "node_instance", id: instance_id, error: result.error }
            end
          rescue StandardError => e
            errors << { resource: "node_instance", id: instance_id, error: e.message }
          end

          { errors: errors, terminated: terminated, deleted_volumes: deleted_volumes,
            removed_backends: removed_backends }
        end

        # Drops `instance` out of every published service's backend set.
        # Returns the removed row ids; a failure is recorded against the
        # instance and the teardown carries on to the terminate — a stale row
        # is a routing defect, not a reason to leave the VM billing.
        def leave_service_backends!(instance, errors)
          ::Sdwan::ServiceBackend.host_routed_services(account: @account, instance: instance)
                                 .flat_map { |svc| ::Sdwan::ServiceBackend.remove_instance!(service: svc, instance: instance) }
                                 .map(&:id)
        rescue StandardError => e
          errors << { resource: "sdwan_service_backend", id: instance.id, error: e.message }
          []
        end

        def prepend_strategy_marker(strategy, planned_actions)
          marker = { step: "scale_project", scaling_strategy: strategy }
          [ marker ] + Array(planned_actions)
        end
      end
    end
  end
end
