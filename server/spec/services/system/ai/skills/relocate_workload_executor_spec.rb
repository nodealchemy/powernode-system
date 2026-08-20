# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
RSpec.describe System::Ai::Skills::RelocateWorkloadExecutor do
  let(:account)        { create(:account) }
  let(:mission)        { create(:ai_mission, account: account, mission_type: "infrastructure") }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:provider)       { create(:system_provider, account: account) }
  let(:from_region)    { create(:system_provider_region, account: account, provider: provider) }
  let(:to_region)      { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type)  { create(:system_provider_instance_type, account: account, provider: provider) }
  let(:exec)           { described_class.new(account: account) }

  let(:source_node)     { create(:system_node, account: account, node_template: template, name: "src-1") }
  let(:source_instance) { create(:system_node_instance, :running, node: source_node) }

  let(:new_instance_stub) { instance_double("System::NodeInstance", id: SecureRandom.uuid) }

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, instance-method rollback, and high blast_radius" do
      d = described_class.descriptor

      expect(d[:name]).to eq("relocate_workload")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :project_id, :required)).to be true
      expect(d.dig(:inputs, :from_region_id, :required)).to be true
      expect(d.dig(:inputs, :to_region_id, :required)).to be true
      expect(d.dig(:inputs, :cutover_strategy, :required)).to be true
      expect(d.dig(:inputs, :source_instance_ids, :required)).to be true
      expect(d.dig(:outputs, :outputs)).to include(:node_instance_ids, :sdwan_peer_ids,
                                                    :storage_volume_ids, :terminated_instance_ids)
      expect(d[:rollback]).to eq(:rollback_relocate_workload)
      expect(d[:requires_approval]).to be true
      expect(d[:blast_radius]).to eq(:high)
    end
  end

  describe "#execute" do
    context "with an unknown cutover_strategy" do
      it "rejects" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "bogus",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [ source_instance.id ])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/cutover_strategy must be/)
      end
    end

    context "with an empty source set" do
      it "rejects" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/source_instance_ids must contain/)
      end
    end

    context "with a missing project" do
      it "returns failure" do
        r = exec.execute(project_id: SecureRandom.uuid, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [ SecureRandom.uuid ])
        expect(r[:success]).to be false
        expect(r[:error]).to match(/project not found/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without provisioning or terminating" do
        expect(::System::ProvisioningService).not_to receive(:provision_instance)
        expect(::System::ProvisioningService).not_to receive(:terminate_instance)

        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 2,
                         source_instance_ids: [ source_instance.id ], dry_run: true)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:dry_run]).to be true
        expect(d[:cutover_strategy]).to eq("blue_green")
        expect(d[:planned_actions].any? { |a| a[:step] == "create_node" }).to be true
        expect(d[:planned_actions].any? { |a| a[:step] == "provision_instance" }).to be true
        expect(d[:planned_actions].any? { |a| a[:step] == "terminate_source" }).to be true
      end
    end

    # IMP-9fff24306a2c — the dry-run plan IS the approval card for a :high
    # blast_radius skill, so its ordering has to match the path it describes.
    # The real run provisions and attaches each volume INSIDE the target
    # provisioning loop (ProvisionFullStackExecutor#run_execute), which for
    # blue_green completes in full before terminate_step! touches the source.
    context "in dry_run mode with storage" do
      let(:storage_steps) { %w[provision_storage attach_volume] }
      let(:plan) do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: strategy,
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 2,
                         source_instance_ids: [ source_instance.id ],
                         with_storage_gb: 25, dry_run: true)
        expect(r[:success]).to be true
        r[:data][:planned_actions]
      end
      let(:step_names) { plan.map { |a| a[:step] } }

      context "with the blue_green strategy" do
        let(:strategy) { "blue_green" }

        it "places every storage step before the first terminate_source" do
          first_terminate = step_names.index("terminate_source")
          expect(first_terminate).not_to be_nil

          storage_positions = step_names.each_index.select { |i| storage_steps.include?(step_names[i]) }
          expect(storage_positions.size).to eq(4) # provision + attach, per target
          expect(storage_positions.max).to be < first_terminate
        end

        it "groups each target's storage with that target's own provision steps" do
          # IMP-666a6e904650 — the card names the run's own emitted steps:
          # the real path creates the Node, then provisions its instance
          # (two state changes, two steps), and its storage step is
          # provision_storage. One collapsed provision_target_instance
          # understated the run by a step per target.
          expect(step_names).to eq(%w[
            relocate_workload
            create_node provision_instance provision_storage attach_volume
            create_node provision_instance provision_storage attach_volume
            terminate_source
          ])

          # The pair carries the index of the instance it belongs to, so the
          # card reads per-target rather than as an undifferentiated tail.
          expect(plan.select { |a| storage_steps.include?(a[:step]) }.map { |a| a[:index] })
            .to eq([ 0, 0, 1, 1 ])
          expect(plan.select { |a| a[:step] == "provision_storage" }.map { |a| a[:size_gb] })
            .to eq([ 25, 25 ])
        end

        it "orders each target's steps node -> instance -> peer -> storage -> attach, as the run does" do
          network = ::Sdwan::Network.create!(account_id: account.id, name: "reloc-net-#{SecureRandom.hex(3)}")

          r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                           to_region_id: to_region.id, cutover_strategy: "blue_green",
                           template_id: template.id,
                           provider_instance_type_id: instance_type.id, count: 2,
                           source_instance_ids: [ source_instance.id ],
                           network_id: network.id, with_storage_gb: 25, dry_run: true)

          expect(r[:success]).to be true
          expect(r[:data][:planned_actions].map { |a| a[:step] }).to eq(%w[
            relocate_workload
            create_node provision_instance attach_sdwan_peer provision_storage attach_volume
            create_node provision_instance attach_sdwan_peer provision_storage attach_volume
            terminate_source
          ])
        end
      end

      context "with the drain strategy" do
        let(:strategy) { "drain" }

        it "places every storage step after the last terminate_source" do
          last_terminate = step_names.rindex("terminate_source")
          expect(last_terminate).not_to be_nil

          storage_positions = step_names.each_index.select { |i| storage_steps.include?(step_names[i]) }
          expect(storage_positions.size).to eq(4)
          expect(storage_positions.min).to be > last_terminate
        end

        it "terminates the source before provisioning any target resource" do
          expect(step_names).to eq(%w[
            relocate_workload
            terminate_source
            create_node provision_instance provision_storage attach_volume
            create_node provision_instance provision_storage attach_volume
          ])
        end
      end
    end

    # IMP-666a6e904650 — blue_green's run refuses the teardown when the target
    # stack comes up empty or off-fabric (the blue_green_cutover guard in
    # #run_execute), so an unconditional terminate_source promised a
    # destruction the run may (correctly) decline. The step stays on the card
    # — the operator consents to the intent — but marked conditional with the
    # guard named, so the operator sees both the intent and the safety.
    context "terminate_source marking on the approval card" do
      # IMP-4e5b78f0b737 — the marking is applied by a loop over EVERY source
      # (build_plan#terminate_steps), so the card must be built from more than
      # one source or the `all(...)` sweeps below run over a one-element array
      # and a regression that marks only the first entry passes green. The
      # sources are a per-call-site argument for the same reason: an example
      # that wants a different source set says so rather than inheriting one.
      let(:second_source_node)     { create(:system_node, account: account, node_template: template, name: "src-2") }
      let(:second_source_instance) { create(:system_node_instance, :running, node: second_source_node) }
      let(:both_source_ids)        { [ source_instance.id, second_source_instance.id ] }

      # IMP-f5532c5c5bd6 — the dry run must not preview a clean plan for a
      # declaration the real run already refuses.
      #
      # ProvisionFullStackExecutor emits dry_run_storage_failures for exactly
      # this input, with the rationale stated in its own comment: "a declaration
      # the real run would record failure entries for must not preview as a
      # clean plan". Relocate never composes PFSE for the preview — it builds
      # its own plan and returned `failures: []` unconditionally — so the
      # operator's :high blast-radius card showed the storage steps absent, a
      # conditional storage-unready clause about a volume appearing nowhere in
      # the plan, and ZERO failures.
      #
      # Refused at the DOOR rather than previewed-with-failures (operator's
      # decided option 2): the end-to-end path ALREADY refuses this input — see
      # "refuses every declared-but-unreadable storage shape" below — so
      # continuing buys nothing and costs a full provision-and-reclaim cycle for
      # an input diagnosable before any work starts.
      it "refuses a declared-but-unreadable storage value instead of previewing a clean plan" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 2,
                         source_instance_ids: both_source_ids,
                         with_storage_gb: "plenty", dry_run: true)

        expect(r[:success]).to be(false),
                               "the card previewed a clean plan for a declaration the real run refuses"
        expect(r[:error]).to include("unreadable")
        # The size is UNKNOWN on this branch — quoting with_storage_gb.to_i
        # would render an authoritative "0 GB" for a value never read.
        expect(r[:error]).not_to include("0 GB")
      end

      def card(strategy:, network_id: nil, source_ids: both_source_ids, with_storage_gb: nil)
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: strategy,
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 2,
                         source_instance_ids: source_ids,
                         network_id: network_id, with_storage_gb: with_storage_gb,
                         dry_run: true)
        expect(r[:success]).to be true
        r[:data][:planned_actions]
      end

      # IMP-6b497651d670 + IMP-bb73f7154f27 — the card must disclose BOTH
      # sides of every refusal arm on this :high blast-radius skill: the
      # guard that may decline the terminate (now undersized, subsuming
      # empty, per the :233 undercount hole) AND what happens to the fresh
      # target stack when it does (reclaimed; sources untouched).
      it "marks EVERY blue_green terminate step conditional, naming the guard, the undersized refusal, and the reclaim" do
        terminate = card(strategy: "blue_green").select { |a| a[:step] == "terminate_source" }

        # One entry per source, in the order they were given: this is what
        # makes the sweeps below sweep (IMP-4e5b78f0b737).
        expect(terminate.map { |a| a[:instance_id] }).to eq(both_source_ids)
        expect(terminate).to all(include(conditional: true, guard: "blue_green_cutover"))

        # ANCHORED, and pinned by what this branch must NOT say. The network
        # flavor reads "...comes up undersized or off-fabric (not fully
        # enrolled on network <id>)...", which CONTAINS every substring the
        # no-network flavor was matched on, so an unanchored /undersized/
        # could not tell the two branches apart: collapsing build_plan's
        # ternary to always emit the network flavor — dangling nil
        # interpolation and all — passed. The exclusion below is what kills
        # that mutant; the anchor keeps the opening wording from drifting
        # without pinning the operator prose word for word.
        conditions = terminate.map { |a| a[:condition] }
        expect(conditions).to all(match(/\Askipped when the target stack comes up undersized/))
        expect(conditions).to all(match(/target stack is reclaimed/).and(match(/sources are left untouched/)))
        expect(conditions.join(" | ")).not_to match(/off-fabric|network/)
      end

      it "names the requested network in the condition when enrollment also gates the cutover" do
        network = ::Sdwan::Network.create!(account_id: account.id, name: "reloc-net-#{SecureRandom.hex(3)}")
        terminate = card(strategy: "blue_green", network_id: network.id)
                      .select { |a| a[:step] == "terminate_source" }

        expect(terminate.map { |a| a[:instance_id] }).to eq(both_source_ids)
        expect(terminate).to all(include(conditional: true, guard: "blue_green_cutover"))
        expect(terminate.map { |a| a[:condition] })
          .to all(match(/off-fabric/).and(include(network.id)).and(match(/target stack is reclaimed/)))
      end

      # IMP-e1903a42c1ab — the guard grew a THIRD arm (the storage leg), and a
      # :high blast-radius card that names only two states a narrower guard
      # than the run enforces. Disclosed only when storage was actually
      # requested, and screened by the same predicate the provisioning leg
      # uses: an explicit 0 requests nothing, so promising a storage refusal
      # for it would describe a refusal the run cannot reach.
      it "discloses the storage arm of the guard only when storage was requested" do
        requested = card(strategy: "blue_green", with_storage_gb: 25)
                      .select { |a| a[:step] == "terminate_source" }
        expect(requested.map { |a| a[:condition] })
          .to all(match(/storage-unready/).and(include("25")).and(match(/target stack is reclaimed/)))

        # The declared-but-unreadable half of this example MOVED, deliberately
        # (IMP-f5532c5c5bd6). It used to assert that such a value still
        # produces a card — one planning no storage steps but carrying a
        # storage-unready clause. That card was the defect: it previewed a
        # clean plan (zero failures) for a declaration the run already refuses.
        # The value is now refused at the door, so there is no card to disclose
        # anything on, and the assertion lives in
        # "refuses a declared-but-unreadable storage value instead of
        # previewing a clean plan" above.

        # A 0 is "no storage", not "storage missing" (ProvisionFullStackExecutor
        # #storage_requested?) — the clause must be absent, not merely reworded.
        none = card(strategy: "blue_green", with_storage_gb: 0)
                 .select { |a| a[:step] == "terminate_source" }
        expect(none.map { |a| a[:condition] }.join(" | ")).not_to match(/storage/)
        expect(none.map { |a| a[:condition] }).to all(match(/\Askipped when the target stack comes up undersized/))
      end

      # Negative control (positive twins above): drain terminates FIRST — no
      # guard exists on its path, so a conditional marker would promise a
      # safety the run does not have.
      it "leaves every drain terminate step unconditional, one per source" do
        # THREE sources against count: 2 targets, so the entries are counted
        # per SOURCE and cannot be coming from the target loop — with two of
        # each, "one terminate per target" is indistinguishable from "one per
        # source". Exact shape, in order: a marker leaking onto any entry, or
        # a step going missing, reds this.
        terminate = card(strategy: "drain", source_ids: both_source_ids + [ source_instance.id ])
                      .select { |a| a[:step] == "terminate_source" }

        expect(terminate).to eq([
          { step: "terminate_source", instance_id: source_instance.id },
          { step: "terminate_source", instance_id: second_source_instance.id },
          { step: "terminate_source", instance_id: source_instance.id }
        ])
      end
    end

    # IMP-33fa6c51f05d — this plan is built here, but the storage it describes
    # is provisioned by the executor this one delegates to
    # (ProvisionFullStackExecutor, via #provision_target!). That executor now
    # screens a non-positive with_storage_gb, so listing the pair here for a 0
    # would promise a volume the run will not create — on the approval card of
    # a :high blast-radius skill. Same guard, one seam.
    context "in dry_run mode with a non-positive with_storage_gb" do
      it "plans no storage steps for 0" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 2,
                         source_instance_ids: [ source_instance.id ],
                         with_storage_gb: 0, dry_run: true)

        expect(r[:success]).to be true
        expect(r[:data][:planned_actions].map { |a| a[:step] }).to eq(%w[
          relocate_workload
          create_node provision_instance
          create_node provision_instance
          terminate_source
        ])
      end

      # Positive control: the identical call with a positive value still
      # carries the pair, so the example above cannot pass off a broken
      # fixture as the guard working.
      it "still plans the storage pair for a positive value" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 2,
                         source_instance_ids: [ source_instance.id ],
                         with_storage_gb: 25, dry_run: true)

        expect(r[:data][:planned_actions].map { |a| a[:step] })
          .to include("provision_storage", "attach_volume")
      end
    end

    context "blue_green execute (provisioning + termination stubbed at the service layer)" do
      let(:ok_prov) do
        ::System::Runtime::Result.ok(data: { instance: new_instance_stub, cloud_instance_id: "ci-bg" })
      end
      let(:ok_terminate) { ::System::Runtime::Result.ok }

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(ok_prov)
        allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(ok_terminate)
      end

      it "provisions the target stack first, then terminates the source" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [ source_instance.id ])

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:cutover_strategy]).to eq("blue_green")
        expect(d[:outputs][:node_instance_ids].size).to eq(1)
        expect(d[:outputs][:terminated_instance_ids]).to include(source_instance.id)

        # Order: provision first, then terminate
        expect(::System::ProvisioningService).to have_received(:provision_instance).ordered
        expect(::System::ProvisioningService).to have_received(:terminate_instance).ordered
      end

      # IMP-666a6e904650 — the envelope used to lift only the inner
      # executor's outputs and failures, never its planned_actions, so the
      # run could not be graded against the approval card it was consented
      # on. The envelope now carries the inner steps in execution order,
      # followed by the provision_target_stack rollup for the leg.
      it "records the inner executor's own steps in the envelope, in run order" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [ source_instance.id ])

        expect(r[:success]).to be true
        steps = r[:data][:planned_actions]
        expect(steps.map { |a| a[:step] }).to eq(%w[
          relocate_workload
          create_node provision_instance
          provision_target_stack
          terminate_source
        ])

        # The concatenated steps are the inner envelope itself, not a
        # re-synthesized card: they carry the ids the run produced.
        expect(steps.find { |a| a[:step] == "provision_instance" }[:instance_id])
          .to eq(new_instance_stub.id)
        expect(steps.find { |a| a[:step] == "create_node" }[:node_id]).to be_present
      end
    end

    # IMP-df4e3a7d71e5 — the relocated fleet has to stay the MISSION's fleet.
    # The full argument (why BOTH ownership markers travel, and what the
    # containment rail does with each) lives at the seam it constrains:
    # RelocateWorkloadExecutor#provision_target!. These examples pin its
    # observable half — what a later scale-in can actually find and vouch for.
    context "mission provenance on the relocated fleet" do
      let(:mission) do
        create(:ai_mission, account: account, mission_type: "infrastructure",
                            configuration: { "name_prefix" => "reloc-prov" })
      end

      before do
        # Real Node + NodeInstance rows: the contract under test is a database
        # predicate (`config @> {mission_id}`), so a doubled instance would
        # prove nothing about what a scale-in can find.
        allow(::System::ProvisioningService).to receive(:provision_instance) do |node:, **_rest|
          ::System::Runtime::Result.ok(
            data: { instance: create(:system_node_instance, :running, node: node,
                                     name: "#{node.name}-instance"),
                    cloud_instance_id: "ci-#{node.name}" }
          )
        end
        allow(::System::ProvisioningService).to receive(:terminate_instance)
          .and_return(::System::Runtime::Result.ok)
      end

      def relocate!(count: 2)
        exec.execute(project_id: mission.id, from_region_id: from_region.id,
                     to_region_id: to_region.id, cutover_strategy: "blue_green",
                     template_id: template.id,
                     provider_instance_type_id: instance_type.id, count: count,
                     source_instance_ids: [ source_instance.id ])
      end

      it "stamps mission_id so the mission's own provenance query returns exactly the new fleet" do
        r = relocate!
        expect(r[:success]).to be true
        new_ids = r[:data][:outputs][:node_instance_ids]
        expect(new_ids.size).to eq(2)

        # ScaleProjectExecutor#mission_replicas, verbatim.
        found = ::System::NodeInstance
                  .joins(:node)
                  .where(system_nodes: { account_id: account.id })
                  .where("system_nodes.config @> ?", { mission_id: mission.id }.to_json)
                  .active
        expect(found.pluck(:id)).to match_array(new_ids)
        # Negative control: the un-stamped source instance is not swept in.
        expect(found.pluck(:id)).not_to include(source_instance.id)
      end

      it "carries the mission's blast-radius prefix onto the node names the rail reads" do
        r = relocate!(count: 1)
        expect(r[:success]).to be true

        node = ::System::Node.find(r[:data][:outputs][:node_ids].first)
        expect(node.name).to start_with("reloc-prov-")
        expect(node.config["mission_id"]).to eq(mission.id)
      end

      it "leaves the relocated capacity resolvable as scale-in victims" do
        expect(relocate!(count: 2)[:success]).to be true

        scale = ::System::Ai::Skills::ScaleProjectExecutor.new(account: account)
        r = scale.execute(project_id: mission.id, scaling_strategy: "remove_replicas",
                          target_count: 1, dry_run: true)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:count]).to eq(1)
        expect(d[:planned_actions].map { |a| a[:step] }).to include("remove_replica")
        expect(d[:planned_actions].map { |a| a[:step] }).not_to include("remove_replicas_floor")
        # The rail measured the removal rather than skipping it.
        expect(d[:outputs][:prefix_enforced]).to eq("reloc-prov")
      end
    end

    context "drain execute" do
      let(:ok_prov) do
        ::System::Runtime::Result.ok(data: { instance: new_instance_stub, cloud_instance_id: "ci-dr" })
      end
      let(:ok_terminate) { ::System::Runtime::Result.ok }

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(ok_prov)
        allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(ok_terminate)
      end

      it "terminates the source first, then provisions the target" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "drain",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [ source_instance.id ])

        expect(r[:success]).to be true
        expect(r[:data][:cutover_strategy]).to eq("drain")
        expect(::System::ProvisioningService).to have_received(:terminate_instance).ordered
        expect(::System::ProvisioningService).to have_received(:provision_instance).ordered
      end

      # IMP-666a6e904650 — exact-sequence twin of the blue_green envelope
      # example: under drain the terminate is recorded BEFORE the inner
      # provisioning steps, exactly as the run performed them.
      it "records terminate before the inner provisioning steps, in run order" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "drain",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [ source_instance.id ])

        expect(r[:success]).to be true
        expect(r[:data][:planned_actions].map { |a| a[:step] }).to eq(%w[
          relocate_workload
          terminate_source
          create_node provision_instance
          provision_target_stack
        ])
      end

      # IMP-4e5b78f0b737 — every exact-sequence example above runs count: 1
      # with all legs succeeding, and on that shape a LIFTED inner envelope and
      # a re-SYNTHESIZED card are indistinguishable (one create_node, one
      # provision_instance, either way). The partial run is what tells them
      # apart: the failed leg contributes its create_node and NOT its
      # provision_instance, in the position the run actually performed it —
      # the record an operator grades a half-finished relocate from.
      #
      # Drain rather than blue_green for a failing PROVISIONING leg: that is
      # exactly what blue_green's guard refuses (undersized ⇒ failure
      # envelope, no planned_actions at all — see "blue_green refusal when the
      # target stack comes up undersized"), so this shape cannot be observed
      # there.
      #
      # That guard USED to read instance count and fabric enrollment only
      # (#run_execute), so it was not the case that blue_green refused every
      # partial run: a blue_green run whose STORAGE leg failed left
      # undersized=false and off_fabric=false, passed the guard, terminated
      # the sources, and returned a partial envelope of this same shape
      # (verified by execution, IMP-4e5b78f0b737). That was left deliberately
      # unpinned here pending a decision on whether it was correct. It was
      # not: IMP-e1903a42c1ab added the storage arm, and the decision is
      # specced in "blue_green refusal when the target stack's storage leg
      # failed" below. Drain remains the strategy this partial-run shape is
      # observable on — under blue_green all three legs now gate the teardown,
      # and drain has no guard at all because it terminates first by design.
      context "when one of several provisioning legs fails" do
        let(:surviving_instance) { instance_double("System::NodeInstance", id: SecureRandom.uuid) }

        before do
          # First leg fails, second succeeds — so the missing provision_instance
          # sits in the MIDDLE of the sequence. A tail-truncated or
          # append-at-end recording of the same run would not look like this.
          results = [
            ::System::Runtime::Result.err(error: "region quota exhausted"),
            ::System::Runtime::Result.ok(data: { instance: surviving_instance, cloud_instance_id: "ci-dr-2" })
          ]
          allow(::System::ProvisioningService).to receive(:provision_instance) { results.shift }
        end

        it "records the failed leg's create_node with no provision_instance, in run order" do
          r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                           to_region_id: to_region.id, cutover_strategy: "drain",
                           template_id: template.id,
                           provider_instance_type_id: instance_type.id, count: 2,
                           source_instance_ids: [ source_instance.id ])

          expect(r[:success]).to be true
          steps = r[:data][:planned_actions]
          expect(steps.map { |a| a[:step] }).to eq(%w[
            relocate_workload
            terminate_source
            create_node create_node provision_instance
            provision_target_stack
          ])

          # The surviving leg's steps pair up by node: the one provision belongs
          # to the SECOND node created, and the failed leg's node has none.
          created_node_ids = steps.select { |a| a[:step] == "create_node" }.map { |a| a[:node_id] }
          provisioned      = steps.select { |a| a[:step] == "provision_instance" }
          expect(created_node_ids.uniq.size).to eq(2)
          expect(provisioned.map { |a| a[:node_id] }).to eq([ created_node_ids.last ])
          expect(provisioned.map { |a| a[:instance_id] }).to eq([ surviving_instance.id ])

          # The rollup counts what CAME UP, not what was asked for, and the
          # failed leg surfaces on the envelope rather than only in the steps.
          expect(steps.last).to include(step: "provision_target_stack", instance_count: 1)
          expect(r[:data][:partial]).to be true
          expect(r[:data][:failures]).to include(
            hash_including(step: "provision_instance", node_id: created_node_ids.first,
                           error: "region quota exhausted")
          )
        end
      end
    end

    # IMP-6b497651d670 — every blue_green refusal arm returns the SAME
    # failure discriminator (one guard, one envelope shape). The empty arm
    # has nothing to reclaim, so the strict no-terminate oracle holds
    # unqualified here.
    context "blue_green refusal when target stack fails" do
      let(:bad_prov) { ::System::Runtime::Result.err(error: "region quota exhausted") }

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(bad_prov)
      end

      it "refuses with a failure envelope and does not terminate source instances when no target instance came up" do
        expect(::System::ProvisioningService).not_to receive(:terminate_instance)

        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 1,
                         source_instance_ids: [ source_instance.id ])

        expect(r[:success]).to be false
        expect(r[:error]).to match(/target stack is empty/)
        # The inner executor's provision failure — the reason the stack is
        # empty — must still surface; it rides the error string now.
        expect(r[:error]).to include("region quota exhausted")

        # The refusal event fires on this arm too (one guard, one shape) and
        # records the Node shell left for inspection even though there was
        # nothing to reclaim.
        ev = ::Ai::ExecutionEvent.where(account_id: account.id,
                                        event_type: "relocate_cutover_refusal")
                                 .order(:created_at).last
        expect(ev).to be_present
        expect(ev.metadata["refusal_reasons"]).to include("target stack is empty")
        expect(ev.metadata["reclaimed"].values.flatten).to be_empty
        expect(ev.metadata["node_ids_left_for_inspection"].size).to eq(1)
      end
    end

    # IMP-bb73f7154f27 (pre-existing :233 undercount hole, closed alongside
    # IMP-6b497651d670): the guard used to check only empty/off-fabric, so a
    # 1-of-2 capacity shortfall passed and terminated EVERY source against
    # half the requested capacity. Undersized now refuses like the other
    # arms: failure envelope, provisioned targets reclaimed, sources alive.
    context "blue_green refusal when the target stack comes up undersized" do
      let(:target_a) do
        create(:system_node_instance, :running,
               node: create(:system_node, account: account, node_template: template))
      end
      let(:terminated_ids) { [] }

      before do
        results = [
          ::System::Runtime::Result.ok(data: { instance: target_a, cloud_instance_id: "ci-1" }),
          ::System::Runtime::Result.err(error: "region quota exhausted")
        ]
        allow(::System::ProvisioningService).to receive(:provision_instance) { results.shift }
        allow(::System::ProvisioningService).to receive(:terminate_instance) do |**kwargs|
          terminated_ids << kwargs[:instance].id
          ::System::Runtime::Result.ok
        end
      end

      it "refuses the cutover, reclaims the one provisioned target, and leaves every source alive" do
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: "blue_green",
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 2,
                         source_instance_ids: [ source_instance.id ])

        expect(r[:success]).to be false
        expect(r[:error]).to match(%r{undersized \(1/2})
        expect(terminated_ids).to eq([ target_a.id ])
        expect(terminated_ids).not_to include(source_instance.id)
        expect(::System::NodeInstance.where(id: source_instance.id)).to exist
      end
    end

    # IMP-94f778f92dba — the instance-count check has NEVER covered the
    # network leg. Before the enrollment change, compile_for_network enrolled
    # nothing and so could not fail, and every blue/green relocate with a
    # network_id terminated the source with its targets off-fabric, reporting
    # success. The enrollment change does not create that hole; it produces
    # the attach_sdwan_peer failure data that finally lets the guard see it.
    #
    # IMP-6b497651d670 — the refusal itself must be a FAILURE that reclaims
    # the refused target stack in-branch. success(partial: true) abandoned
    # the whole stack: SkillCompositionRunner reaches rollback_step! only
    # from handle_failure, so a completed-partial step never dispatches the
    # rollback holding these ids. And a bare failure(...) reclaims nothing
    # either — the runner's rollback kwargs come from metadata["last_outputs"],
    # written only by mark_completed, so a first-run failure rolls back {}
    # and stamps rolled_back over live resources.
    context "blue_green refusal when the target never joined the requested network" do
      let(:network) { ::Sdwan::Network.create!(account_id: account.id, name: "reloc-net-#{SecureRandom.hex(3)}") }

      # Real rows, because the reclaim resolves ids back to records — an
      # instance_double id makes the rollback loops skip via find_by(nil)
      # and every reclaim assertion would pass vacuously.
      let(:target_a) { sdwan_test_node_instance(node: sdwan_test_node(account: account)) }
      let(:target_b) { sdwan_test_node_instance(node: sdwan_test_node(account: account)) }
      let(:volume_a) do
        create(:system_provider_volume, :attached, account: account,
               provider_region: to_region, node_instance: target_a)
      end
      let(:volume_b) do
        create(:system_provider_volume, :attached, account: account,
               provider_region: to_region, node_instance: target_b)
      end

      let(:terminated_ids)    { [] }
      let(:enrolled_peer_ids) { [] }

      before do
        targets = [ target_a, target_b ]
        allow(::System::ProvisioningService).to receive(:provision_instance) do
          ::System::Runtime::Result.ok(data: { instance: targets.shift, cloud_instance_id: "ci-bg" })
        end

        # The first target enrolls for real; the second fails — 1/2 on fabric.
        allow(::Sdwan::PeerEnroller).to receive(:call).and_wrap_original do |orig, **kwargs|
          raise StandardError, "vrf table exhausted" if enrolled_peer_ids.any?

          orig.call(**kwargs).tap { |peer| enrolled_peer_ids << peer.id }
        end

        volumes = [ volume_a, volume_b ]
        allow(::System::VolumeManagementService).to receive(:provision) do
          ::System::Runtime::Result.ok(data: { volume: volumes.shift })
        end
        allow(::System::VolumeManagementService).to receive(:attach)
          .and_return(::System::Runtime::Result.ok(data: { device: "/dev/vdb" }))
        allow(::System::VolumeManagementService).to receive(:detach)
          .and_return(::System::Runtime::Result.ok)
        allow(::System::VolumeManagementService).to receive(:delete)
          .and_return(::System::Runtime::Result.ok)

        allow(::System::ProvisioningService).to receive(:terminate_instance) do |**kwargs|
          terminated_ids << kwargs[:instance].id
          ::System::Runtime::Result.ok
        end
      end

      def run_blue_green_relocate
        exec.execute(project_id: mission.id, from_region_id: from_region.id,
                     to_region_id: to_region.id, cutover_strategy: "blue_green",
                     template_id: template.id,
                     provider_instance_type_id: instance_type.id, count: 2,
                     network_id: network.id, with_storage_gb: 25,
                     source_instance_ids: [ source_instance.id ])
      end

      it "reports the refusal as a failure, naming the fabric shortfall and the enrollment error" do
        r = run_blue_green_relocate

        expect(r[:success]).to be false
        expect(r[:error]).to match(/off-fabric/)
        expect(r[:error]).to include("1/2").and include(network.id)
        # The inner executor's own leg failure must still reach the recorded
        # envelope — the runner records only what this executor returns, and
        # a failure envelope carries no failures array, so it rides the error.
        expect(r[:error]).to include("vrf table exhausted")
      end

      it "reclaims the refused target stack — instances, volumes, enrolled peer — and never touches the source" do
        # Strict oracle restored (was the not_to receive(:terminate_instance)
        # of the pre-reclaim contract): the reclaim DOES terminate targets,
        # so the never-condition is now scoped to the source's own args and
        # backstopped by the terminated_ids capture below.
        expect(::System::ProvisioningService).not_to receive(:terminate_instance)
          .with(instance: source_instance)

        r = run_blue_green_relocate
        expect(r[:success]).to be false

        # Target instances terminated; the source is NOT in the terminate set.
        expect(terminated_ids).to match_array([ target_a.id, target_b.id ])
        expect(terminated_ids).not_to include(source_instance.id)
        expect(::System::NodeInstance.where(id: source_instance.id)).to exist

        # Volumes detached then deleted (they arrive attached — IMP-093378034fb4).
        expect(::System::VolumeManagementService).to have_received(:detach).with(volume: volume_a)
        expect(::System::VolumeManagementService).to have_received(:detach).with(volume: volume_b)
        expect(::System::VolumeManagementService).to have_received(:delete).with(volume: volume_a)
        expect(::System::VolumeManagementService).to have_received(:delete).with(volume: volume_b)

        # The one peer that DID enroll is detached again.
        expect(enrolled_peer_ids.size).to eq(1)
        expect(::Sdwan::Peer.where(id: enrolled_peer_ids.first)).to be_empty
      end

      it "surfaces an incomplete reclaim instead of claiming a clean unwind" do
        allow(::System::VolumeManagementService).to receive(:delete)
          .and_return(::System::Runtime::Result.err(error: "volume delete refused"))

        r = run_blue_green_relocate

        expect(r[:success]).to be false
        expect(r[:error]).to match(/reclaim/i)
        expect(r[:error]).to include("volume delete refused")
      end

      # IMP-6b497651d670 hardening — the message is human-oriented and
      # bounded; the MACHINE-READABLE diagnosis lives in an
      # Ai::ExecutionEvent, because the runner's mark_rolled_back (composers
      # stamp on_failure: "rollback" by default) overwrites result_summary
      # after our failure return — without the event, an incomplete reclaim's
      # survivors would be recorded nowhere durable.
      it "records a machine-readable execution event with reclaimed ids per class and the inspection nodes" do
        expect { run_blue_green_relocate }
          .to change { ::Ai::ExecutionEvent.where(account_id: account.id).count }.by(1)

        ev = ::Ai::ExecutionEvent.where(account_id: account.id,
                                        event_type: "relocate_cutover_refusal")
                                 .order(:created_at).last
        expect(ev).to be_present
        expect(ev.source_type).to eq("Ai::Mission")
        expect(ev.source_id).to eq(mission.id)
        expect(ev.status).to eq("target_stack_reclaimed")

        md = ev.metadata
        expect(md["refusal_reasons"].join).to match(/off-fabric/)
        expect(md["reclaimed"]["node_instance"]).to match_array([ target_a.id, target_b.id ])
        expect(md["reclaimed"]["provider_volume"]).to match_array([ volume_a.id, volume_b.id ])
        expect(md["reclaimed"]["sdwan_peer"]).to eq(enrolled_peer_ids)
        expect(md["survivors"].values.flatten).to be_empty
        # F8 — the Node shells stay for inspection, but their ids are
        # RECORDED, so "left for inspection" is findable rather than orphaned.
        expect(md["node_ids_left_for_inspection"].size).to eq(2)
        expect(::System::Node.where(id: md["node_ids_left_for_inspection"]).count).to eq(2)
        expect(md["provisioning_leg_failures"].map { |f| f["step"] }).to include("attach_sdwan_peer")
      end

      # IMP-2182fd8fcdee — the durable EVENT above records survivors, but the
      # runner cannot act on an event. Composers stamp on_failure: "rollback"
      # by default, so after this failure returns the runner calls
      # rollback_step! — which reads its kwargs from the failure envelope (or
      # from last_outputs, empty on a first-run failure). A bare
      # failure(message) therefore rolls back NOTHING and then stamps
      # rolled_back over resources that are still live and billing.
      it "hands surviving resources to the runner's failure-time rollback seam" do
        allow(::System::VolumeManagementService).to receive(:delete)
          .and_return(::System::Runtime::Result.err(error: "volume delete refused"))

        r = run_blue_green_relocate

        expect(r[:success]).to be false
        # Keyed by rollback_relocate_workload's OWN kwarg names, because that
        # is the hook the runner will invoke with them.
        expect(r[:storage_volume_ids]).to match_array([ volume_a.id, volume_b.id ])
      end

      it "omits classes that reclaimed cleanly rather than sending empty arrays" do
        allow(::System::VolumeManagementService).to receive(:delete)
          .and_return(::System::Runtime::Result.err(error: "volume delete refused"))

        r = run_blue_green_relocate

        # An outputs hash that is "present" while holding no ids displaces a
        # retried step's genuine last_outputs and fakes compensation in one
        # move — the runner's own failure_outputs_from warns about exactly
        # this shape. Only classes with survivors may appear.
        expect(r).not_to have_key(:node_instance_ids)
        expect(r).not_to have_key(:sdwan_peer_ids)
      end

      it "stays a bare failure when the reclaim was clean, so nothing is faked" do
        r = run_blue_green_relocate

        expect(r[:success]).to be false
        expect(r[:storage_volume_ids]).to be_nil
        expect(r[:node_instance_ids]).to be_nil
        expect(r[:sdwan_peer_ids]).to be_nil
      end

      it "records survivors per class when the reclaim is incomplete" do
        allow(::System::VolumeManagementService).to receive(:delete)
          .and_return(::System::Runtime::Result.err(error: "volume delete refused"))

        run_blue_green_relocate

        ev = ::Ai::ExecutionEvent.where(account_id: account.id,
                                        event_type: "relocate_cutover_refusal")
                                 .order(:created_at).last
        expect(ev.status).to eq("reclaim_incomplete")

        md = ev.metadata
        expect(md["survivors"]["provider_volume"]).to match_array([ volume_a.id, volume_b.id ])
        expect(md["reclaimed"]["provider_volume"]).to be_empty
        # The other classes reclaimed cleanly and must not be smeared into
        # the survivor set (per-class truth, not one aggregate flag).
        expect(md["reclaimed"]["node_instance"]).to match_array([ target_a.id, target_b.id ])
        expect(md["survivors"]["node_instance"]).to be_empty
        expect(md["reclaim_errors"].map { |e| e["error"] }).to all(include("volume delete refused"))
      end

      # Positive control (F10): the identical composition with a healthy
      # fabric — every target enrolls — must still cut over, or the refusal
      # examples above could pass off an unconditional failure as the guard
      # working. Terminate reaches ONLY the source; nothing is reclaimed.
      context "when every target enrolls (positive control)" do
        before do
          allow(::Sdwan::PeerEnroller).to receive(:call).and_call_original
        end

        it "proceeds with the cutover: source terminated, targets kept, success envelope" do
          r = run_blue_green_relocate

          expect(r[:success]).to be true
          expect(r[:data][:outputs][:terminated_instance_ids]).to eq([ source_instance.id ])
          expect(terminated_ids).to eq([ source_instance.id ])
          expect(::System::VolumeManagementService).not_to have_received(:detach)
          expect(::System::VolumeManagementService).not_to have_received(:delete)
        end
      end
    end

    # IMP-e1903a42c1ab — the readiness guard covered the instance and fabric
    # legs; the executor composes THREE. This is the arm iteration 274 left
    # deliberately unpinned pending a decision on whether tearing a source
    # down against a diskless target is correct — it is not, and the guard now
    # says so.
    #
    # Why this is the same class as undersized/off-fabric rather than untidy:
    # blue_green exists to move a workload, and until the target is serving,
    # the SOURCES hold the only copy of the data. A data volume that never
    # attached means "the target is not ready" exactly as the other two arms
    # do, and worse for a data-bearing workload.
    #
    # Verified by execution BEFORE the fix (this context, red): a failing
    # attach left undersized=false and off_fabric=false, the guard passed,
    # terminate_instance ran on the SOURCE, and the envelope returned
    # success(partial: true) — and because a partial success never reaches
    # SkillCompositionRunner#rollback_step!, the volume with the nil instance
    # FK in storage_volume_ids was a permanent orphan.
    #
    # Counting `storage_volume_ids` alone would NOT have closed this: the
    # inner executor records the volume id before attempting the attach, so
    # the attach-failure shape has full count parity and a nil FK. The oracle
    # has to be the attachment itself.
    context "blue_green refusal when the target stack's storage leg failed" do
      # Real rows throughout: the guard's question is about a persisted
      # volume's FK and the reclaim resolves ids back to records, so a double
      # would make both vacuous.
      let(:target_a) do
        create(:system_node_instance, :running,
               node: create(:system_node, account: account, node_template: template))
      end
      let(:target_b) do
        create(:system_node_instance, :running,
               node: create(:system_node, account: account, node_template: template))
      end
      let(:volume_a) { create(:system_provider_volume, account: account, provider_region: to_region) }
      let(:volume_b) { create(:system_provider_volume, account: account, provider_region: to_region) }

      let(:terminated_ids)  { [] }
      let(:pending_targets) { [ target_a, target_b ] }
      let(:pending_volumes) { [ volume_a, volume_b ] }

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance) do
          ::System::Runtime::Result.ok(data: { instance: pending_targets.shift, cloud_instance_id: "ci-st" })
        end
        allow(::System::ProvisioningService).to receive(:terminate_instance) do |**kwargs|
          terminated_ids << kwargs[:instance].id
          ::System::Runtime::Result.ok
        end
        allow(::System::VolumeManagementService).to receive(:provision) do
          ::System::Runtime::Result.ok(data: { volume: pending_volumes.shift })
        end
        # A FAITHFUL attach: an ok-returning stub that never writes the FK
        # would make every target look diskless and the positive control below
        # could not pass, which is the point — attachment is the oracle.
        allow(::System::VolumeManagementService).to receive(:attach) do |**kwargs|
          kwargs[:volume].attach_to!(kwargs[:instance], "/dev/vdb")
          ::System::Runtime::Result.ok(data: { device: "/dev/vdb" })
        end
        allow(::System::VolumeManagementService).to receive(:detach).and_return(::System::Runtime::Result.ok)
        allow(::System::VolumeManagementService).to receive(:delete).and_return(::System::Runtime::Result.ok)
      end

      def run_relocate(count: 1, with_storage_gb: 25)
        exec.execute(project_id: mission.id, from_region_id: from_region.id,
                     to_region_id: to_region.id, cutover_strategy: "blue_green",
                     template_id: template.id,
                     provider_instance_type_id: instance_type.id, count: count,
                     with_storage_gb: with_storage_gb,
                     source_instance_ids: [ source_instance.id ])
      end

      it "refuses when the volume was provisioned but never attached, and leaves the source alive" do
        allow(::System::VolumeManagementService).to receive(:attach)
          .and_return(::System::Runtime::Result.err(error: "no free device paths"))

        r = run_relocate

        expect(r[:success]).to be false
        expect(r[:error]).to match(%r{storage-unready \(0/1})
        expect(r[:error]).to include("source instances not terminated")
        # The inner leg failure — the REASON the stack is refused — rides the
        # error string, as it does on the other two arms.
        expect(r[:error]).to include("no free device paths")

        expect(terminated_ids).to eq([ target_a.id ])
        expect(terminated_ids).not_to include(source_instance.id)
        expect(::System::NodeInstance.where(id: source_instance.id)).to exist
      end

      # The orphan the pre-fix path left behind: the refusal's reclaim adopts
      # it, because the inner envelope lists the volume id even though the
      # attach failed. Detach is correctly SKIPPED — its FK is nil.
      it "reclaims the never-attached volume that the pre-fix partial success orphaned" do
        allow(::System::VolumeManagementService).to receive(:attach)
          .and_return(::System::Runtime::Result.err(error: "no free device paths"))

        run_relocate

        expect(volume_a.reload.node_instance_id).to be_nil
        expect(::System::VolumeManagementService).to have_received(:delete).with(volume: volume_a)
        expect(::System::VolumeManagementService).not_to have_received(:detach)
      end

      it "refuses when the data volume was never provisioned at all" do
        allow(::System::VolumeManagementService).to receive(:provision)
          .and_return(::System::Runtime::Result.err(error: "storage pool exhausted"))

        r = run_relocate

        expect(r[:success]).to be false
        expect(r[:error]).to match(%r{storage-unready \(0/1})
        expect(r[:error]).to include("storage pool exhausted")
        expect(terminated_ids).to eq([ target_a.id ])
        expect(terminated_ids).not_to include(source_instance.id)
        expect(::System::NodeInstance.where(id: source_instance.id)).to exist
      end

      # IMP-e1903a42c1ab review F1 — the gate question is "was storage
      # DECLARED?", not "was a positive size REQUESTED?". A declared-but-
      # unreadable value takes ProvisionFullStackExecutor's LOUD lane
      # (#storage_unreadable?): it records a provision_storage failure per
      # node and skips the volume entirely, so the inner envelope comes back
      # with the instances up and storage_volume_ids EMPTY. Gated on
      # storage_requested? alone, that shape reproduced this task's exact
      # failure — guard passes, sources torn down against a diskless target —
      # through a different input. relocate forwards the raw value with no
      # validation of its own (the descriptor says integer; nothing enforces
      # it), and IMP-f85254148755 already judged the shape reachable from
      # hand-authored plan_data, MissionComposer output and operator input.
      #
      # BOTH sub-branches of #storage_unreadable? in one sweep: a String that
      # responds to to_i but reads 0 ("plenty"), and a shape that does not
      # respond to to_i at all — those reach the lane by different routes.
      # IMP-f5532c5c5bd6 — SAME VERDICT, REACHED EARLIER. This asserted the
      # refusal after a full provision-and-reclaim cycle: targets came up
      # diskless, storage_unready? refused the cutover, and the targets were
      # torn down again. The value is now refused at the door, so the cycle
      # never runs — which is why the "terminated every target" assertion is
      # gone rather than loosened: there are no targets to terminate.
      #
      # Everything the example existed to protect still holds, and now holds
      # without provisioning anything: both unreadable shapes refuse, no volume
      # is created, the source survives, and the message never quotes an
      # authoritative "0 GB" for a size nothing read.
      it "refuses every declared-but-unreadable storage shape, on which no volume is ever created" do
        [ "plenty", { "gb" => 50 } ].each do |declared|
          r = run_relocate(with_storage_gb: declared)

          expect(r[:success]).to be(false), "expected #{declared.inspect} to refuse the cutover"
          expect(r[:error]).to include("storage declared but unreadable")
          expect(r[:error]).not_to include("0 GB")
        end

        expect(::System::VolumeManagementService).not_to have_received(:provision)
        expect(terminated_ids).to be_empty,
                                 "the door refusal must not provision anything to reclaim"
        expect(::System::NodeInstance.where(id: source_instance.id)).to exist
      end

      # Open question answered in place: a PARTIALLY attached stack refuses
      # too, on the same reasoning off-fabric refuses a partially-enrolled one
      # — the card promises one volume per target, and a target without its
      # disk cannot serve the workload the sources still hold.
      #
      # ONE source against TWO targets, deliberately: with two of each,
      # "terminated every target" and "terminated every source" are
      # indistinguishable.
      it "refuses a partially attached stack — one target with a disk is not a ready stack" do
        attach_calls = 0
        allow(::System::VolumeManagementService).to receive(:attach) do |**kwargs|
          attach_calls += 1
          if attach_calls == 1
            kwargs[:volume].attach_to!(kwargs[:instance], "/dev/vdb")
            ::System::Runtime::Result.ok(data: { device: "/dev/vdb" })
          else
            ::System::Runtime::Result.err(error: "no free device paths")
          end
        end

        r = run_relocate(count: 2)

        expect(r[:success]).to be false
        expect(r[:error]).to match(%r{storage-unready \(1/2})
        expect(terminated_ids).to match_array([ target_a.id, target_b.id ])
        expect(terminated_ids).not_to include(source_instance.id)
        expect(::System::NodeInstance.where(id: source_instance.id)).to exist
      end

      # One guard, one envelope shape: a consumer must not be able to tell the
      # storage arm from the other two.
      it "reports the storage refusal through the same failure envelope and event as the other arms" do
        allow(::System::VolumeManagementService).to receive(:attach)
          .and_return(::System::Runtime::Result.err(error: "no free device paths"))

        expect { run_relocate }
          .to change { ::Ai::ExecutionEvent.where(account_id: account.id).count }.by(1)

        ev = ::Ai::ExecutionEvent.where(account_id: account.id,
                                        event_type: "relocate_cutover_refusal")
                                 .order(:created_at).last
        expect(ev.source_type).to eq("Ai::Mission")
        expect(ev.source_id).to eq(mission.id)
        expect(ev.status).to eq("target_stack_reclaimed")

        md = ev.metadata
        expect(md["refusal_reasons"].join).to match(/storage-unready/)
        expect(md["reclaimed"]["node_instance"]).to eq([ target_a.id ])
        # IMP-0d9e7ca7b166 — this used to expect [volume_a.id] here. The
        # provisioning leg now reclaims a volume it could not attach IN-BRANCH,
        # because for every OTHER caller of ProvisionFullStackExecutor nothing
        # downstream can reach a nil-FK volume. So by the time this refusal
        # runs its own reclaim, the volume is already gone and there is
        # correctly nothing left for it to reclaim.
        #
        # The guarantee this example exists to protect is unchanged and is
        # asserted directly below: no volume survives the refusal. Which LAYER
        # deleted it is an implementation detail; that it is gone is not.
        expect(md["reclaimed"]["provider_volume"]).to be_empty
        # The reclaim still HAPPENED — just one layer down. This context stubs
        # VolumeManagementService.delete to return ok WITHOUT destroying the
        # row, so "the row is gone" is unobservable here and the call is the
        # only available evidence. (The row actually disappearing is asserted
        # in provision_full_stack_executor_spec, where delete runs for real
        # against a stubbed provider adapter.)
        expect(::System::VolumeManagementService).to have_received(:delete).with(volume: volume_a)
        expect(md["survivors"].values.flatten).to be_empty
        expect(md["provisioning_leg_failures"].map { |f| f["step"] }).to include("attach_volume")
      end

      # Positive control: the identical composition with a healthy storage leg
      # must still cut over, or the refusals above could be an unconditional
      # failure passing itself off as the guard working.
      #
      # It rests on one unstated coupling worth naming: the volume factory's
      # default status is "available" (spec/factories/system_factories.rb), so
      # the faithful attach stub's `attach_to!` actually writes the FK. Were
      # that default to become "creating", `can_attach?` would be false,
      # `attach_to!` would silently return false, and this control would fail
      # as storage-unready 0/2 — a factory change masquerading as a guard bug.
      it "proceeds with the cutover when every target's volume is attached (positive control)" do
        r = run_relocate(count: 2)

        expect(r[:success]).to be true
        expect(r[:data][:outputs][:terminated_instance_ids]).to eq([ source_instance.id ])
        expect(terminated_ids).to eq([ source_instance.id ])
        expect(::System::VolumeManagementService).not_to have_received(:delete)
        expect([ volume_a.reload.node_instance_id, volume_b.reload.node_instance_id ])
          .to match_array([ target_a.id, target_b.id ])
      end

      # Negative control on the PREDICATE, not the guard: an explicit 0 is a
      # legitimate "no storage" answer (ProvisionFullStackExecutor
      # #storage_requested?, IMP-33fa6c51f05d), so the absence of a volume is
      # not a shortfall. A `present?`-shaped re-derivation would refuse here
      # and strand every zero-storage blue_green relocate.
      it "invents no storage refusal when no storage was requested" do
        r = run_relocate(with_storage_gb: 0)

        expect(r[:success]).to be true
        expect(::System::VolumeManagementService).not_to have_received(:provision)
        expect(terminated_ids).to eq([ source_instance.id ])
      end
    end

    # IMP-01a774a80f7a — the storage declaration reaches this executor under
    # TWO key names, and only one of them used to survive the door.
    # `storage_gb` is the tolerated alias ProvisionFullStackExecutor resolves
    # ([with_storage_gb, storage_gb], first PRESENT wins) and the one
    # CostEstimatorService#declared_gb prices. relocate's #perform declared no
    # such keyword, so the alias landed in `**_extras` and was discarded, and
    # #provision_target! forwarded only `with_storage_gb:` — nil.
    #
    # Verified by execution BEFORE the fix (this context, red): a blue_green
    # relocate declaring `storage_gb: 25` alone provisioned no volume, planned
    # no storage steps, recorded NO failure entry, disclosed no refusal clause,
    # and — storage_declared?(nil) being false — passed the cutover guard and
    # TERMINATED the sources against a target with no disk, reporting success.
    # That is the IMP-e1903a42c1ab data loss reached through a third input
    # shape, and strictly worse diagnostically than the unreadable one, which
    # at least leaves one provision_storage failure per node to read.
    context "storage declared through the `storage_gb` alias" do
      let(:target_a) do
        create(:system_node_instance, :running,
               node: create(:system_node, account: account, node_template: template))
      end
      let(:target_b) do
        create(:system_node_instance, :running,
               node: create(:system_node, account: account, node_template: template))
      end
      let(:volume_a) { create(:system_provider_volume, account: account, provider_region: to_region) }
      let(:volume_b) { create(:system_provider_volume, account: account, provider_region: to_region) }

      let(:terminated_ids)  { [] }
      let(:pending_targets) { [ target_a, target_b ] }
      let(:pending_volumes) { [ volume_a, volume_b ] }

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance) do
          ::System::Runtime::Result.ok(data: { instance: pending_targets.shift, cloud_instance_id: "ci-alias" })
        end
        allow(::System::ProvisioningService).to receive(:terminate_instance) do |**kwargs|
          terminated_ids << kwargs[:instance].id
          ::System::Runtime::Result.ok
        end
        allow(::System::VolumeManagementService).to receive(:provision) do
          ::System::Runtime::Result.ok(data: { volume: pending_volumes.shift })
        end
        # Faithful attach — it writes the FK the guard actually reads. Rests on
        # the volume factory defaulting to status "available" (so `can_attach?`
        # holds); a factory change there would surface here as a guard bug.
        allow(::System::VolumeManagementService).to receive(:attach) do |**kwargs|
          kwargs[:volume].attach_to!(kwargs[:instance], "/dev/vdb")
          ::System::Runtime::Result.ok(data: { device: "/dev/vdb" })
        end
        allow(::System::VolumeManagementService).to receive(:detach).and_return(::System::Runtime::Result.ok)
        allow(::System::VolumeManagementService).to receive(:delete).and_return(::System::Runtime::Result.ok)
      end

      def relocate_via_alias(count: 1, dry_run: false, **storage_keys)
        exec.execute(project_id: mission.id, from_region_id: from_region.id,
                     to_region_id: to_region.id, cutover_strategy: "blue_green",
                     template_id: template.id,
                     provider_instance_type_id: instance_type.id, count: count,
                     source_instance_ids: [ source_instance.id ],
                     dry_run: dry_run, **storage_keys)
      end

      # The destructive shape, and the whole finding: pre-fix this returned
      # success with the source gone and nothing anywhere recording why.
      it "refuses the cutover and leaves the sources alive when the aliased storage leg fails" do
        allow(::System::VolumeManagementService).to receive(:attach)
          .and_return(::System::Runtime::Result.err(error: "no free device paths"))

        r = relocate_via_alias(storage_gb: 25)

        expect(r[:success]).to be false
        expect(r[:error]).to match(%r{storage-unready \(0/1})
        expect(r[:error]).to include("25 GB")
        expect(r[:error]).to include("source instances not terminated")
        # The leg failure the pre-fix path never even attempted, so had nothing
        # to report: no volume was requested, so none could fail.
        expect(r[:error]).to include("no free device paths")

        expect(terminated_ids).to eq([ target_a.id ])
        expect(terminated_ids).not_to include(source_instance.id)
        expect(::System::NodeInstance.where(id: source_instance.id)).to exist
      end

      # The FORWARD leg, distinct from the guard: a fix that taught only the
      # guard to see the alias would refuse every aliased relocate. This proves
      # the resolved value reaches ProvisionFullStackExecutor and buys a disk.
      it "provisions and attaches the aliased volume, then cuts over (positive control)" do
        r = relocate_via_alias(count: 2, storage_gb: 25)

        expect(r[:success]).to be true
        expect(::System::VolumeManagementService).to have_received(:provision)
          .with(hash_including(size_gb: 25)).twice
        expect([ volume_a.reload.node_instance_id, volume_b.reload.node_instance_id ])
          .to match_array([ target_a.id, target_b.id ])
        expect(r[:data][:outputs][:storage_volume_ids]).to match_array([ volume_a.id, volume_b.id ])
        expect(terminated_ids).to eq([ source_instance.id ])
      end

      # The CARD leg. One resolved value feeds card, guard and forward, so the
      # approval card for a :high blast-radius skill must quote the aliased
      # volume and disclose the arm of the guard that can refuse the teardown.
      it "previews the aliased volume and its guard clause on the approval card" do
        plan = relocate_via_alias(count: 2, dry_run: true, storage_gb: 25)[:data][:planned_actions]

        expect(plan.select { |a| a[:step] == "provision_storage" }.map { |a| a[:size_gb] })
          .to eq([ 25, 25 ])
        expect(plan.count { |a| a[:step] == "attach_volume" }).to eq(2)
        expect(plan.select { |a| a[:step] == "terminate_source" }.map { |a| a[:condition] })
          .to all(match(/storage-unready/).and(include("25 GB")))
      end

      # The LOUD lane through the alias: a declared-but-unreadable value
      # creates no volume but must still refuse, exactly as it does under the
      # advertised key (IMP-f85254148755's fork, reached by the other name).
      it "refuses a declared-but-unreadable alias, on which no volume is ever created" do
        r = relocate_via_alias(storage_gb: "plenty")

        # Refused at the door now (IMP-f5532c5c5bd6), so no target is
        # provisioned and none is reclaimed — the alias reaches the same
        # verdict by the other name, which is what this example is for.
        expect(r[:success]).to be false
        expect(r[:error]).to include("storage declared but unreadable")
        expect(r[:error]).not_to include("0 GB")
        expect(::System::VolumeManagementService).not_to have_received(:provision)
        expect(terminated_ids).to be_empty
        expect(::System::NodeInstance.where(id: source_instance.id)).to exist
      end

      # Resolution ORDER, pinned against a wrong-order fix rather than against
      # the pre-fix state: `with_storage_gb` is read first and the first
      # PRESENT value wins, so an explicit 0 — a legitimate "no storage"
      # (IMP-33fa6c51f05d) — beats a positive alias on all three surfaces.
      # `storage_gb || with_storage_gb` would provision 500 GB the operator
      # explicitly declined and refuse the cutover when it failed.
      it "reads with_storage_gb first: an explicit 0 beats a positive alias" do
        r = relocate_via_alias(with_storage_gb: 0, storage_gb: 500)

        expect(r[:success]).to be true
        expect(::System::VolumeManagementService).not_to have_received(:provision)
        expect(terminated_ids).to eq([ source_instance.id ])

        card = relocate_via_alias(dry_run: true, with_storage_gb: 0, storage_gb: 500)[:data][:planned_actions]
        expect(card.map { |a| a[:step] }).not_to include("provision_storage")
        expect(card.select { |a| a[:step] == "terminate_source" }.map { |a| a[:condition] }.join(" | "))
          .not_to match(/storage/)
      end
    end
  end

  describe "#rollback_relocate_workload" do
    let(:new_instance_id) { SecureRandom.uuid }
    let(:volume_id)       { SecureRandom.uuid }

    it "detaches the peers the relocation enrolled, even when the provider rejects the terminate" do
      inst = sdwan_test_node_instance(node: sdwan_test_node(account: account))
      network = ::Sdwan::Network.create!(account_id: account.id, name: "reloc-rb-#{SecureRandom.hex(3)}")
      peer = ::Sdwan::PeerEnroller.call(network: network, node_instance: inst)

      # The path that skips ProvisioningService's own auto-detach: a
      # provider-side terminate failure returns before finalize_termination!.
      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(::System::Runtime::Result.err(error: "provider rejected terminate"))

      r = exec.rollback_relocate_workload(
        node_instance_ids: [ inst.id ],
        storage_volume_ids: [],
        sdwan_peer_ids: [ peer.id ]
      )

      expect(::Sdwan::Peer.where(id: peer.id)).to be_empty
      expect(r[:errors].map { |e| e[:resource] }).to eq([ "node_instance" ])
    end

    # IMP-093378034fb4 — this rollback takes its storage_volume_ids straight
    # from ProvisionFullStackExecutor's envelope, and relocate composes that
    # executor WITH with_storage_gb. Once the inner executor started attaching
    # what it provisions, a terminate-first / delete-without-detach rollback
    # failed every volume with "Volume is attached, detach first" and left the
    # row alive — the same leak the attach fix closed elsewhere, reopened here.
    # Real rows: the refusal is a fact about a persisted volume's FK and cannot
    # be observed on a double.
    it "detaches an attached volume and deletes it BEFORE terminating its instance" do
      inst = create(:system_node_instance, :running,
                    node: create(:system_node, account: account, node_template: template))
      volume = create(:system_provider_volume, :attached, account: account,
                      provider_region: to_region, node_instance: inst)

      adapter = instance_double(::System::Providers::MockProvider,
                                detach_volume: { success: true },
                                delete_volume: { success: true })
      allow(::System::Providers::Registry).to receive(:for_volume).and_return(adapter)

      volume_gone_at_terminate = nil
      allow(::System::ProvisioningService).to receive(:terminate_instance) do
        volume_gone_at_terminate = ::System::ProviderVolume.where(id: volume.id).none?
        ::System::Runtime::Result.ok
      end

      r = exec.rollback_relocate_workload(
        node_instance_ids: [ inst.id ], storage_volume_ids: [ volume.id ], sdwan_peer_ids: []
      )

      expect(r[:errors]).to be_empty
      expect(::System::ProviderVolume.where(id: volume.id)).to be_empty
      # A delete attempted after the terminate would have had nothing left to
      # detach from on the provider side.
      expect(volume_gone_at_terminate).to be(true)
    end

    it "terminates new instances and deletes new volumes; tolerates an unknown sdwan peer id" do
      instance = instance_double("System::NodeInstance", id: new_instance_id)
      volume   = instance_double("System::ProviderVolume", id: volume_id, attached?: false)
      allow(::System::NodeInstance).to receive(:find_by).with(id: new_instance_id).and_return(instance)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(volume)

      ok = ::System::Runtime::Result.ok
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(ok)
      allow(::System::VolumeManagementService).to receive(:delete).and_return(ok)

      r = exec.rollback_relocate_workload(
        node_instance_ids: [ new_instance_id ],
        storage_volume_ids: [ volume_id ],
        sdwan_peer_ids: [ SecureRandom.uuid ]
      )

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end

    it "collects errors when termination fails but does not raise" do
      instance = instance_double("System::NodeInstance", id: new_instance_id)
      allow(::System::NodeInstance).to receive(:find_by).with(id: new_instance_id).and_return(instance)

      bad = ::System::Runtime::Result.err(error: "provider rejected terminate")
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(bad)

      r = exec.rollback_relocate_workload(
        node_instance_ids: [ new_instance_id ],
        storage_volume_ids: [],
        sdwan_peer_ids: []
      )

      expect(r[:success]).to be false
      expect(r[:errors].first).to include(resource: "node_instance", id: new_instance_id)
    end

    it "tolerates the runner forwarding terminated_instance_ids and unknown kwargs" do
      r = exec.rollback_relocate_workload(
        node_instance_ids: [],
        storage_volume_ids: [],
        sdwan_peer_ids: [],
        terminated_instance_ids: [ SecureRandom.uuid ]
      )

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end
  end
end
