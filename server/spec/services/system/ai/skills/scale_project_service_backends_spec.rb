# frozen_string_literal: true

require "rails_helper"

# APO-3d (IMP-0c10b9fd5596) — a scaled project's replicas must RECEIVE TRAFFIC.
#
# APO-3c gave Sdwan::ServiceExposureWriter a backend set to fan out across, and
# nothing produced one: `add_replicas` minted instances that no published
# service dialled, and `remove_replicas` terminated instances whose member rows
# (had anyone added them by console) would have kept Traefik dialling a dead
# host. The executor now maintains the set on both arms and regenerates the
# proxy, so the fleet the operator approved is the fleet that serves.
RSpec.describe System::Ai::Skills::ScaleProjectExecutor, "service backend maintenance (APO-3d)" do
  let(:account)       { create(:account) }
  let(:prefix)        { "dryrun-lb-01" }
  let(:mission) do
    create(:ai_mission, account: account, mission_type: "infrastructure",
                        configuration: { "name_prefix" => prefix })
  end
  let(:platform)      { create(:system_node_platform, account: account) }
  let(:template)      { create(:system_node_template, account: account, node_platform: platform) }
  let(:provider)      { create(:system_provider, account: account) }
  let(:region)        { create(:system_provider_region, account: account, provider: provider) }
  let(:instance_type) { create(:system_provider_instance_type, account: account, provider: provider) }
  let(:exec)          { described_class.new(account: account) }

  let(:provider_adapter) do
    instance_double(::System::Providers::MockProvider,
                    terminate_instance: { success: true },
                    detach_volume: { success: true }, delete_volume: { success: true })
  end

  before do
    allow(::System::Providers::Registry).to receive(:for_instance).and_return(provider_adapter)
    allow(::System::Providers::Registry).to receive(:for_volume).and_return(provider_adapter)
    allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
      .and_return(output_path: "/tmp/x.yaml", route_count: 1, skipped_service_ids: [])
  end

  # The shape ProvisionFullStackExecutor#create_node! stamps (mission provenance
  # + prefixed name), so #mission_replicas resolves these as the mission's own.
  def replica!(private_ip:, minutes_old: 10)
    node = create(:system_node, account: account, node_template: template,
                                name: "#{prefix}-web-#{SecureRandom.hex(3)}",
                                config: { "mission_id" => mission.id })
    create(:system_node_instance, :running, node: node, private_ip_address: private_ip,
           provider_region: region, provider_instance_type: instance_type,
           name: "#{node.name}-instance", created_at: minutes_old.minutes.ago)
  end

  let!(:seed) { replica!(private_ip: "10.0.1.5", minutes_old: 30) }
  let!(:service) do
    create(:sdwan_service, :local_exposed, account: account,
                           backend_host: "10.0.1.5", backend_port: 3000)
  end

  describe "add_replicas" do
    let(:next_ip) { [ 6 ] }

    before do
      # Real rows, not doubles: the executor has to read the new replica's
      # address off the instance the provisioning service handed back.
      allow(::System::ProvisioningService).to receive(:provision_instance) do |node:, **|
        ip = "10.0.1.#{next_ip[0]}"
        next_ip[0] += 1
        instance = create(:system_node_instance, :running, node: node, private_ip_address: ip,
                          provider_region: region, provider_instance_type: instance_type,
                          name: "#{node.name}-instance")
        ::System::Runtime::Result.ok(data: { instance: instance, cloud_instance_id: "ci-#{ip}" })
      end
    end

    def scale_out!(count, **extra)
      exec.execute(project_id: mission.id, target_count: count, scaling_strategy: "add_replicas",
                   template_id: template.id, provider_region_id: region.id,
                   provider_instance_type_id: instance_type.id, **extra)
    end

    it "joins every new replica to the service the mission's replicas already back, " \
       "keeping the original backend in the set" do
      r = scale_out!(2)

      expect(r[:success]).to be(true), "executor failed: #{r[:error]}"
      expect(service.reload.load_balanced_backends.map(&:address)).to eq(%w[10.0.1.5 10.0.1.6 10.0.1.7])
      expect(service.backends.map(&:status).uniq).to eq([ "active" ])
    end

    it "reports the joined service and the rows it minted, and regenerates the proxy once" do
      r = scale_out!(1)

      outs = r[:data][:outputs]
      expect(outs[:sdwan_service_ids]).to eq([ service.id ])
      expect(outs[:sdwan_service_backend_ids]).to match_array(service.backends.pluck(:id))
      expect(r[:data][:planned_actions]).to include(
        a_hash_including(step: "join_service_backends", service_id: service.id)
      )
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account).once
    end

    it "names the services a dry run WOULD join, without writing a row" do
      expect(::System::ProvisioningService).not_to receive(:provision_instance)

      r = scale_out!(2, dry_run: true)

      expect(r[:data][:planned_actions]).to include(
        a_hash_including(step: "join_service_backends", service_id: service.id)
      )
      expect(::Sdwan::ServiceBackend.count).to eq(0)
      expect(::Sdwan::ServiceExposureWriter).not_to have_received(:write!)
    end

    it "does nothing to the backend set when no service routes to the mission" do
      service.update!(backend_host: "10.0.9.9")

      r = scale_out!(1)

      expect(r[:success]).to be(true)
      expect(::Sdwan::ServiceBackend.count).to eq(0)
      expect(r[:data][:outputs][:sdwan_service_ids]).to eq([])
      expect(::Sdwan::ServiceExposureWriter).not_to have_received(:write!)
    end

    # The scale arm and the replace arm must agree about what a VIP-fronted
    # service is. ReplaceInstanceExecutor#rehome_service_backends! refuses to
    # add a host-form row beside a VIP row because that counts one machine
    # twice — and hands it the WHOLE round robin the moment the VIP fails over
    # onto it. Scale-out applies the same rule.
    it "leaves a service reached only through a backend VIP alone" do
      service.update!(backend_host: "10.0.9.9") # no longer routes to the mission by address
      network = create(:sdwan_network, account: account)
      peer = create(:sdwan_peer, account: account, network: network, node_instance: seed)
      vip  = create(:sdwan_virtual_ip, network: network, account: account,
                                       holder_peer_ids: [ peer.id ])
      vip_service = create(:sdwan_service, :local_exposed, account: account,
                           backend_host: nil, backend_vip: vip, backend_port: 3000)

      r = scale_out!(1)

      expect(r[:success]).to be(true), "executor failed: #{r[:error]}"
      expect(vip_service.reload.backends).to be_empty
      expect(r[:data][:outputs][:sdwan_service_ids]).to eq([])
      expect(::Sdwan::ServiceExposureWriter).not_to have_received(:write!)
    end

    it "records a failed join as a step failure rather than a silent one" do
      allow(::Sdwan::ServiceBackend).to receive(:add_instance!)
        .and_raise(::Sdwan::ServiceBackend::NoAddressError, "no address")

      r = scale_out!(1)

      expect(r[:success]).to be(true)
      expect(r[:data][:partial]).to be(true)
      expect(r[:data][:failures]).to include(a_hash_including(step: "join_service_backends"))
    end

    it "leaves the rollback able to take a replica back OUT of the set" do
      r = scale_out!(1)
      new_id = r[:data][:outputs][:node_instance_ids].first

      rb = exec.rollback_scale_project(node_instance_ids: [ new_id ], storage_volume_ids: [])

      expect(rb[:success]).to be(true)
      expect(service.reload.load_balanced_backends.map(&:address)).to eq([ "10.0.1.5" ])
    end
  end

  # REVIEW FINDING 7 (IMP-0c10b9fd5596). add_replicas and add_region compose
  # the SAME provision arm (#run_provision), so the join is not an add_replicas
  # behaviour — it is a run_provision one. Pinned here because the class header
  # and the runbook name only add_replicas, and a cross-region replica is
  # exactly the case where joining the wrong fabric hurts.
  describe "add_region" do
    let(:next_ip) { [ 6 ] }

    before do
      allow(::System::ProvisioningService).to receive(:provision_instance) do |node:, **|
        ip = "10.0.1.#{next_ip[0]}"
        next_ip[0] += 1
        instance = create(:system_node_instance, :running, node: node, private_ip_address: ip,
                          provider_region: region, provider_instance_type: instance_type,
                          name: "#{node.name}-instance")
        ::System::Runtime::Result.ok(data: { instance: instance, cloud_instance_id: "ci-#{ip}" })
      end
    end

    it "joins the new replica to the mission's service, same as add_replicas" do
      r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "add_region",
                       template_id: template.id, provider_region_id: region.id,
                       provider_instance_type_id: instance_type.id)

      expect(r[:success]).to be(true), "executor failed: #{r[:error]}"
      expect(r[:data][:outputs][:sdwan_service_ids]).to eq([ service.id ])
      expect(service.reload.load_balanced_backends.map(&:address)).to eq(%w[10.0.1.5 10.0.1.6])
    end
  end

  describe "remove_replicas" do
    let!(:newest) { replica!(private_ip: "10.0.1.6", minutes_old: 5) }

    before do
      ::Sdwan::ServiceBackend.add_instance!(service: service, instance: seed)
      ::Sdwan::ServiceBackend.add_instance!(service: service, instance: newest)
    end

    it "removes the victim's member row BEFORE the instance (and its addresses) are gone, " \
       "and regenerates the proxy" do
      r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas")

      expect(r[:success]).to be(true), "executor failed: #{r[:error]}"
      expect(::System::NodeInstance.find(newest.id).status).to eq("terminated")
      expect(service.reload.load_balanced_backends.map(&:address)).to eq([ "10.0.1.5" ])
      expect(r[:data][:outputs][:removed_sdwan_service_backend_ids].size).to eq(1)
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    # Traefik reloads on every write to the dynamic dir, so a regen belongs to
    # the RUN, not to each victim: the teardown leaves it to its caller.
    it "regenerates the proxy ONCE for the whole scale-in, not once per victim" do
      third = replica!(private_ip: "10.0.1.7", minutes_old: 1)
      ::Sdwan::ServiceBackend.add_instance!(service: service, instance: third)

      r = exec.execute(project_id: mission.id, target_count: 2, scaling_strategy: "remove_replicas")

      expect(r[:success]).to be(true), "executor failed: #{r[:error]}"
      expect(r[:data][:outputs][:removed_sdwan_service_backend_ids].size).to eq(2)
      expect(service.reload.load_balanced_backends.map(&:address)).to eq([ "10.0.1.5" ])
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account).once
    end

    it "names the rows a dry run WOULD remove, and removes none" do
      r = exec.execute(project_id: mission.id, target_count: 1, scaling_strategy: "remove_replicas",
                       dry_run: true)

      expect(r[:data][:planned_actions]).to include(
        a_hash_including(step: "leave_service_backends", service_id: service.id,
                         node_instance_id: newest.id)
      )
      expect(service.reload.backends.count).to eq(2)
    end
  end
end
