# frozen_string_literal: true

require "rails_helper"
require "openssl"

# Phase B — runtime daemon handshake endpoint.
#
# Exercises the three phases (wants_cert / ready / stopped) over the
# `docker` runtime against an instance with the `docker-engine` module
# assigned + an SDWAN peer attached. Authorization is faked at the
# controller level (we override authenticate_instance! to set
# current_instance directly) — the auth chain itself is covered by
# `BaseController` specs and isn't the focus here.
RSpec.describe Api::V1::System::NodeApi::RuntimeController, type: :request do
  before { ::System::InternalCaService.reset! }
  after  { ::System::InternalCaService.reset! }

  let(:account) { create(:account) }
  let(:node) { sdwan_test_node(account: account) }
  let(:node_instance) { sdwan_test_node_instance(node: node) }

  # SDWAN peer with auto-allocated overlay /128 — required for the
  # docker provisioner to compute api_endpoint. Static-routing network
  # avoids the iBGP path which needs additional setup.
  let!(:sdwan_network) do
    ::Sdwan::Network.create!(
      account_id: account.id,
      name: "rt-test-net-#{SecureRandom.hex(3)}",
      routing_protocol: "static"
    )
  end
  let!(:peer) do
    ::Sdwan::Peer.create!(
      account: account,
      sdwan_network_id: sdwan_network.id,
      node_instance: node_instance,
      publicly_reachable: false
    )
  end

  # `docker-engine` module assignment — the controller's
  # module_assigned? guard requires it.
  let!(:container_runtimes_category) do
    ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "Container Runtimes") do |c|
      c.assign_attributes(variety: "subscription", position: 70, enabled: true, public: true,
                          description: "test category")
    end
  end
  let!(:docker_module) do
    ::System::NodeModule.find_or_create_by!(account: account, name: "docker-engine") do |m|
      m.assign_attributes(variety: "subscription", category: container_runtimes_category,
                          enabled: true, public: true, priority: 100,
                          description: "docker runtime test seed")
    end
  end
  let!(:docker_assignment) do
    ::System::NodeModuleAssignment.create!(
      node: node, node_module: docker_module, enabled: true
    )
  end

  let(:agent_keypair) { OpenSSL::PKey.generate_key("ED25519") }
  let(:csr_pem) do
    csr = OpenSSL::X509::Request.new
    csr.version = 0
    csr.subject = OpenSSL::X509::Name.parse("/CN=docker-daemon-#{node_instance.id}")
    csr.public_key = agent_keypair
    csr.sign(agent_keypair, nil)
    csr.to_pem
  end

  before do
    # Swap in a stub auth: any request resolves to our test
    # node_instance. Production behavior (mTLS preferred, JWT fallback)
    # is covered by BaseController specs.
    allow_any_instance_of(Api::V1::System::NodeApi::BaseController)
      .to receive(:authenticate_instance!).and_wrap_original do |_m|
        controller = _m.receiver
        controller.instance_variable_set(:@current_instance, node_instance)
      end
  end

  describe "POST /api/v1/system/node_api/runtime/handshake" do
    let(:url) { "/api/v1/system/node_api/runtime/handshake" }

    context "phase=wants_cert (docker)" do
      it "issues a CA-signed cert + creates the managed DockerHost on first call" do
        expect {
          post url, params: { runtime: "docker", phase: "wants_cert", csr_pem: csr_pem }, as: :json
        }.to change { Devops::DockerHost.managed.count }.by(1)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        cert = body.dig("data", "certificate")

        expect(cert["cert_pem"]).to include("BEGIN CERTIFICATE")
        expect(cert["ca_chain_pem"]).to include("BEGIN CERTIFICATE")
        expect(cert["not_after"]).to be_present

        # Verify the issued cert chains back to the platform's CA.
        leaf = OpenSSL::X509::Certificate.new(cert["cert_pem"])
        ca = OpenSSL::X509::Certificate.new(cert["ca_chain_pem"])
        expect(leaf.verify(ca.public_key)).to be true
      end

      it "is idempotent — second wants_cert reuses the existing DockerHost" do
        post url, params: { runtime: "docker", phase: "wants_cert", csr_pem: csr_pem }, as: :json
        expect {
          post url, params: { runtime: "docker", phase: "wants_cert", csr_pem: csr_pem }, as: :json
        }.not_to change { Devops::DockerHost.managed.count }

        expect(response).to have_http_status(:ok)
      end

      it "rejects a missing CSR" do
        post url, params: { runtime: "docker", phase: "wants_cert" }, as: :json
        expect(response).to have_http_status(:unprocessable_entity).or have_http_status(:bad_request)
        expect(JSON.parse(response.body)["error"]).to include("csr_pem required")
      end

      it "rejects a malformed CSR with 400" do
        post url, params: { runtime: "docker", phase: "wants_cert", csr_pem: "not a CSR" }, as: :json
        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)["error"]).to include("invalid CSR")
      end
    end

    context "phase=ready (docker)" do
      it "promotes the managed DockerHost from pending to connected" do
        # Seed a managed host first via wants_cert so 'ready' has something to flip.
        post url, params: { runtime: "docker", phase: "wants_cert", csr_pem: csr_pem }, as: :json
        host = Devops::DockerHost.managed.find_by(node_instance_id: node_instance.id)
        expect(host.status).to eq("pending")

        post url, params: { runtime: "docker", phase: "ready", version: "25.0.3" }, as: :json
        expect(response).to have_http_status(:ok)

        host.reload
        expect(host.status).to eq("connected")
        expect(host.docker_version).to eq("25.0.3")
      end

      it "fails with 422 when no DockerHost has been provisioned yet" do
        post url, params: { runtime: "docker", phase: "ready" }, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to include("wants_cert must precede ready")
      end
    end

    context "phase=stopped (docker)" do
      it "marks the host disconnected if one exists" do
        post url, params: { runtime: "docker", phase: "wants_cert", csr_pem: csr_pem }, as: :json
        host = Devops::DockerHost.managed.find_by(node_instance_id: node_instance.id)

        post url, params: { runtime: "docker", phase: "stopped" }, as: :json
        expect(response).to have_http_status(:ok)
        expect(host.reload.status).to eq("disconnected")
      end

      it "is a no-op when no host exists" do
        post url, params: { runtime: "docker", phase: "stopped" }, as: :json
        expect(response).to have_http_status(:ok)
      end
    end

    context "authorization guards" do
      it "returns 403 when the docker-engine module is not assigned" do
        docker_assignment.destroy!
        post url, params: { runtime: "docker", phase: "wants_cert", csr_pem: csr_pem }, as: :json
        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to include("not enabled for this node")
      end

      it "returns 422 when the runtime is unknown (no spoofing future runtimes)" do
        post url, params: { runtime: "k8s_helm", phase: "wants_cert", csr_pem: csr_pem }, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to include("unsupported runtime")
      end

      it "returns 422 when phase is invalid" do
        post url, params: { runtime: "docker", phase: "magic" }, as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to include("invalid phase")
      end
    end
  end
end
