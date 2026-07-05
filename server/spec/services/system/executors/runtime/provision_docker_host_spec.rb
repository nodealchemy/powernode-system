# frozen_string_literal: true

require "rails_helper"

# IMP-967901b9d2e1 — ProvisionDockerHost called
# DockerDaemonProvisionerService.new(account:, instance_id:, options:), but
# the service takes node_instance:/docker_host:/account: — every call raised
# ArgumentError (unknown keyword) before ever reaching #provision!.
RSpec.describe System::Executors::Runtime::ProvisionDockerHost do
  before { ::System::InternalCaService.reset! }
  after  { ::System::InternalCaService.reset! }

  let(:account) { create(:account) }
  let(:node) { sdwan_test_node(account: account) }
  let(:node_instance) { sdwan_test_node_instance(node: node) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }
  let!(:network) do
    ::Sdwan::Network.create!(
      account_id: account.id,
      name: "provision-docker-test-net-#{SecureRandom.hex(3)}",
      routing_protocol: "static"
    )
  end
  let!(:peer) do
    ::Sdwan::Peer.create!(
      account: account,
      sdwan_network_id: network.id,
      node_instance: node_instance,
      publicly_reachable: false
    )
  end

  describe ".execute" do
    it "provisions a managed Devops::DockerHost via node_instance:, not instance_id:" do
      result = described_class.execute(
        { instance_id: node_instance.id },
        deferred_operation: deferred_operation
      )

      expect(result[:success]).to be true
      host = ::Devops::DockerHost.find(result[:data][:host_id])
      expect(host.provisioning_state).to eq("managed")
      expect(host.node_instance_id).to eq(node_instance.id)
      expect(result[:data]).to eq(
        instance_id: node_instance.id,
        host_id: host.id,
        status: host.status
      )
    end

    it "is idempotent — re-running returns the existing host" do
      first = described_class.execute({ instance_id: node_instance.id }, deferred_operation: deferred_operation)
      second = described_class.execute({ instance_id: node_instance.id }, deferred_operation: deferred_operation)

      expect(second[:data][:host_id]).to eq(first[:data][:host_id])
      expect(::Devops::DockerHost.managed.where(node_instance_id: node_instance.id).count).to eq(1)
    end
  end
end
