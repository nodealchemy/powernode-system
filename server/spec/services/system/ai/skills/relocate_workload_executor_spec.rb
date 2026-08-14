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
      def card(strategy:, network_id: nil)
        r = exec.execute(project_id: mission.id, from_region_id: from_region.id,
                         to_region_id: to_region.id, cutover_strategy: strategy,
                         template_id: template.id,
                         provider_instance_type_id: instance_type.id, count: 2,
                         source_instance_ids: [ source_instance.id ],
                         network_id: network_id, dry_run: true)
        expect(r[:success]).to be true
        r[:data][:planned_actions]
      end

      # IMP-6b497651d670 + IMP-bb73f7154f27 — the card must disclose BOTH
      # sides of every refusal arm on this :high blast-radius skill: the
      # guard that may decline the terminate (now undersized, subsuming
      # empty, per the :233 undercount hole) AND what happens to the fresh
      # target stack when it does (reclaimed; sources untouched).
      it "marks blue_green terminate steps conditional, naming the guard, the undersized refusal, and the reclaim" do
        terminate = card(strategy: "blue_green").select { |a| a[:step] == "terminate_source" }

        expect(terminate).not_to be_empty
        expect(terminate).to all(include(conditional: true, guard: "blue_green_cutover"))
        expect(terminate.map { |a| a[:condition] })
          .to all(match(/undersized/).and(match(/target stack is reclaimed/)).and(match(/sources are left untouched/)))
      end

      it "names the requested network in the condition when enrollment also gates the cutover" do
        network = ::Sdwan::Network.create!(account_id: account.id, name: "reloc-net-#{SecureRandom.hex(3)}")
        terminate = card(strategy: "blue_green", network_id: network.id)
                      .select { |a| a[:step] == "terminate_source" }

        expect(terminate).not_to be_empty
        expect(terminate).to all(include(conditional: true, guard: "blue_green_cutover"))
        expect(terminate.map { |a| a[:condition] })
          .to all(match(/off-fabric/).and(include(network.id)).and(match(/target stack is reclaimed/)))
      end

      # Negative control (positive twins above): drain terminates FIRST — no
      # guard exists on its path, so a conditional marker would promise a
      # safety the run does not have.
      it "leaves drain terminate steps unconditional" do
        terminate = card(strategy: "drain").select { |a| a[:step] == "terminate_source" }

        expect(terminate).not_to be_empty
        expect(terminate).to all(eq({ step: "terminate_source", instance_id: source_instance.id }))
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
