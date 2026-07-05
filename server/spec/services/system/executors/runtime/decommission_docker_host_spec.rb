# frozen_string_literal: true

require "rails_helper"

# IMP-967901b9d2e1 — DecommissionDockerHost called ::DockerHost.find, but
# ::DockerHost is not a top-level constant (the model is Devops::DockerHost)
# — every call raised NameError. It also guarded a
# ::System::DockerHostDecommissionService that doesn't exist anywhere,
# so the `defined?` branch was always false and every host (managed or
# external) fell through to a bare #destroy!, skipping the managed host's
# Vault TLS-material purge.
RSpec.describe System::Executors::Runtime::DecommissionDockerHost do
  let(:account) { create(:account) }
  let(:deferred_operation) { double("Ai::DeferredOperation", account: account) }

  describe ".execute" do
    context "with a managed host" do
      let(:node) { sdwan_test_node(account: account) }
      let(:node_instance) { sdwan_test_node_instance(node: node) }
      let!(:network) do
        ::Sdwan::Network.create!(
          account_id: account.id,
          name: "decommission-docker-test-net-#{SecureRandom.hex(3)}",
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
      let!(:host) { ::System::DockerDaemonProvisionerService.provision!(node_instance: node_instance, account: account) }

      it "routes through DockerDaemonProvisionerService#decommission! and destroys the row" do
        result = described_class.execute({ host_id: host.id }, deferred_operation: deferred_operation)

        expect(result[:success]).to be true
        expect(result[:data]).to eq(host_id: host.id, decommissioned: true)
        expect(::Devops::DockerHost.exists?(host.id)).to be false
      end
    end

    context "with an external (operator-registered) host" do
      let!(:host) { create(:devops_docker_host, account: account) }

      it "destroys the row directly without NameError" do
        expect(host.provisioning_state).to eq("external")

        result = described_class.execute({ host_id: host.id }, deferred_operation: deferred_operation)

        expect(result[:success]).to be true
        expect(::Devops::DockerHost.exists?(host.id)).to be false
      end
    end
  end
end
