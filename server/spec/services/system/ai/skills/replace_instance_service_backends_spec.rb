# frozen_string_literal: true

require "rails_helper"

# APO-3d (IMP-0c10b9fd5596) — a DR replace must re-home the published service.
#
# ReplaceInstanceExecutor moved volumes, peers and VIPs onto the warm spare and
# left every Sdwan::Service that dialled the dead instance BY ADDRESS pointing
# at it. The replace now adds the replacement to each such service's backend
# set and DRAINS the dead member (its row survives until the reap, which is
# what a rolling replacement needs between "stop sending it work" and "it is
# gone"); the reap removes the drained rows before the terminate destroys the
# peers those rows were resolved from.
RSpec.describe "DR replace / reap service backend maintenance (APO-3d)", type: :service do
  let(:account)                { create(:account) }
  let(:node_template)          { create(:system_node_template, account: account) }
  let(:provider_region)        { create(:system_provider_region) }
  let(:provider_instance_type) { create(:system_provider_instance_type) }

  let(:pool) do
    System::InstancePool.create!(
      account: account, node_template: node_template, name: "dr-pool",
      target_size: 2, min_size: 1, max_size: 4, lifecycle_class: "ephemeral",
      status: "active", provider_region: provider_region,
      provider_instance_type: provider_instance_type
    )
  end

  def pool_member(pool_state:, status:, private_ip:)
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance,
           node: node, name: "m-#{SecureRandom.hex(3)}", variety: "cloud",
           status: status, provider_region: provider_region,
           provider_instance_type: provider_instance_type,
           private_ip_address: private_ip,
           instance_pool_id: pool.id, pool_state: pool_state,
           pool_warming_started_at: 5.minutes.ago)
  end

  let!(:failed) { pool_member(pool_state: "claimed", status: "error",   private_ip: "10.0.1.5") }
  let!(:spare)  { pool_member(pool_state: "ready",   status: "running", private_ip: "10.0.1.6") }

  let(:network) { create(:sdwan_network, account: account) }
  let!(:old_peer) do
    create(:sdwan_peer, :active, account: account, network: network, node_instance: failed,
                                 assigned_address: "fd00:abcd:1::5")
  end

  # The published service dials the dead instance over the OVERLAY — the
  # address form ProvisionFullStackExecutor's peers give a replica.
  let!(:service) do
    create(:sdwan_service, :local_exposed, account: account,
                           backend_host: "fd00:abcd:1::5", backend_port: 3000)
  end

  let(:provider) { instance_double(System::Providers::MockProvider, provider_type: "mock") }

  before do
    allow(System::Providers::Registry).to receive(:for_volume).and_return(provider)
    allow(System::Providers::Registry).to receive(:for_instance).and_return(provider)
    allow(provider).to receive(:terminate_instance).and_return({ success: true })
    allow(::Sdwan::ServiceExposureWriter).to receive(:write!)
      .and_return(output_path: "/tmp/x.yaml", route_count: 1, skipped_service_ids: [])
  end

  def replace!(operation_id: "op-lb", **extra)
    System::Ai::Skills::ReplaceInstanceExecutor.new(account: account, agent: nil, user: nil)
      .execute(gated: true, instance_id: failed.id, operation_id: operation_id, **extra)
  end

  def reap!(operation_id: "op-lb")
    System::Ai::Skills::ReapInstanceExecutor.new(account: account, agent: nil, user: nil)
      .execute(gated: true, instance_id: failed.id, operation_id: operation_id)
  end

  def members
    service.reload.backends.order(:created_at).map { |b| [ b.backend_host, b.status ] }
  end

  describe "the replace" do
    it "adds the replacement (over the same overlay network) and drains the dead member" do
      result = replace!

      expect(result[:success]).to be(true), "executor failed: #{result[:error]}"
      new_peer = Sdwan::Peer.find_by(sdwan_network_id: network.id, node_instance_id: spare.id)
      expect(new_peer).to be_present
      # The allocator stores the peer address WITH its /128; a backend dials
      # the bare host.
      new_address = new_peer.assigned_address.split("/").first

      expect(members).to eq([ [ "fd00:abcd:1::5", "draining" ], [ new_address, "active" ] ])
      expect(service.load_balanced_backends.map(&:address)).to eq([ new_address ])
      expect(result.dig(:data, :rehomed_sdwan_service_ids)).to eq([ service.id ])
      expect(::Sdwan::ServiceExposureWriter).to have_received(:write!).with(account: account)
    end

    it "records the step on the ledger and replays it on a re-drive instead of re-adding" do
      replace!(operation_id: "op-replay")
      second = replace!(operation_id: "op-replay")

      expect(second.dig(:data, :replayed_steps)).to include("rehome_service_backends")
      expect(service.reload.backends.count).to eq(2)
    end

    it "previews the services a dry run would re-home" do
      plan = replace!(dry_run: true)

      expect(plan.dig(:data, :would_rehome_service_ids)).to eq([ service.id ])
      expect(::Sdwan::ServiceBackend.count).to eq(0)
    end

    it "leaves a VIP-backed service to the VIP move" do
      vip = create(:sdwan_virtual_ip, network: network, account: account,
                                      holder_peer_ids: [ old_peer.id ], state: "active")
      vip_service = create(:sdwan_service, account: account, slug: "vip-backed",
                                           backend_host: nil, backend_vip: vip, backend_port: 3000)

      replace!

      expect(vip_service.reload.backends.count).to eq(0)
      new_peer = Sdwan::Peer.find_by(sdwan_network_id: network.id, node_instance_id: spare.id)
      expect(vip.reload.holder_peer_ids).to eq([ new_peer.id ])
    end
  end

  describe "the reap" do
    it "removes the dead instance's rows BEFORE the terminate destroys the peers they resolve from" do
      replace!
      expect(members.map(&:last)).to include("draining")

      result = reap!

      expect(result[:success]).to be(true), "reap failed: #{result[:error]}"
      expect(provider).to have_received(:terminate_instance).once
      expect(members.map(&:last)).to eq([ "active" ])
      expect(members.map(&:first)).not_to include("fd00:abcd:1::5")
      expect(result.dig(:data, :removed_sdwan_service_backend_ids).size).to eq(1)
    end
  end
end
