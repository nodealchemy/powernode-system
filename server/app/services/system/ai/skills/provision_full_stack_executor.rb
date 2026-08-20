# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Provision a full compute + (optional) network + (optional) storage stack
      # from a NodeTemplate. Composition shape:
      #
      #   loop(create_node + ProvisioningService.provision_instance
      #        [+ Sdwan::PeerEnroller.call, when network_id]
      #        [+ VolumeManagementService.provision then .attach, when with_storage_gb])
      #
      # The executor returns a structured *result set* (created nodes,
      # provisioned instances, volumes, sdwan peer ids) plus a planned-actions
      # log for the audit trail. Polling/wait_for_running is the autonomy
      # reconciler's job — this executor only provisions and returns.
      #
      # Rollback (`self.rollback_provision_full_stack`): reverses the side
      # effects — detach enrolled SDWAN peers, detach-and-delete provisioned
      # volumes, then terminate node instances — using the execution_record's
      # outputs as the source of truth for what was created. Volumes precede
      # instances because delete refuses an attached volume, and detaching one
      # after its instance is terminated asks the provider to detach it from a
      # machine it no longer has.
      #
      # Reference: AI-Driven Provisioning plan slice 4 (M0).
      class ProvisionFullStackExecutor < BaseSkillExecutor
        # Hard upper bound on a single skill invocation. Larger fleet rolls go
        # through rolling_module_upgrade with explicit operator confirmation.
        MAX_COUNT = 50

        skill_descriptor(
          name: "provision_full_stack",
          description: "Provision a full compute+network+storage stack from a template — composes provision_instance + optional storage volume + optional SDWAN peer enrollment",
          category: "devops",
          inputs: {
            template_id: { type: "string", required: true,
                           description: "System::NodeTemplate to instantiate" },
            count: { type: "integer", required: true,
                     description: "Number of node instances to provision (1-#{MAX_COUNT})" },
            provider_region_id: { type: "string", required: true,
                                  description: "System::ProviderRegion target" },
            provider_instance_type_id: { type: "string", required: true,
                                         description: "System::ProviderInstanceType for each instance" },
            network_id: { type: "string", required: false,
                          description: "Sdwan::Network — when present, every instance this step provisions is enrolled onto the network and the NEW peer ids are returned" },
            with_storage_gb: { type: "integer", required: false,
                               description: "When present, provision a per-instance ProviderVolume of this size" },
            dry_run: { type: "boolean", required: false, default: false,
                       description: "Plan only — return projected actions without creating any cloud resources" }
          },
          outputs: {
            dry_run: :boolean,
            count: :integer,
            planned_actions: [ :object ],
            outputs: {
              node_ids: [ :string ],
              node_instance_ids: [ :string ],
              sdwan_peer_ids: [ :string ],
              storage_volume_ids: [ :string ]
            },
            failures: [ :object ],
            partial: :boolean
          },
          rollback: :rollback_provision_full_stack,
          blast_radius: :medium
        )

        binds_to "Fleet Autonomy"

        # Instance-method rollback contract — invoked by `SkillCompositionRunner`
        # via `executor.public_send(:rollback_provision_full_stack, **outputs)`.
        # Receives the recorded outputs as kwargs so the runner can dispatch
        # without knowing the executor's internals.
        # Nodes themselves are cheap shells — left in place so the operator can
        # inspect the failed run. Only NodeInstances and ProviderVolumes are
        # reversed — plus the peers this executor now enrolls.
        #
        # The peer pass is NOT redundant with terminate_instance's auto-detach.
        # That detach lives in ProvisioningService#finalize_termination!, which
        # IS unconditional once reached — but terminate_instance reaches it on
        # only three of its exits (provider NotFound, a successful terminate,
        # and the ResourceNotFoundError rescue). FIVE of its exits never
        # detach: four return Result.err — a blank cloud_instance_id (:239), an
        # UnknownProviderError (:243), a provider-side failure (:268), and the
        # ProviderError rescue (:275) — and the fifth, `rescue ArgumentError`
        # (:279), propagates instead of returning, which matters to a caller
        # deciding whether to clean up. Every one of those is the branch where
        # the loop below records a node_instance error, so the invariant fails
        # exactly where rollback is meant to work, leaving the Sdwan::Peer and
        # its NodeInstancePeer capability mirror live on the fabric. Detach
        # runs FIRST, while the instance rows still resolve; PeerDetacher is a
        # no-op on an already-detached peer, so it is safe unconditionally.
        def rollback_provision_full_stack(node_instance_ids: [], storage_volume_ids: [],
                                          sdwan_peer_ids: [], **_extras)
          errors = []

          Array(sdwan_peer_ids).reverse_each do |peer_id|
            peer = ::Sdwan::Peer.where(account_id: @account.id).find_by(id: peer_id)
            next unless peer

            ::Sdwan::PeerDetacher.call(node_instance: peer.node_instance, network: peer.network)
          rescue StandardError => e
            errors << { resource: "sdwan_peer", id: peer_id, error: e.message }
          end

          # VOLUMES BEFORE INSTANCES, detach-then-delete (IMP-093378034fb4).
          # The DETACH is what `VolumeManagementService#delete` requires — it
          # refuses an attached volume outright — so it became load-bearing the
          # moment run_execute started attaching what it provisions; without it
          # this rollback fails every volume with "Volume is attached, detach
          # first", moving the leak rather than closing it. The ORDER is for
          # the provider rather than the row: `terminate!` is a status
          # transition, so the NodeInstance row still resolves afterwards, but
          # the provider-side machine is gone and detaching from it is no
          # longer meaningful.
          # Deliberately the same shape as ScaleProjectExecutor#teardown_resources,
          # which reached this order first; the two rollbacks are separate
          # methods on separate executors, so this is stated rather than shared.
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

          { success: errors.empty?, errors: errors }
        end

        protected

        # `**_extras` swallows context kwargs that PlanComposerService injects
        # into every step's inputs (notably `brief`) so the runner's
        # `executor.execute(**inputs)` invocation doesn't raise ArgumentError.
        def perform(template_id:, count:, provider_region_id:, provider_instance_type_id:,
                    network_id: nil, with_storage_gb: nil, storage_gb: nil, dry_run: false,
                    name_prefix: nil, mission_id: nil, **_extras)
          count = count.to_i
          return failure("count must be between 1 and #{MAX_COUNT}") unless count.between?(1, MAX_COUNT)

          storage_declared = self.class.resolve_storage_gb(with_storage_gb, storage_gb)

          template = ::System::NodeTemplate.where(account_id: @account.id).find_by(id: template_id)
          return failure("template not found: #{template_id}") unless template

          region = ::System::ProviderRegion.where(account_id: @account.id).find_by(id: provider_region_id)
          return failure("provider region not found: #{provider_region_id}") unless region

          instance_type = ::System::ProviderInstanceType.where(account_id: @account.id).find_by(id: provider_instance_type_id)
          return failure("provider instance type not found: #{provider_instance_type_id}") unless instance_type

          network = nil
          if network_id.present?
            network = ::Sdwan::Network.where(account_id: @account.id).find_by(id: network_id)
            return failure("sdwan network not found: #{network_id}") unless network
          end

          if dry_run
            return success(
              dry_run: true,
              count: count,
              planned_actions: build_plan(template, count, region, instance_type, network, storage_declared),
              outputs: { node_ids: [], node_instance_ids: [], sdwan_peer_ids: [], storage_volume_ids: [] },
              # The dry run is the operator's approval card, and it consults
              # the same storage answer as the loop (storage_requested?'s
              # documented single-answer contract) — so a declaration the
              # real run would record failure entries for must not preview
              # as a clean plan. Nothing is created here, so `partial`
              # stays false.
              failures: dry_run_storage_failures(count, storage_declared),
              partial: false
            )
          end

          run_execute(template: template, count: count, region: region,
                      instance_type: instance_type, network: network,
                      with_storage_gb: storage_declared,
                      name_prefix: name_prefix, mission_id: mission_id)
        end

        private

        def run_execute(template:, count:, region:, instance_type:, network:, with_storage_gb:,
                        name_prefix: nil, mission_id: nil)
          node_ids = []
          node_instance_ids = []
          sdwan_peer_ids = []
          storage_volume_ids = []
          failures = []
          planned_actions = []

          count.times do |i|
            node = create_node!(template: template, index: i,
                                name_prefix: name_prefix, mission_id: mission_id)
            node_ids << node.id
            planned_actions << { step: "create_node", node_id: node.id, name: node.name }

            prov_result = ::System::ProvisioningService.provision_instance(
              node: node,
              provider_region_id: region.id,
              provider_instance_type_id: instance_type.id
            )

            unless prov_result.success?
              failures << { step: "provision_instance", node_id: node.id, error: prov_result.error }
              next
            end

            instance = prov_result.data[:instance]
            node_instance_ids << instance.id
            planned_actions << { step: "provision_instance", node_id: node.id, instance_id: instance.id }

            # IMP-94f778f92dba — this is the only thing that puts a new
            # instance ON the fabric. The previous implementation compiled
            # Sdwan::TopologyCompiler.compile_for_network once at the end,
            # which maps the network's ALREADY-EXISTING peers and creates
            # nothing: sdwan_peer_ids reported the pre-existing fleet, so a
            # "scale-out produced a peer" oracle passed vacuously. Enroll
            # per instance instead, and guard it like every other leg —
            # push to `failures` and continue, so a raise can't take out the
            # step and orphan the VMs and volumes this loop already created.
            # (IMP-2182fd8fcdee: rollback_step! now also reads
            # metadata["failure_outputs"], not just the mark_completed-written
            # "last_outputs" — but an escaping raise is turned into a bare
            # failure(e.message) by BaseSkillExecutor#execute, which carries no
            # ids, so guarding the leg here is still what protects them.)
            if network
              begin
                peer = ::Sdwan::PeerEnroller.call(network: network, node_instance: instance)
                sdwan_peer_ids << peer.id
                planned_actions << { step: "attach_sdwan_peer", network_id: network.id,
                                     instance_id: instance.id, peer_id: peer.id }
              rescue StandardError => e
                failures << { step: "attach_sdwan_peer", node_id: node.id,
                              instance_id: instance.id, error: e.message }
              end
            end

            # Requested-but-unusable fails LOUD, per node — the ratified
            # 4db30efae network-declaration fork, mapped onto the same
            # declaration class (IMP-f85254148755): a caller who DECLARED
            # storage in a shape this executor cannot read gets a failure
            # entry, not a silent "none requested". Absent and explicit
            # non-positive stay silent below — those genuinely request
            # nothing (IMP-33fa6c51f05d) and the estimator quotes no line.
            if storage_unreadable?(with_storage_gb)
              failures << { step: "provision_storage", node_id: node.id,
                            error: unreadable_storage_error(with_storage_gb) }
              next
            end

            next unless storage_requested?(with_storage_gb)

            vol_result = ::System::VolumeManagementService.provision(
              account: @account,
              region: region,
              volume_type: nil,
              size_gb: with_storage_gb.to_i,
              options: { name: "#{node.name}-data" }
            )
            unless vol_result.success?
              failures << { step: "provision_storage", node_id: node.id, error: vol_result.error }
              next
            end

            volume = vol_result.data[:volume]
            storage_volume_ids << volume.id
            planned_actions << { step: "provision_storage", instance_id: instance.id,
                                 volume_id: volume.id, size_gb: with_storage_gb.to_i }

            # IMP-093378034fb4 — provisioning without attaching left every
            # volume carrying a nil `node_instance_id`, and that FK is how BOTH
            # the scale-in teardown (ScaleProjectExecutor#victim_volumes) and
            # its zero-orphan sweep (#orphans_for) reach a victim's volumes. So
            # the check built to catch a leaked volume was structurally unable
            # to see one: scale-in reported ZERO orphans while the volume
            # billed on indefinitely. Attaching is what puts the row in reach
            # of the teardown — and of every operator view keyed on the same FK.
            #
            # Guarded like the peer leg above, and for the same reason: attach
            # re-raises ArgumentError and VolumeError (no free device paths), so
            # an unguarded call would take out the whole step and orphan the
            # instances and volumes this loop already created.
            begin
              att_result = ::System::VolumeManagementService.attach(volume: volume, instance: instance)
              if att_result.success?
                planned_actions << { step: "attach_volume", instance_id: instance.id,
                                     volume_id: volume.id, device: att_result.data[:device] }
              else
                # IMP-0d9e7ca7b166 — recorded loudly AND reclaimed, because
                # nothing downstream can reach this volume. Its FK is nil, and
                # that FK is how both the scale-in teardown
                # (ScaleProjectExecutor#victim_volumes) and its orphan sweep
                # find a victim's volumes. This executor's own rollback DOES
                # hold the id, but it is dispatched by
                # SkillCompositionRunner#rollback_step!, reachable only from
                # handle_failure — and this step deliberately returns SUCCESS
                # so one bad attach cannot terminate a whole provisioned fleet.
                # So the rollback never runs and the volume billed forever.
                # In-branch reclaim is the only path left, which is what
                # RelocateWorkloadExecutor#refuse_blue_green_cutover! concluded
                # for the same structural reason.
                #
                # The envelope stays loud either way: `partial` plus the
                # recorded failure is what VerificationService grades.
                failures << { step: "attach_volume", node_id: node.id, instance_id: instance.id,
                              volume_id: volume.id, error: att_result.error }
                reclaim_unattachable_volume!(volume: volume, node: node, instance: instance,
                                             failures: failures,
                                             storage_volume_ids: storage_volume_ids,
                                             planned_actions: planned_actions)
              end
            rescue StandardError => e
              failures << { step: "attach_volume", node_id: node.id, instance_id: instance.id,
                            volume_id: volume.id, error: e.message }
              # Same reclaim on the raise path. attach re-raises ArgumentError
              # and VolumeError (no free device paths), and a volume orphaned by
              # a raise is exactly as unreachable as one orphaned by an error
              # return — guarding only the `else` would fix half the defect.
              reclaim_unattachable_volume!(volume: volume, node: node, instance: instance,
                                           failures: failures,
                                           storage_volume_ids: storage_volume_ids,
                                           planned_actions: planned_actions)
            end
          end

          success(
            dry_run: false,
            count: count,
            planned_actions: planned_actions,
            outputs: {
              node_ids: node_ids,
              node_instance_ids: node_instance_ids,
              sdwan_peer_ids: sdwan_peer_ids,
              storage_volume_ids: storage_volume_ids
            },
            failures: failures,
            partial: failures.any? && (node_instance_ids.any? || storage_volume_ids.any?)
          )
        end

        # F3 (IMP 019fe4c4-e813): name_prefix carries the mission's marker
        # (e.g. the charter's dryrun- blast-radius prefix) into node names —
        # instance names derive from the node's, so the prefix reaches the
        # substrate. mission_id lands in node.config so created nodes and
        # their instances are provenance-queryable regardless of naming.
        # IMP-0d9e7ca7b166 — delete a volume this step provisioned but could
        # not attach, and stop advertising it as provisioned storage.
        #
        # Why delete rather than leave it for a human: a volume with a nil
        # node_instance_id is not merely untidy, it is UNREACHABLE. Every
        # reclaim path keys on that FK, and the one path that holds the raw id
        # (this executor's rollback) is never dispatched for a step that
        # returns success. Leaving the row means it bills indefinitely with no
        # surface that can find it.
        #
        # No detach first: the attach is what failed, so the volume is not
        # attached — but `attached?` is still checked, because a partially
        # applied attach is exactly the case where the naive assumption is
        # wrong, and VolumeManagementService#delete refuses an attached volume
        # outright rather than silently.
        #
        # A failed reclaim is recorded as its own `reclaim_volume` failure and
        # the id is KEPT in storage_volume_ids. That is deliberate: if the row
        # survives, the envelope must still name it, or this guard would just
        # move the leak behind a quieter layer.
        def reclaim_unattachable_volume!(volume:, node:, instance:, failures:, storage_volume_ids:,
                                         planned_actions:)
          if volume.attached?
            detach = ::System::VolumeManagementService.detach(volume: volume)
            unless detach.success?
              failures << { step: "reclaim_volume", node_id: node.id, instance_id: instance.id,
                            volume_id: volume.id, error: detach.error }
              return false
            end
          end

          result = ::System::VolumeManagementService.delete(volume: volume)
          if result.success?
            storage_volume_ids.delete(volume.id)
            # Recorded as its own action. A SILENT reclaim is its own problem:
            # the envelope would show a volume provisioned, an attach failed,
            # and no trace of what became of the volume — and any wrapper that
            # reports what IT reclaimed (RelocateWorkloadExecutor's blue_green
            # refusal) now legitimately finds nothing left to reclaim, so this
            # is the only place the reclaim is observable.
            planned_actions << { step: "reclaim_volume", instance_id: instance.id,
                                 volume_id: volume.id }
            true
          else
            failures << { step: "reclaim_volume", node_id: node.id, instance_id: instance.id,
                          volume_id: volume.id, error: result.error }
            false
          end
        rescue StandardError => e
          failures << { step: "reclaim_volume", node_id: node.id, instance_id: instance.id,
                        volume_id: volume.id, error: e.message }
          false
        end

        def create_node!(template:, index:, name_prefix: nil, mission_id: nil)
          base = [ name_prefix.presence, template.name.parameterize ].compact.join("-")
          node_name = "#{base}-#{index + 1}-#{SecureRandom.hex(3)}"
          ::System::Node.create!(
            account: @account,
            name: node_name,
            node_template: template,
            enabled: true,
            config: mission_id.present? ? { "mission_id" => mission_id } : {}
          )
        end

        def build_plan(template, count, region, instance_type, network, with_storage_gb)
          steps = []
          count.times do |i|
            steps << { step: "create_node", index: i, template_id: template.id, template_name: template.name }
            steps << { step: "provision_instance", index: i,
                       provider_region_id: region.id, provider_instance_type_id: instance_type.id }
            steps << { step: "attach_sdwan_peer", index: i, network_id: network.id } if network
            if storage_requested?(with_storage_gb)
              steps << { step: "provision_storage", index: i, size_gb: with_storage_gb.to_i }
              # The attach is a separate state change and is planned as one, so
              # the dry run enumerates what execute actually does and an oracle
              # can grade "the scale-out attached storage" rather than only
              # "a volume was created" (IMP-093378034fb4).
              steps << { step: "attach_volume", index: i }
            end
          end
          steps
        end

        # Whether this run was asked for a volume at all — the single answer
        # both the dry-run plan and the provisioning loop consult, so the
        # approval card and the actuator cannot disagree about it.
        #
        # IMP-33fa6c51f05d — the guards here used to be `blank?`/`present?`, and
        # in Ruby `0.blank?` is FALSE, so an explicit `with_storage_gb: 0`
        # passed straight through to VolumeManagementService.provision.
        #
        # What that actually produced, verified rather than assumed: NOT a
        # leaked 0 GB volume. ProviderVolume validates `size_gb` as
        # `greater_than: 0`, so `create!` raised RecordInvalid and the service's
        # `rescue StandardError` returned an err Result — every time. The harm
        # was one fabricated `provision_storage` failure PER NODE and a
        # `partial: true` envelope, which is exactly what VerificationService
        # grades as a failing step_N_failures check. A plan that asked for no
        # storage reported itself as a partially-failed provisioning run.
        #
        # `respond_to?(:to_i)` covers a SECOND, worse shape that `blank?` also
        # let through — `true.blank?`, `{a: 1}.blank?` and `[50].blank?` are all
        # false, so those reached `.to_i` and raised NoMethodError. That raise
        # escaped the per-node legs and failed the whole step via `failure(...)`,
        # which returns no `:data` at all: the nodes and instances this loop had
        # already created were handed back to nobody. Screening them here turns
        # an orphan-producing crash into a clean skip. (Only EMPTY Hash/Array
        # and `false` were ever screened by `blank?`.)
        #
        # Non-positive now reads the same way here as in
        # CostEstimatorService#declared_gb and PlanComposerService
        # #brief_storage_gb. The composer never ADDS a non-positive, so the
        # reachable writers are a hand-authored plan_data, a MissionComposer
        # output, and an operator-supplied input — the direct-dispatch paths the
        # composer's `||=` is documented to let win. This hardens those.
        #
        # An UNREADABLE value ("plenty", true, {a: 1}) is NOT silent: it takes
        # the loud lane via #storage_unreadable? (IMP-f85254148755, closing
        # the gap this comment used to record) — this predicate only answers
        # the SIZE question for values that read as numbers.
        #
        # IMP-e1903a42c1ab — published at CLASS scope because the answer is
        # consulted by executors that COMPOSE this one and must not re-derive
        # it. RelocateWorkloadExecutor's blue_green cutover guard has to know
        # whether a missing volume is a shortfall or a legitimate "none
        # requested" before it refuses to tear a workload's sources down; a
        # second copy of the expression is exactly the disagreement between
        # card and actuator this predicate exists to prevent, and a
        # `present?`-shaped copy would refuse every zero-storage relocate.
        def self.storage_requested?(with_storage_gb)
          with_storage_gb.respond_to?(:to_i) && with_storage_gb.to_i.positive?
        end

        # The single storage DECLARATION reader — one implementation, three
        # surfaces (this executor plus the two that compose it).
        #
        # `storage_gb` is a tolerated alias for hand-authored plan_data,
        # resolved in exactly CostEstimatorService#declared_gb's read order:
        # `with_storage_gb` first, first PRESENT value wins — so an explicit
        # `with_storage_gb: 0` beats a positive alias, and both surfaces read
        # "no storage requested" for it. Before IMP-f85254148755 the alias fell
        # into `**_extras` here, so a plan carrying it alone was QUOTED for a
        # volume this executor never provisioned — the same quote/actuator key
        # disagreement class IMP-051509357291 removed. `with_storage_gb` stays
        # the only ADVERTISED input; the alias is a compatibility read on both
        # sides, not a descriptor entry.
        #
        # IMP-01a774a80f7a — published at CLASS scope for the same reason the
        # two predicates were, and with a sharper consequence. The predicates
        # answer "what does this value MEAN"; this answers "which value are we
        # even reading", and a composing executor that never asked the question
        # read `nil` for a declaration its caller made under the other name.
        # RelocateWorkloadExecutor dropped the alias into `**_extras` and
        # forwarded nil, so its blue_green cutover guard saw storage_declared?
        # (nil) — false — skipped the storage arm, and terminated the sources
        # against a target with no disk, with no volume, no failure entry and
        # no refusal clause anywhere in the run. A second copy of the
        # expression would be the same divergence one refactor later, so the
        # resolution lives here with the order it has to agree with.
        #
        # IMP-b439270dab0d — the ORDER now lives in Shared::StorageSizeResolution
        # (core). Three of the four surfaces that read it are core, and core
        # cannot depend on an extension: beyond the invariant, core mode runs
        # with no system extension loaded, so a core caller reaching for this
        # class would be a NameError on every install without it. This keeps its
        # name and its callers and delegates, so there is still exactly one
        # order — the shape Shared::SdwanNetworkResolution already uses for the
        # fabric declaration.
        def self.resolve_storage_gb(with_storage_gb, storage_gb = nil)
          ::Shared::StorageSizeResolution.resolve(with_storage_gb, storage_gb)
        end

        def storage_requested?(with_storage_gb)
          self.class.storage_requested?(with_storage_gb)
        end

        # The loud half of the storage fork (IMP-f85254148755, ruled by the
        # 4db30efae precedent): a value that was DECLARED (present after the
        # alias resolution in #perform) but has no trustworthy numeric
        # reading is requested-but-unusable. An explicit non-positive number
        # (0, "0", -50) is NOT unreadable — it is a legitimate "no storage"
        # answer (IMP-33fa6c51f05d) and stays silent, matching
        # CostEstimatorService#declared_gb's quote of no line.
        #
        # IMP-e1903a42c1ab — published at CLASS scope alongside
        # `storage_requested?`, and for a sharper reason than symmetry: this
        # lane creates NO volume, so a composing executor that asks only "was
        # a positive size requested?" reads a stack with no disk as a stack
        # that wanted none. RelocateWorkloadExecutor's cutover guard needs
        # "was storage DECLARED?" — the union of the two predicates — before
        # it tears a workload's sources down.
        def self.storage_unreadable?(value)
          return false unless value.present?         # absent — genuinely not requested
          return false if storage_requested?(value)  # readable and positive — provisions
          !numeric_reading?(value)
        end

        def storage_unreadable?(value)
          self.class.storage_unreadable?(value)
        end

        # Shapes with a trustworthy numeric reading: real numbers, and strings
        # that parse as one ("0", "-50"). `"plenty".to_i == 0` is why `to_i`
        # alone cannot tell an explicit zero from a shape that merely failed
        # to parse. Class-scope only — its sole caller is the class-scope
        # `storage_unreadable?` above, so an instance delegator would be dead
        # the moment it was written.
        def self.numeric_reading?(value)
          value.is_a?(Numeric) ||
            (value.is_a?(String) && !Float(value, exception: false).nil?)
        end

        def unreadable_storage_error(value)
          "storage declared but unreadable: #{value.inspect.truncate(120)} — " \
            "with_storage_gb must be a positive integer count of GB; no volume provisioned"
        end

        # Per-index failure entries for the dry-run envelope when the storage
        # declaration is unreadable — the preview of the per-node entries the
        # real run records. No nodes exist yet, so entries carry the loop
        # index instead of a node_id.
        def dry_run_storage_failures(count, storage_declared)
          return [] unless storage_unreadable?(storage_declared)

          Array.new(count) do |i|
            { step: "provision_storage", index: i,
              error: unreadable_storage_error(storage_declared) }
          end
        end
      end
    end
  end
end
