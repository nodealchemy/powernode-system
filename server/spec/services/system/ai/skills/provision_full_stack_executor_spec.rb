# frozen_string_literal: true

require "rails_helper"

# AI-Driven Provisioning plan — slice 4 (M0). Mirrors
# provision_cluster_executor_spec.rb in shape; adapts for the richer outputs
# (node_instance_ids, sdwan_peer_ids, storage_volume_ids) and the
# class-method rollback contract.
RSpec.describe System::Ai::Skills::ProvisionFullStackExecutor do
  let(:account)        { create(:account) }
  let(:platform)       { create(:system_node_platform, account: account) }
  let(:template)       { create(:system_node_template, account: account, node_platform: platform) }
  let(:provider)       { create(:system_provider, account: account) }
  let(:region)         { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type)  { create(:system_provider_instance_type, account: account, provider: provider) }
  let(:exec)           { described_class.new(account: account) }

  # Stand-in for a real System::NodeInstance — we only need an .id surface
  # for the executor's outputs, so an instance_double is sufficient.
  let(:instance_stub) do
    instance_double("System::NodeInstance", id: SecureRandom.uuid)
  end
  let(:volume_stub) do
    instance_double("System::ProviderVolume", id: SecureRandom.uuid)
  end

  describe ".descriptor" do
    it "advertises required inputs, structured outputs, rollback, and blast_radius" do
      d = described_class.descriptor

      expect(d[:name]).to eq("provision_full_stack")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :template_id, :required)).to be true
      expect(d.dig(:inputs, :count, :required)).to be true
      expect(d.dig(:inputs, :provider_region_id, :required)).to be true
      expect(d.dig(:inputs, :provider_instance_type_id, :required)).to be true
      expect(d.dig(:inputs, :network_id, :required)).to be false
      expect(d.dig(:inputs, :with_storage_gb, :required)).to be false
      expect(d.dig(:outputs, :outputs)).to include(:node_ids, :node_instance_ids, :sdwan_peer_ids, :storage_volume_ids)
      expect(d[:rollback]).to eq(:rollback_provision_full_stack)
      expect(d[:requires_approval]).to be false
      expect(d[:blast_radius]).to eq(:medium)
    end
  end

  describe "#execute" do
    context "with invalid count" do
      it "rejects 0" do
        r = exec.execute(template_id: template.id, count: 0,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/count must be/)
      end

      it "rejects above MAX_COUNT" do
        r = exec.execute(template_id: template.id, count: described_class::MAX_COUNT + 1,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
      end
    end

    context "with a missing template" do
      it "returns failure on lookup" do
        r = exec.execute(template_id: SecureRandom.uuid, count: 1,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/template not found/)
      end
    end

    context "with a missing provider_region_id" do
      it "returns failure" do
        r = exec.execute(template_id: template.id, count: 1,
                         provider_region_id: SecureRandom.uuid,
                         provider_instance_type_id: instance_type.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/provider region not found/)
      end
    end

    context "in dry_run mode" do
      it "returns a plan without provisioning anything" do
        expect(::System::ProvisioningService).not_to receive(:provision_instance)
        expect(::System::VolumeManagementService).not_to receive(:provision)

        r = exec.execute(template_id: template.id, count: 3,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id,
                         with_storage_gb: 50, dry_run: true)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:dry_run]).to be true
        expect(d[:count]).to eq(3)
        expect(d[:outputs]).to eq(node_ids: [], node_instance_ids: [], sdwan_peer_ids: [], storage_volume_ids: [])
        # 3 nodes × (create + provision + storage + attach) = 12 planned steps.
        # The attach is planned because it is performed (IMP-093378034fb4) — a
        # dry run that under-lists what execute does is how a plan stops being
        # a preview of it.
        expect(d[:planned_actions].size).to eq(12)
        expect(d[:planned_actions].first[:step]).to eq("create_node")
        expect(d[:planned_actions].map { |a| a[:step] }).to include("attach_volume")
      end
    end

    context "in execute mode (provisioning stubbed at the service layer)" do
      let(:ok_prov) do
        ::System::Runtime::Result.ok(data: { instance: instance_stub, cloud_instance_id: "ci-abc" })
      end

      before do
        allow(::System::ProvisioningService).to receive(:provision_instance).and_return(ok_prov)
      end

      it "creates N nodes, dispatches N provision calls, and returns structured outputs" do
        r = exec.execute(template_id: template.id, count: 2,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)

        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:count]).to eq(2)
        expect(d[:outputs][:node_ids].size).to eq(2)
        expect(d[:outputs][:node_instance_ids].size).to eq(2)
        expect(d[:outputs][:storage_volume_ids]).to be_empty
        expect(d[:outputs][:sdwan_peer_ids]).to be_empty
        expect(d[:failures]).to be_empty
        expect(::System::ProvisioningService).to have_received(:provision_instance).twice
      end

      # F3 (IMP 019fe4c4-e813): all four dryrun VMs came out named
      # powernode-ops-cell-N-<hex> — the mission's dryrun- marker never
      # reached the substrate, so the charter's prefix rail was decorative
      # and teardown fell back to hand-collected instance ids.
      it "prefixes node names with name_prefix and stamps mission provenance" do
        r = exec.execute(template_id: template.id, count: 2,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id,
                         name_prefix: "dryrun-20260809d", mission_id: "m-123")

        expect(r[:success]).to be true
        nodes = ::System::Node.where(id: r[:data][:outputs][:node_ids])
        expect(nodes.count).to eq(2)
        nodes.each do |n|
          expect(n.name).to start_with("dryrun-20260809d-")
          expect(n.config["mission_id"]).to eq("m-123")
        end
      end

      it "keeps template-derived names and stamps no provenance when none given" do
        r = exec.execute(template_id: template.id, count: 1,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)

        node = ::System::Node.find(r[:data][:outputs][:node_ids].first)
        expect(node.name).to start_with(template.name.parameterize)
        expect(node.config).not_to have_key("mission_id")
      end

      context "with with_storage_gb" do
        let(:ok_vol) { ::System::Runtime::Result.ok(data: { volume: volume_stub }) }

        before do
          allow(::System::VolumeManagementService).to receive(:provision).and_return(ok_vol)
          allow(::System::VolumeManagementService).to receive(:attach)
            .and_return(::System::Runtime::Result.ok(data: { device: "/dev/sdb" }))
        end

        it "provisions a per-instance volume" do
          r = exec.execute(template_id: template.id, count: 2,
                           provider_region_id: region.id,
                           provider_instance_type_id: instance_type.id,
                           with_storage_gb: 100)

          expect(r[:success]).to be true
          expect(r[:data][:outputs][:storage_volume_ids].size).to eq(2)
          expect(::System::VolumeManagementService).to have_received(:provision).twice
        end

        # IMP-093378034fb4 — the volume was provisioned and never attached, so
        # ProviderVolume#node_instance_id stayed nil. That FK is how BOTH the
        # scale-in teardown (ScaleProjectExecutor#victim_volumes) and its
        # zero-orphan sweep (#orphans_for) reach a victim's volumes, so the
        # check built to catch a leaked volume could not see one: scale-in
        # reported zero orphans while the volume billed on.
        #
        # Real rows throughout, and the real VolumeManagementService.attach —
        # only the provider adapter is stubbed. A nil FK is a fact about a
        # persisted row; it cannot be observed on a double, and a spec that
        # asserted `have_received(:attach)` would prove the call was made, not
        # that anything now points at the instance.
        context "attachment (real rows — the FK the teardown reads)" do
          let(:storage_node) { create(:system_node, account: account, node_template: template) }
          let(:provisioned_instance) do
            create(:system_node_instance, :running, node: storage_node,
                   provider_region: region, provider_instance_type: instance_type)
          end
          let(:real_volume) do
            create(:system_provider_volume, account: account, provider_region: region,
                   status: "available", external_id: "vol-#{SecureRandom.hex(6)}")
          end
          let(:volume_adapter) do
            instance_double(::System::Providers::MockProvider,
                            attach_volume: { success: true, device: "/dev/sdb" })
          end

          before do
            allow(::System::ProvisioningService).to receive(:provision_instance).and_return(
              ::System::Runtime::Result.ok(
                data: { instance: provisioned_instance,
                        cloud_instance_id: provisioned_instance.cloud_instance_id }
              )
            )
            allow(::System::VolumeManagementService).to receive(:provision)
              .and_return(::System::Runtime::Result.ok(data: { volume: real_volume }))
            allow(::System::VolumeManagementService).to receive(:attach).and_call_original
            allow(::System::Providers::Registry).to receive(:for_volume).and_return(volume_adapter)
          end

          def provision_one_with_storage
            exec.execute(template_id: template.id, count: 1,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id,
                         with_storage_gb: 100)
          end

          it "attaches the volume to the instance it provisioned it for" do
            r = provision_one_with_storage

            expect(r[:success]).to be true
            expect(r[:data][:failures]).to be_empty
            # Ground truth: the persisted FK, not the call.
            expect(real_volume.reload.node_instance_id).to eq(provisioned_instance.id)
            expect(real_volume).to be_attached
            expect(real_volume.device_name).to eq("/dev/sdb")
          end

          it "records the attach as its own planned action, so a plan can be graded on it" do
            r = provision_one_with_storage

            attach = r[:data][:planned_actions].find { |a| a[:step] == "attach_volume" }
            expect(attach).not_to be_nil,
                                  "no attach_volume action: #{r[:data][:planned_actions].inspect}"
            expect(attach[:volume_id]).to eq(real_volume.id)
            expect(attach[:instance_id]).to eq(provisioned_instance.id)
          end

          it "reports a FAILURE rather than a clean provision when the attach fails" do
            allow(volume_adapter).to receive(:attach_volume)
              .and_return({ success: false, error: "no free device" })

            r = provision_one_with_storage
            d = r[:data]

            # An unattached volume bills and is out of reach of scale-in. The
            # only thing that surfaces it is a loud partial — silence here is
            # the failure mode this task exists to remove.
            expect(d[:failures].map { |f| f[:step] }).to include("attach_volume")
            expect(d[:partial]).to be true
            # Still recorded, so the rollback path can reclaim it.
            expect(d[:outputs][:storage_volume_ids]).to eq([ real_volume.id ])
            expect(real_volume.reload.node_instance_id).to be_nil
          end

          it "does not let an attach raise take out the step and orphan what it created" do
            allow(::System::VolumeManagementService).to receive(:attach)
              .and_raise(::System::VolumeManagementService::VolumeError, "No available device paths")

            r = provision_one_with_storage
            d = r[:data]

            expect(r[:success]).to be true
            expect(d[:outputs][:node_instance_ids]).to eq([ provisioned_instance.id ])
            expect(d[:failures].map { |f| f[:step] }).to include("attach_volume")
          end
        end

        # IMP-33fa6c51f05d — the guard was `next if with_storage_gb.blank?`,
        # and `0.blank?` is FALSE in Ruby, so an explicit 0 sailed past it and
        # reached VolumeManagementService.provision as a real 0 GB volume
        # request. PlanComposerService#brief_storage_gb drops non-positives
        # before stamping, so a COMPOSED plan never carried one — the reachable
        # writers are a hand-authored plan_data, a MissionComposer output, and
        # an operator-supplied input, i.e. exactly the direct-dispatch paths
        # the composer's `||=` is documented to let win.
        #
        # It did not leak a 0 GB volume — ProviderVolume validates size_gb as
        # `greater_than: 0`, so the create raised and came back as an err
        # Result. It produced one fabricated `provision_storage` failure per
        # node and a `partial: true` envelope, i.e. a run that asked for no
        # storage reporting itself as partially failed. Meanwhile
        # CostEstimatorService#declared_gb already clamped non-positive to "not
        # requested", so the approval card showed no volume line at all — the
        # quote and the actuator disagreed about the same input.
        context "with a non-positive with_storage_gb" do
          # Stubbed to SUCCEED, deliberately. If the guard lets a 0 through,
          # the example has to fail on "the provisioner was called" and not on
          # a nil result crashing the leg — a red that points at the wrong
          # thing is a red that gets fixed the wrong way.
          before do
            allow(::System::VolumeManagementService).to receive(:provision)
              .and_return(::System::Runtime::Result.ok(data: { volume: volume_stub }))
            allow(::System::VolumeManagementService).to receive(:attach)
              .and_return(::System::Runtime::Result.ok(data: { device: "/dev/sdb" }))
          end

          # Each shape is its own example rather than one loop, because they
          # fail for different reasons and a loop reports only the first.
          {
            "integer 0"    => 0,
            "string \"0\"" => "0",
            "negative"     => -50,
            "non-numeric"  => "plenty"
          }.each do |label, value|
            it "provisions no volume for #{label}" do
              r = exec.execute(template_id: template.id, count: 2,
                               provider_region_id: region.id,
                               provider_instance_type_id: instance_type.id,
                               with_storage_gb: value)

              expect(r[:success]).to be true
              expect(::System::VolumeManagementService).not_to have_received(:provision)
              expect(r[:data][:outputs][:storage_volume_ids]).to be_empty
              expect(r[:data][:planned_actions].map { |a| a[:step] })
                .not_to include("provision_storage", "attach_volume")
            end
          end

          # `true` rather than `{}` on purpose: `{}.blank?` was ALREADY true, so
          # an empty-Hash example would pass identically before and after the
          # fix and prove nothing about it. `true.blank?` is FALSE, so this
          # shape used to reach `.to_i`, raise NoMethodError, and fail the
          # WHOLE step through `failure(...)` — which returns no `:data`, so
          # the instances the loop had already provisioned were reported to
          # nobody. Asserting the outputs survive is the point of the example;
          # it also pins the `respond_to?` screen against a later
          # simplification that would trade the skip back for a raise.
          it "skips, rather than crashing the step, on a shape with no numeric reading" do
            r = exec.execute(template_id: template.id, count: 2,
                             provider_region_id: region.id,
                             provider_instance_type_id: instance_type.id,
                             with_storage_gb: true)

            expect(r[:success]).to be true
            expect(::System::VolumeManagementService).not_to have_received(:provision)
            # The orphan hazard: these ids are what rollback and teardown read.
            expect(r[:data][:outputs][:node_instance_ids].size).to eq(2)
          end

          # Positive control for the four negatives above: same stubs, same
          # call shape, only the value differs. Without it a broken harness
          # (a mis-stubbed provisioner, a raise swallowed into `failures`)
          # would read as a pass.
          it "still provisions for a positive value" do
            r = exec.execute(template_id: template.id, count: 2,
                             provider_region_id: region.id,
                             provider_instance_type_id: instance_type.id,
                             with_storage_gb: 100)

            expect(::System::VolumeManagementService).to have_received(:provision).twice
            expect(r[:data][:outputs][:storage_volume_ids].size).to eq(2)
          end

          # The dry run is the operator's approval card. It has to agree with
          # what execute does, or the card promises a volume the run will not
          # create (build_plan carried the same defect via `present?`).
          it "plans no storage steps for 0 in dry_run" do
            r = exec.execute(template_id: template.id, count: 3,
                             provider_region_id: region.id,
                             provider_instance_type_id: instance_type.id,
                             with_storage_gb: 0, dry_run: true)

            steps = r[:data][:planned_actions].map { |a| a[:step] }
            expect(steps).not_to include("provision_storage", "attach_volume")
            # 3 × (create_node + provision_instance) and nothing else.
            expect(r[:data][:planned_actions].size).to eq(6)
          end
        end
      end

      # IMP-94f778f92dba — network_id used to only compile a read-only view
      # of the network's ALREADY-EXISTING peers and return THOSE ids as
      # sdwan_peer_ids. Nothing put the instances this step provisioned onto
      # the fabric, and every "scale-out produced a peer" oracle passed
      # vacuously off the fleet that was already there. Real records
      # throughout: an enrollment cannot be proven against a double.
      context "with network_id" do
        let(:network) do
          ::Sdwan::Network.create!(account_id: account.id, name: "pfs-net-#{SecureRandom.hex(3)}")
        end

        # The pre-existing fleet the old implementation reported as its own
        # output. Its peer id must never appear in sdwan_peer_ids.
        let(:incumbent_instance) { sdwan_test_node_instance(node: sdwan_test_node(account: account)) }
        let!(:incumbent_peer) do
          ::Sdwan::PeerEnroller.call(network: network, node_instance: incumbent_instance)
        end

        # PeerEnroller needs a persisted host, so this context hands the
        # provisioning stub real NodeInstance rows rather than instance_stub.
        let(:provisioned_node) { sdwan_test_node(account: account) }
        let(:provisioned_instances) do
          [ sdwan_test_node_instance(node: provisioned_node),
            sdwan_test_node_instance(node: provisioned_node) ]
        end

        before do
          queue = provisioned_instances.dup
          allow(::System::ProvisioningService).to receive(:provision_instance) do
            ::System::Runtime::Result.ok(data: { instance: queue.shift,
                                                 cloud_instance_id: "ci-#{SecureRandom.hex(2)}" })
          end
        end

        def provision_two
          exec.execute(template_id: template.id, count: 2,
                       provider_region_id: region.id,
                       provider_instance_type_id: instance_type.id,
                       network_id: network.id)
        end

        it "enrolls every instance it provisioned as a peer on the network" do
          r = provision_two

          expect(r[:success]).to be true
          enrolled = ::Sdwan::Peer.where(node_instance_id: provisioned_instances.map(&:id))
          expect(enrolled.count).to eq(2)
          expect(r[:data][:outputs][:sdwan_peer_ids]).to match_array(enrolled.pluck(:id))
          expect(r[:data][:failures]).to be_empty
        end

        it "reports only the peers it created — never the network's pre-existing ones" do
          r = provision_two

          expect(r[:data][:outputs][:sdwan_peer_ids]).not_to include(incumbent_peer.id)
          expect(r[:data][:planned_actions].select { |a| a[:step] == "attach_sdwan_peer" }.size).to eq(2)
        end

        it "records an enrollment failure and keeps the provisioned instances instead of raising" do
          allow(::Sdwan::PeerEnroller).to receive(:call).and_raise(StandardError, "vrf table exhausted")

          r = provision_two

          expect(r[:success]).to be true
          expect(r[:data][:outputs][:node_instance_ids].size).to eq(2)
          expect(r[:data][:outputs][:sdwan_peer_ids]).to be_empty
          expect(r[:data][:failures].map { |f| f[:step] }).to eq([ "attach_sdwan_peer", "attach_sdwan_peer" ])
          expect(r[:data][:partial]).to be true
        end
      end
    end

    context "when provisioning partially fails" do
      let(:ok_result)  { ::System::Runtime::Result.ok(data: { instance: instance_stub, cloud_instance_id: "ci-1" }) }
      let(:bad_result) { ::System::Runtime::Result.err(error: "region unavailable") }

      before do
        call_count = 0
        allow(::System::ProvisioningService).to receive(:provision_instance) do
          call_count += 1
          call_count.odd? ? ok_result : bad_result
        end
      end

      it "marks the run as partial and surfaces the failure" do
        r = exec.execute(template_id: template.id, count: 2,
                         provider_region_id: region.id,
                         provider_instance_type_id: instance_type.id)

        expect(r[:success]).to be true
        expect(r[:data][:partial]).to be true
        expect(r[:data][:outputs][:node_instance_ids].size).to eq(1)
        expect(r[:data][:failures].size).to eq(1)
        expect(r[:data][:failures].first[:step]).to eq("provision_instance")
        expect(r[:data][:failures].first[:error]).to match(/region unavailable/)
      end
    end
  end

  describe "#rollback_provision_full_stack" do
    let(:instance_id_a) { SecureRandom.uuid }
    let(:instance_id_b) { SecureRandom.uuid }
    let(:volume_id)     { SecureRandom.uuid }

    it "terminates instances and deletes volumes in reverse order, returning success when all clear" do
      instance_a = instance_double("System::NodeInstance", id: instance_id_a)
      instance_b = instance_double("System::NodeInstance", id: instance_id_b)
      volume     = instance_double("System::ProviderVolume", id: volume_id, attached?: false)

      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_a).and_return(instance_a)
      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_b).and_return(instance_b)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(volume)

      ok = ::System::Runtime::Result.ok
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(ok)
      allow(::System::VolumeManagementService).to receive(:delete).and_return(ok)

      result = exec.rollback_provision_full_stack(
        node_instance_ids: [ instance_id_a, instance_id_b ],
        storage_volume_ids: [ volume_id ]
      )

      expect(result[:success]).to be true
      expect(result[:errors]).to be_empty
      expect(::System::ProvisioningService).to have_received(:terminate_instance).twice
      expect(::System::VolumeManagementService).to have_received(:delete).once
    end

    it "collects errors when termination fails but does not raise" do
      instance_a = instance_double("System::NodeInstance", id: instance_id_a)
      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_a).and_return(instance_a)
      allow(::System::NodeInstance).to receive(:find_by).with(id: instance_id_b).and_return(nil)
      allow(::System::ProviderVolume).to receive(:find_by).with(id: volume_id).and_return(nil)

      bad = ::System::Runtime::Result.err(error: "provider rejected terminate")
      allow(::System::ProvisioningService).to receive(:terminate_instance).and_return(bad)

      result = exec.rollback_provision_full_stack(
        node_instance_ids: [ instance_id_a, instance_id_b ],
        storage_volume_ids: [ volume_id ]
      )

      expect(result[:success]).to be false
      expect(result[:errors].first).to include(resource: "node_instance", id: instance_id_a)
      expect(result[:errors].first[:error]).to match(/provider rejected/)
    end

    it "ignores extra kwargs that the runner may forward (node_ids, etc.) and unknown peer ids" do
      result = exec.rollback_provision_full_stack(
        node_instance_ids: [],
        storage_volume_ids: [],
        sdwan_peer_ids: [ SecureRandom.uuid ],
        node_ids: [ SecureRandom.uuid ]
      )

      expect(result[:success]).to be true
      expect(result[:errors]).to be_empty
    end

    # IMP-94f778f92dba — the executor enrols peers now, so rollback owns them.
    # Leaning on terminate_instance's auto-detach is not enough: it lives in
    # finalize_termination!, and five of terminate_instance's exits never reach
    # it — a missing cloud_instance_id, an unknown provider, the ProviderError
    # rescue, and (exercised here) a provider-side terminate failure all return
    # Result.err, while `rescue ArgumentError` re-raises. Those are precisely
    # the rollbacks that matter, and they would leave the peer live on the
    # fabric.
    it "detaches enrolled peers even when the provider rejects the terminate" do
      inst = sdwan_test_node_instance(node: sdwan_test_node(account: account))
      network = ::Sdwan::Network.create!(account_id: account.id, name: "pfs-rb-#{SecureRandom.hex(3)}")
      peer = ::Sdwan::PeerEnroller.call(network: network, node_instance: inst)

      allow(::System::ProvisioningService).to receive(:terminate_instance)
        .and_return(::System::Runtime::Result.err(error: "provider rejected terminate"))

      result = exec.rollback_provision_full_stack(
        node_instance_ids: [ inst.id ],
        storage_volume_ids: [],
        sdwan_peer_ids: [ peer.id ]
      )

      expect(::Sdwan::Peer.where(id: peer.id)).to be_empty
      expect(result[:success]).to be false
      expect(result[:errors].map { |e| e[:resource] }).to eq([ "node_instance" ])
    end

    # IMP-093378034fb4 — the executor attaches what it provisions now, so
    # rollback owns the detach too. VolumeManagementService#delete REFUSES an
    # attached volume ("Volume is attached, detach first"), and once the
    # instance is terminated there is nothing left to detach from — so the
    # volume pass has to be detach-then-delete AND has to run BEFORE the
    # instances. Same order, for the same reason, as
    # ScaleProjectExecutor#teardown_resources. Without both, adding the attach
    # would simply move the leak from scale-in to rollback.
    it "detaches an attached volume and deletes it BEFORE terminating its instance" do
      inst = create(:system_node_instance, :running,
                    node: create(:system_node, account: account, node_template: template),
                    provider_region: region, provider_instance_type: instance_type)
      volume = create(:system_provider_volume, :attached, account: account,
                      provider_region: region, node_instance: inst)

      adapter = instance_double(::System::Providers::MockProvider,
                                detach_volume: { success: true },
                                delete_volume: { success: true })
      allow(::System::Providers::Registry).to receive(:for_volume).and_return(adapter)

      volume_gone_at_terminate = nil
      allow(::System::ProvisioningService).to receive(:terminate_instance) do
        volume_gone_at_terminate = ::System::ProviderVolume.where(id: volume.id).none?
        ::System::Runtime::Result.ok
      end

      result = exec.rollback_provision_full_stack(
        node_instance_ids: [ inst.id ], storage_volume_ids: [ volume.id ]
      )

      expect(result[:errors]).to be_empty
      expect(::System::ProviderVolume.where(id: volume.id)).to be_empty
      # Ordering IS the assertion: a delete attempted after the terminate
      # would have had nothing left to detach from.
      expect(volume_gone_at_terminate).to be(true)
    end
  end
end
