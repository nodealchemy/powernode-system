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
                    network_id: nil, with_storage_gb: nil, dry_run: false,
                    name_prefix: nil, mission_id: nil, **_extras)
          count = count.to_i
          return failure("count must be between 1 and #{MAX_COUNT}") unless count.between?(1, MAX_COUNT)

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
              planned_actions: build_plan(template, count, region, instance_type, network, with_storage_gb),
              outputs: { node_ids: [], node_instance_ids: [], sdwan_peer_ids: [], storage_volume_ids: [] },
              failures: [],
              partial: false
            )
          end

          run_execute(template: template, count: count, region: region,
                      instance_type: instance_type, network: network,
                      with_storage_gb: with_storage_gb,
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
            # step (the runner's rollback reads metadata["last_outputs"],
            # only written by mark_completed, and would orphan the VMs and
            # volumes this loop already created).
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
                # Recorded LOUDLY, because nothing reclaims this volume on its
                # own. The step still returns success — one failed attach must
                # not terminate a whole provisioned fleet — so the runner marks
                # it completed and never dispatches the rollback hook that
                # holds these ids (SkillCompositionRunner#rollback_step! is
                # reachable only from handle_failure). Its FK is nil, so
                # scale-in cannot see it either. What surfaces it is the
                # envelope: `partial` plus this recorded failure, which
                # VerificationService grades as a failing step_N_failures
                # check. Silence here is the failure mode this guard exists
                # to end.
                failures << { step: "attach_volume", node_id: node.id, instance_id: instance.id,
                              volume_id: volume.id, error: att_result.error }
              end
            rescue StandardError => e
              failures << { step: "attach_volume", node_id: node.id, instance_id: instance.id,
                            volume_id: volume.id, error: e.message }
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
        # Known gap, deliberately not closed here: an UNREADABLE value
        # ("plenty", true, {a: 1}) is now indistinguishable from "no storage
        # requested" — silent rather than loud. That is strictly better than the
        # orphaning crash it replaces, but a caller who asked for storage in a
        # shape this executor cannot read still deserves a failure entry.
        def storage_requested?(with_storage_gb)
          with_storage_gb.respond_to?(:to_i) && with_storage_gb.to_i.positive?
        end
      end
    end
  end
end
