# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning plan — slice 8 (M2 adaptive evolution).
# Mirrors provision_full_stack_executor_spec in shape; adapts for the
# strategy switch (add_replicas / vertical_resize / add_region) and the
# unified outputs envelope.
RSpec.describe System::Ai::Skills::ScaleProjectExecutor do
  let(:account)        { create(:account) }
  let(:mission)        { create(:ai_mission, account: account, mission_type: "infrastructure") }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:provider)       { create(:system_provider, account: account) }
  let(:region)         { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type)  { create(:system_provider_instance_type, account: account, provider: provider) }
  let(:exec)           { described_class.new(account: account) }

  let(:instance_stub) do
    instance_double("System::NodeInstance", id: SecureRandom.uuid)
  end

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, instance-method rollback, and blast_radius" do
      d = described_class.descriptor

      expect(d[:name]).to eq("scale_project")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :project_id, :required)).to be true
      expect(d.dig(:inputs, :target_count, :required)).to be true
      expect(d.dig(:inputs, :scaling_strategy, :required)).to be true
      expect(d.dig(:inputs, :template_id, :required)).to be false
      expect(d.dig(:inputs, :module_id, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:node_ids, :node_instance_ids, :sdwan_peer_ids,
                                                    :storage_volume_ids, :rolling_upgrade_plan)
      # INC-4: removal records what it DESTROYED under its own keys, never in
      # the creation keys above.
      expect(d.dig(:outputs, :outputs)).to include(:removed_node_instance_ids,
                                                    :detached_sdwan_peer_ids,
                                                    :deleted_storage_volume_ids, :orphans,
                                                    :floor_reached, :prefix_enforced)
      expect(d[:rollback]).to eq(:rollback_scale_project)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:medium)
    end
  end

  describe "#execute" do
    context "with an unknown strategy" do
      it "rejects" do
        r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "bogus")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/scaling_strategy must be/)
      end
    end

    context "with a missing project" do
      it "returns failure on lookup" do
        r = exec.execute(project_id: SecureRandom.uuid, target_count: 1, scaling_strategy: "add_replicas",
                         template_id: template.id, provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/project not found/)
      end
    end

    context "add_replicas" do
      it "rejects out-of-bounds target_count" do
        r = exec.execute(project_id: mission.id, target_count: 0, scaling_strategy: "add_replicas",
                         template_id: template.id, provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/target_count must be/)
      end

      it "rejects above MAX_DELTA" do
        r = exec.execute(project_id: mission.id, target_count: described_class::MAX_DELTA + 1,
                         scaling_strategy: "add_replicas",
                         template_id: template.id, provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
      end

      it "requires template_id" do
        r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "add_replicas",
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/template_id is required/)
      end

      context "in dry_run mode" do
        it "returns a plan without provisioning anything" do
          expect(::System::ProvisioningService).not_to receive(:provision_instance)

          r = exec.execute(project_id: mission.id, target_count: 2, scaling_strategy: "add_replicas",
                           template_id: template.id, provider_region_id: region.id,
                           provider_instance_type_id: instance_type.id,
                           dry_run: true)

          expect(r[:success]).to be true
          d = r[:data]
          expect(d[:dry_run]).to be true
          expect(d[:scaling_strategy]).to eq("add_replicas")
          expect(d[:count]).to eq(2)
          expect(d[:planned_actions].first[:step]).to eq("scale_project")
          expect(d[:outputs][:node_ids]).to be_empty
        end
      end

      context "in execute mode (provisioning stubbed at the service layer)" do
        let(:ok_prov) do
          ::System::Runtime::Result.ok(data: { instance: instance_stub, cloud_instance_id: "ci-abc" })
        end

        before do
          allow(::System::ProvisioningService).to receive(:provision_instance).and_return(ok_prov)
        end

        it "delegates to ProvisionFullStackExecutor and returns structured outputs" do
          r = exec.execute(project_id: mission.id, target_count: 2, scaling_strategy: "add_replicas",
                           template_id: template.id, provider_region_id: region.id,
                           provider_instance_type_id: instance_type.id)

          expect(r[:success]).to be true
          d = r[:data]
          expect(d[:scaling_strategy]).to eq("add_replicas")
          expect(d[:count]).to eq(2)
          expect(d[:outputs][:node_instance_ids].size).to eq(2)
          expect(::System::ProvisioningService).to have_received(:provision_instance).twice
        end
      end
    end

    context "add_region" do
      let(:other_region) { create(:system_provider_region, account: account, provider: provider) }
      let(:ok_prov) do
        ::System::Runtime::Result.ok(data: { instance: instance_stub, cloud_instance_id: "ci-r2" })
      end

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(ok_prov)
      end

      it "provisions a parallel stack at the new region" do
        r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "add_region",
                         template_id: template.id, provider_region_id: other_region.id,
                         provider_instance_type_id: instance_type.id)

        expect(r[:success]).to be true
        expect(r[:data][:scaling_strategy]).to eq("add_region")
        expect(r[:data][:outputs][:node_instance_ids].size).to eq(1)
      end
    end

    context "vertical_resize" do
      let(:category) { create(:system_node_module_category, account: account) }
      let(:mod) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "vresize-mod")
      end
      let!(:target_version) do
        ::System::NodeModuleVersion.create!(
          node_module: mod, version_number: 7,
          mask: [], file_spec: [], package_spec: [], config: {},
          oci_digest: "sha256:#{'c' * 64}"
        )
      end

      it "requires module_id and target_version_id" do
        r = exec.execute(project_id: mission.id, target_count: 0, scaling_strategy: "vertical_resize",
                         template_id: template.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/module_id is required/)
      end

      it "in dry_run, returns a plan with no rolling upgrade execution" do
        # Ensure RollingModuleUpgradeExecutor is NOT instantiated in dry_run
        expect(::System::Ai::Skills::RollingModuleUpgradeExecutor).not_to receive(:new)

        r = exec.execute(project_id: mission.id, target_count: 0, scaling_strategy: "vertical_resize",
                         template_id: template.id, module_id: mod.id,
                         target_version_id: target_version.id, dry_run: true)

        expect(r[:success]).to be true
        expect(r[:data][:dry_run]).to be true
        expect(r[:data][:planned_actions].first[:step]).to eq("rolling_module_upgrade_plan")
        expect(r[:data][:outputs][:rolling_upgrade_plan]).to be_nil
      end

      it "delegates to RollingModuleUpgradeExecutor and surfaces the batched plan" do
        plan = { total_instances: 5, batch_size: 1, batch_count: 5,
                 estimated_total_seconds: 600, batches: [], requires_approval: true }
        rmu = instance_double(::System::Ai::Skills::RollingModuleUpgradeExecutor,
                              execute: { success: true, data: plan })
        allow(::System::Ai::Skills::RollingModuleUpgradeExecutor).to receive(:new).and_return(rmu)

        r = exec.execute(project_id: mission.id, target_count: 0, scaling_strategy: "vertical_resize",
                         template_id: template.id, module_id: mod.id,
                         target_version_id: target_version.id)

        expect(r[:success]).to be true
        expect(r[:data][:scaling_strategy]).to eq("vertical_resize")
        expect(r[:data][:count]).to eq(5)
        expect(r[:data][:outputs][:rolling_upgrade_plan]).to eq(plan)
      end
    end

    # INC-4 (IMP-216a6dbc7e32) — the fourth strategy. Until it landed the
    # executor's ONLY instance-terminating path was its own rollback, so a
    # composed downscale had no bindable actuator.
    #
    # Every assertion below reads GROUND TRUTH (rows, statuses, membership
    # mirrors) rather than the returned envelope. The provider adapter — the
    # one genuinely external dependency — is the only thing stubbed, so
    # ProvisioningService, Sdwan::PeerDetacher and VolumeManagementService all
    # really run against the DB. A spec that stubbed
    # `ProvisioningService.terminate_instance` would assert nothing about the
    # orphan classes this strategy exists to avoid.
    context "remove_replicas" do
      let(:prefix)  { "dryrun-evo-01" }
      let(:mission) do
        create(:ai_mission, account: account, mission_type: "infrastructure",
                            configuration: { "name_prefix" => prefix })
      end

      let(:provider_adapter) do
        instance_double(::System::Providers::MockProvider,
                        terminate_instance: { success: true },
                        detach_volume: { success: true },
                        delete_volume: { success: true })
      end

      before do
        allow(::System::Providers::Registry).to receive(:for_instance).and_return(provider_adapter)
        allow(::System::Providers::Registry).to receive(:for_volume).and_return(provider_adapter)
      end

      # Reproduces exactly what ProvisionFullStackExecutor#create_node! stamps:
      # mission provenance in node.config, and a prefixed node name the
      # instance name derives from.
      # The full production naming chain: create_node! prefixes the NODE name,
      # provision_instance derives the instance name from it, and a
      # per-instance volume is "<node name>-data". Every containment rail
      # reads one of those three, so the fixture has to build all three the
      # way the provisioning path does.
      def replica!(minutes_old:, name: nil, mission_owned: true)
        node = create(:system_node, account: account, node_template: template,
                                    name: "#{prefix}-web-#{SecureRandom.hex(3)}",
                                    config: mission_owned ? { "mission_id" => mission.id } : {})
        create(:system_node_instance, :running, node: node,
               provider_region: region, provider_instance_type: instance_type,
               name: name || "#{node.name}-instance-#{SecureRandom.hex(2)}",
               created_at: minutes_old.minutes.ago)
      end

      def volume_for!(instance, **attrs)
        create(:system_provider_volume, :attached, account: account, provider_region: region,
               node_instance: instance, name: "#{instance.node.name}-data", **attrs)
      end

      def statuses_of(*instances)
        instances.map { |i| ::System::NodeInstance.find(i.id).status }
      end

      it "is an advertised strategy" do
        expect(described_class::STRATEGIES).to include("remove_replicas")
      end

      it "rejects out-of-bounds target_count exactly like the additive strategies" do
        expect(exec.execute(project_id: mission.id, target_count: 0,
                            scaling_strategy: "remove_replicas")[:success]).to be false
        expect(exec.execute(project_id: mission.id, target_count: described_class::MAX_DELTA + 1,
                            scaling_strategy: "remove_replicas")[:success]).to be false
      end

      it "terminates the NEWEST replica of the mission's own set" do
        oldest = replica!(minutes_old: 30)
        middle = replica!(minutes_old: 20)
        newest = replica!(minutes_old: 10)

        r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas")

        expect(r[:success]).to be true
        expect(r[:data][:scaling_strategy]).to eq("remove_replicas")
        expect(r[:data][:count]).to eq(1)
        # Ground truth, not the envelope: only the newest row is terminated.
        expect(statuses_of(newest)).to eq(%w[terminated])
        expect(statuses_of(oldest, middle)).to eq(%w[running running])
        expect(r[:data][:outputs][:removed_node_instance_ids]).to eq([ newest.id ])
      end

      it "records terminations OUTSIDE node_instance_ids so no creation oracle can grade it" do
        replica!(minutes_old: 30)
        victim = replica!(minutes_old: 10)

        outs = exec.execute(project_id: mission.id, target_count: 1,
                            scaling_strategy: "remove_replicas")[:data][:outputs]

        # VerificationService derives a step's expected instance count from the
        # step inputs and compares it against outputs.node_instance_ids. A
        # removal that reported its victims there would be graded by an
        # instance-CREATION oracle, fail permanently, and — because the
        # adaptation lane settles on verification — leave every later
        # adaptation on the mission unable to settle.
        expect(outs[:node_instance_ids]).to be_empty
        expect(outs[:storage_volume_ids]).to be_empty
        expect(outs[:removed_node_instance_ids]).to eq([ victim.id ])
      end

      it "never scales to zero — the floor clamps an oversized request" do
        oldest = replica!(minutes_old: 30)
        newest = replica!(minutes_old: 10)

        r = exec.execute(project_id: mission.id, target_count: 5, scaling_strategy: "remove_replicas")

        expect(r[:success]).to be true
        expect(r[:data][:count]).to eq(1)
        expect(statuses_of(newest)).to eq(%w[terminated])
        expect(statuses_of(oldest)).to eq(%w[running])
      end

      it "removes NOTHING when the mission is already at the floor" do
        only_one = replica!(minutes_old: 30)

        r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas")

        expect(r[:success]).to be true
        expect(r[:data][:count]).to eq(0)
        expect(r[:data][:outputs][:floor_reached]).to be true
        expect(statuses_of(only_one)).to eq(%w[running])
      end

      it "draws victims ONLY from the mission's own replicas, never fleet-wide" do
        mine_old   = replica!(minutes_old: 40)
        mine_new   = replica!(minutes_old: 30)
        # Newer than every replica of this mission — a fleet-wide "newest
        # first" query would take these first.
        foreign_a  = replica!(minutes_old: 5, mission_owned: false)
        foreign_b  = replica!(minutes_old: 1, mission_owned: false)

        r = exec.execute(project_id: mission.id, target_count: 5, scaling_strategy: "remove_replicas")

        expect(r[:success]).to be true
        expect(r[:data][:count]).to eq(1)
        expect(statuses_of(mine_new)).to eq(%w[terminated])
        expect(statuses_of(mine_old, foreign_a, foreign_b)).to eq(%w[running running running])
      end

      it "HARD ERRORS on a victim outside the mission's prefix and terminates nothing" do
        keeper = replica!(minutes_old: 30)
        stray  = replica!(minutes_old: 10, name: "unprefixed-stray-1")

        r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas")

        expect(r[:success]).to be false
        expect(r[:error]).to match(/prefix/i)
        expect(r[:error]).to include("unprefixed-stray-1")
        # The halt is BEFORE teardown so forensics survive.
        expect(statuses_of(keeper, stray)).to eq(%w[running running])
      end

      it "plans without terminating anything in dry_run" do
        victim = replica!(minutes_old: 10)
        replica!(minutes_old: 30)
        expect(::System::ProvisioningService).not_to receive(:terminate_instance)

        r = exec.execute(project_id: mission.id, target_count: 1,
                         scaling_strategy: "remove_replicas", dry_run: true)

        expect(r[:success]).to be true
        expect(r[:data][:dry_run]).to be true
        expect(r[:data][:count]).to eq(1)
        expect(r[:data][:planned_actions].first[:step]).to eq("scale_project")
        expect(statuses_of(victim)).to eq(%w[running])
      end

      it "classifies the removal as irreversible and approval-bound" do
        replica!(minutes_old: 30)
        replica!(minutes_old: 10)

        d = exec.execute(project_id: mission.id, target_count: 1,
                         scaling_strategy: "remove_replicas")[:data]

        # Ratified §4: removals never auto-apply, regardless of bounds. The
        # core-side enforcement is AdaptationProposerService#auto_apply?'s
        # additive-only allowlist (asserted in its own spec); the envelope
        # carries the classification so the gate and the audit trail see it.
        expect(d[:irreversible]).to be true
        expect(d[:requires_approval]).to be true
      end

      it "can remove the replicas its own add_replicas arm created" do
        # Faithful to ProvisioningService#generate_instance_name: the instance
        # name DERIVES from the node's, which is how the mission's prefix
        # reaches the substrate. A stub that named instances anything else
        # would quietly make the containment rail untestable here.
        allow(::System::ProvisioningService).to receive(:provision_instance) do |node:, **_|
          inst = create(:system_node_instance, :running, node: node, provider_region: region,
                        provider_instance_type: instance_type,
                        name: "#{node.name}-instance-#{SecureRandom.hex(2)}")
          ::System::Runtime::Result.ok(data: { instance: inst, cloud_instance_id: inst.cloud_instance_id })
        end
        seed = replica!(minutes_old: 60)

        added = exec.execute(project_id: mission.id, target_count: 2, scaling_strategy: "add_replicas",
                             template_id: template.id, provider_region_id: region.id,
                             provider_instance_type_id: instance_type.id)
        expect(added[:success]).to be true

        # Scale-out has to stamp the provenance scale-in queries on, or the two
        # arms address different fleets: the removal would skip everything the
        # scale-out just created and eat the mission's original capacity
        # instead — the exact inverse of "undo the most recent scale-out".
        r = exec.execute(project_id: mission.id, target_count: 2, scaling_strategy: "remove_replicas")

        expect(r[:success]).to be true
        expect(r[:data][:outputs][:removed_node_instance_ids])
          .to match_array(added[:data][:outputs][:node_instance_ids])
        expect(statuses_of(seed)).to eq(%w[running])
      end

      it "reports WHICH prefix it enforced, so a nil one is never read as a pass" do
        no_prefix_mission = create(:ai_mission, account: account, mission_type: "infrastructure",
                                                configuration: {})
        node = create(:system_node, account: account, node_template: template,
                                    config: { "mission_id" => no_prefix_mission.id })
        create(:system_node_instance, :running, node: node, provider_region: region,
               provider_instance_type: instance_type, created_at: 30.minutes.ago)
        create(:system_node_instance, :running, node: node, provider_region: region,
               provider_instance_type: instance_type, created_at: 10.minutes.ago)

        with_prefix = exec.execute(project_id: mission.id, target_count: 1,
                                   scaling_strategy: "remove_replicas", dry_run: true)
        without = exec.execute(project_id: no_prefix_mission.id, target_count: 1,
                               scaling_strategy: "remove_replicas", dry_run: true)

        # A mission that declares no marker leaves the rail unmeasured, not
        # satisfied — the envelope has to say which of the two it was.
        expect(with_prefix[:data][:outputs][:prefix_enforced]).to eq(prefix)
        expect(without[:data][:outputs][:prefix_enforced]).to be_nil
      end

      it "FAILS rather than reporting a clean zero when the victim vanished mid-flight" do
        replica!(minutes_old: 30)
        victim = replica!(minutes_old: 10)
        # Selected, then destroyed by something else before teardown.
        # teardown_resources skips a row it cannot find, recording neither an
        # error nor a termination — so nothing removed AND nothing failed
        # would otherwise read as a successful removal of zero.
        allow(::System::NodeInstance).to receive(:find_by).and_call_original
        allow(::System::NodeInstance).to receive(:find_by).with(id: victim.id).and_return(nil)

        r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas")

        expect(r[:success]).to be false
        expect(r[:error]).to match(/removed nothing/i)
      end

      it "FAILS the step when a victim could not be terminated at all" do
        keeper = replica!(minutes_old: 40)
        older  = replica!(minutes_old: 30)
        victim = replica!(minutes_old: 10)
        allow(provider_adapter).to receive(:terminate_instance)
          .and_return({ success: false, error: "provider rejected terminate" })

        r = exec.execute(project_id: mission.id, target_count: 2, scaling_strategy: "remove_replicas")

        # A removal that removed NOTHING must not come back as a completed
        # step: the runner would mark it done, skip `on_failure: rollback`, and
        # dispatch successors as though capacity had gone away.
        expect(r[:success]).to be false
        expect(r[:error]).to match(/provider rejected terminate/)
        expect(statuses_of(keeper, older, victim)).to eq(%w[running running running])
      end

      context "zero-orphan invariant" do
        let(:network) { create(:sdwan_network, account: account) }

        it "leaves no orphaned peer, membership mirror, volume, or live instance" do
          replica!(minutes_old: 30)
          victim = replica!(minutes_old: 10)

          peer = create(:sdwan_peer, account: account, network: network, node_instance: victim)
          central = create(:system_node_instance_peer, node_instance: victim,
                           capabilities: { "sdwan" => { "networks" => [ { "network_id" => network.id } ] } })
          volume = volume_for!(victim)

          r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas")

          expect(r[:success]).to be true
          # Ground truth for every resource class in the invariant.
          expect(::Sdwan::Peer.where(id: peer.id).count).to eq(0)
          expect(::System::ProviderVolume.where(id: volume.id).count).to eq(0)
          expect(::System::ProviderVolume.where(node_instance_id: victim.id).count).to eq(0)
          expect(central.reload.capabilities["sdwan"]).to be_nil
          expect(statuses_of(victim)).to eq(%w[terminated])

          outs = r[:data][:outputs]
          expect(outs[:orphans]).to be_empty
          expect(outs[:detached_sdwan_peer_ids]).to eq([ peer.id ])
          expect(outs[:deleted_storage_volume_ids]).to eq([ volume.id ])
        end

        it "catches a volume that survived its delete even though detach cleared the FK" do
          replica!(minutes_old: 30)
          victim = replica!(minutes_old: 10)
          volume = volume_for!(victim)
          # ProviderVolume#detach! nulls node_instance_id, so a sweep that
          # re-queries by FK sees nothing and blesses the leak. The victim's
          # volume ids are captured BEFORE teardown for exactly this reason.
          allow(provider_adapter).to receive(:delete_volume)
            .and_return({ success: false, error: "volume busy" })

          r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas")

          expect(::System::ProviderVolume.where(id: volume.id).count).to eq(1)
          expect(r[:data][:outputs][:orphans].to_s).to include(volume.id)
          expect(r[:data][:failures]).not_to be_empty
        end

        it "REFUSES to delete a volume that does not carry the mission's prefix" do
          replica!(minutes_old: 30)
          victim = replica!(minutes_old: 10)
          # A volume the mission provisioned is named after its node, so it
          # inherits the prefix. One that does not is somebody else's — an
          # operator's data disk hand-attached to a replica — and deleting it
          # is irreversible under an approval that only described removing
          # replicas. Same rail as the instance side, same hard error.
          stray = create(:system_provider_volume, :attached, account: account,
                         provider_region: region, node_instance: victim,
                         name: "operator-data-disk")

          r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas")

          expect(r[:success]).to be false
          expect(r[:error]).to include("operator-data-disk")
          expect(::System::ProviderVolume.where(id: stray.id).count).to eq(1)
          expect(statuses_of(victim)).to eq(%w[running])
        end

        it "names what it already destroyed when the terminate then fails" do
          replica!(minutes_old: 30)
          victim = replica!(minutes_old: 10)
          volume = volume_for!(victim)
          # Volumes go first by design, so a terminate failure lands AFTER the
          # disks are already gone. Returning a bare failure would leave no
          # machine-readable trace of what was destroyed.
          allow(provider_adapter).to receive(:terminate_instance)
            .and_return({ success: false, error: "provider rejected terminate" })

          r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas")

          expect(r[:success]).to be false
          expect(r[:error]).to include(volume.id)
          expect(::System::ProviderVolume.where(id: volume.id).count).to eq(0)
        end

        it "HALTS on the first orphan instead of tearing down the next victim" do
          replica!(minutes_old: 40)
          older_victim = replica!(minutes_old: 30)
          newest_victim = replica!(minutes_old: 10)
          orphan_peer = create(:sdwan_peer, account: account, network: network,
                               node_instance: newest_victim)
          # A detach that silently does nothing is exactly the FK-orphan class
          # this invariant exists for — the peer survives its instance.
          allow(::Sdwan::PeerDetacher).to receive(:call).and_return([])

          r = exec.execute(project_id: mission.id, target_count: 2, scaling_strategy: "remove_replicas")

          expect(::Sdwan::Peer.where(id: orphan_peer.id).count).to eq(1)
          expect(r[:data][:outputs][:orphans]).not_to be_empty
          expect(r[:data][:failures]).not_to be_empty
          # Halted: the second victim is untouched, so an operator can see the
          # orphan against a fleet that still matches the plan.
          expect(statuses_of(older_victim)).to eq(%w[running])
        end
      end
    end
  end

  describe "#rollback_scale_project" do
    let(:instance_id_a) { SecureRandom.uuid }
    let(:volume_id)     { SecureRandom.uuid }

    it "reverses recorded outputs uniformly with the M0 envelope" do
      instance_a = instance_double("System::NodeInstance", id: instance_id_a)
      # attached? gates the detach the shared teardown does before deleting —
      # a rollback's volumes were provisioned unattached.
      volume     = instance_double("System::ProviderVolume", id: volume_id, attached?: false)

      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_a).and_return(instance_a)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(volume)

      ok = ::System::Runtime::Result.ok
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(ok)
      allow(::System::VolumeManagementService).to receive(:delete).and_return(ok)

      r = exec.rollback_scale_project(node_instance_ids: [ instance_id_a ], storage_volume_ids: [ volume_id ])

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end

    it "collects errors when termination fails but does not raise" do
      instance_a = instance_double("System::NodeInstance", id: instance_id_a)
      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_a).and_return(instance_a)

      bad = ::System::Runtime::Result.err(error: "provider rejected terminate")
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(bad)

      r = exec.rollback_scale_project(node_instance_ids: [ instance_id_a ], storage_volume_ids: [])

      expect(r[:success]).to be false
      expect(r[:errors].first).to include(resource: "node_instance", id: instance_id_a)
    end

    it "ignores extra kwargs the runner forwards (sdwan_peer_ids, rolling_upgrade_plan)" do
      r = exec.rollback_scale_project(
        node_instance_ids: [], storage_volume_ids: [],
        sdwan_peer_ids: [ SecureRandom.uuid ], rolling_upgrade_plan: { foo: "bar" }
      )

      expect(r[:success]).to be true
      expect(r[:errors]).to be_empty
    end
  end
end
