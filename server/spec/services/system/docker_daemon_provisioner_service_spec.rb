# frozen_string_literal: true

require "rails_helper"

# Phase B — Docker daemon auto-registration service.
#
# Covers provision (idempotent + happy path + missing-SDWAN failure),
# mark_daemon_ready (status promotion), and decommission (managed-only).
# InternalCaService runs through its LocalCaAdapter (test default per
# the service's own env-default), so cert issuance is real but in-memory.
RSpec.describe System::DockerDaemonProvisionerService do
  before { ::System::InternalCaService.reset! }
  after  { ::System::InternalCaService.reset! }

  let(:account) { create(:account) }
  let(:node) { sdwan_test_node(account: account) }
  let(:node_instance) { sdwan_test_node_instance(node: node) }
  let!(:network) do
    ::Sdwan::Network.create!(
      account_id: account.id,
      name: "docker-test-net-#{SecureRandom.hex(3)}",
      routing_protocol: "static"
    )
  end
  let(:peer) do
    ::Sdwan::Peer.create!(
      account: account,
      sdwan_network_id: network.id,
      node_instance: node_instance,
      publicly_reachable: false
    )
  end

  describe ".provision!" do
    context "with a NodeInstance backed by an SDWAN peer" do
      before { peer } # force creation — peer.assigned_address is auto-allocated

      it "creates a managed Devops::DockerHost in pending status" do
        host = described_class.provision!(node_instance: node_instance, account: account)

        expect(host).to be_persisted
        expect(host.provisioning_state).to eq("managed")
        expect(host.status).to eq("pending")
        expect(host.node_instance_id).to eq(node_instance.id)
        expect(host.account_id).to eq(account.id)
      end

      it "binds the api_endpoint to the peer's overlay /128 on port 2376" do
        host = described_class.provision!(node_instance: node_instance, account: account)
        # assigned_address is "<v6>/128" — peer model strips the prefix
        # for raw address; we want the bracketed form in the endpoint.
        raw_v6 = peer.assigned_address.to_s.split("/").first
        expect(host.api_endpoint).to eq("tcp://[#{raw_v6}]:2376")
      end

      it "stores client TLS material in encrypted_tls_credentials" do
        host = described_class.provision!(node_instance: node_instance, account: account)
        creds = JSON.parse(host.encrypted_tls_credentials)

        expect(creds["ca_chain_pem"]).to include("BEGIN CERTIFICATE")
        expect(creds["client_cert_pem"]).to include("BEGIN CERTIFICATE")
        expect(creds["client_key_pem"]).to include("BEGIN PRIVATE KEY").or include("BEGIN ED25519 PRIVATE KEY")
        expect(creds["client_cert_serial"]).to be_present
      end

      it "is idempotent — second call returns the same row" do
        first = described_class.provision!(node_instance: node_instance, account: account)
        second = described_class.provision!(node_instance: node_instance, account: account)

        expect(second.id).to eq(first.id)
        expect(Devops::DockerHost.managed.where(node_instance_id: node_instance.id).count).to eq(1)
      end
    end

    context "without an SDWAN peer on the NodeInstance" do
      it "raises MissingSdwanPeerError" do
        expect {
          described_class.provision!(node_instance: node_instance, account: account)
        }.to raise_error(described_class::MissingSdwanPeerError, /no SDWAN peer/)
      end
    end
  end

  describe "#mark_daemon_ready!" do
    let(:host) do
      peer
      described_class.provision!(node_instance: node_instance, account: account)
    end

    it "promotes the host from pending to connected" do
      expect(host.status).to eq("pending")
      described_class.new(docker_host: host, account: account)
                     .mark_daemon_ready!(host: host, docker_version: "25.0.3")
      host.reload
      expect(host.status).to eq("connected")
      expect(host.docker_version).to eq("25.0.3")
      expect(host.last_synced_at).to be_within(2.seconds).of(Time.current)
    end

    it "stamps daemon_ready_at into metadata" do
      described_class.new(docker_host: host, account: account)
                     .mark_daemon_ready!(host: host)
      expect(host.reload.metadata["daemon_ready_at"]).to be_present
    end
  end

  describe ".decommission!" do
    it "destroys a managed host" do
      peer
      host = described_class.provision!(node_instance: node_instance, account: account)
      host_id = host.id

      described_class.decommission!(docker_host: host)
      expect(Devops::DockerHost.where(id: host_id)).to be_empty
    end

    it "refuses to decommission an external host" do
      external = create(:devops_docker_host, account: account, provisioning_state: "external")
      expect {
        described_class.decommission!(docker_host: external)
      }.to raise_error(described_class::ProvisionError, /external/)
    end
  end
end
