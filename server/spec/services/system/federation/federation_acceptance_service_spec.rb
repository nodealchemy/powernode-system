# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Federation::FederationAcceptanceService, type: :service do
  let(:account) { create(:account) }

  let(:peer) do
    create(:system_federation_peer, :platform,
           account: account,
           status: "proposed",
           remote_instance_url: "https://child.example.com")
  end

  # Generate a real single-use token on the peer; the service verifies the
  # round-trip via FederationPeer#accept!.
  let(:plaintext_token) { peer.generate_acceptance_token!(ttl_seconds: 1.hour.to_i) }

  # The child generates its federation keypair + CSR locally and sends only
  # the CSR in the accept request (key-safe); the parent signs it with our CA.
  let(:prepared) { Federation::OutboundIdentityService.prepare_csr }

  let(:base_args) do
    {
      token: plaintext_token,
      contract_version: 1,
      capabilities: { "skill" => { "read" => true } },
      extension_slugs: [ "trading" ],
      endpoints: [ { "url" => "https://child.example.com:443", "scope" => "wan", "priority" => 1 } ],
      csr_pem: prepared.csr_pem,
      platform_url: "https://parent.example.com"
    }
  end

  # The accept→enrolled transition fires FederationPeer's after_commit
  # post-accept enqueue. Stub the worker dispatch so the service specs
  # don't reach Redis (the async topology reconciliation is covered by the
  # model spec + worker-side spec).
  before do
    allow(::System::WorkerDispatch).to receive(:enqueue).and_return("jid-stub")
  end

  describe ".call — happy path (platform peer)" do
    before { plaintext_token }

    it "accepts + enrolls and returns an ok Result with the peer payload" do
      result = described_class.call(**base_args)

      expect(result.ok?).to be true
      expect(result.peer).to eq(peer)
      expect(result.payload[:peer_id]).to eq(peer.id)
      expect(result.payload[:status]).to eq("enrolled")
      expect(result.payload[:peer_kind]).to eq("platform")
      expect(result.payload[:contract_version_agreed]).to eq(1)
      expect(result.payload[:accepted_at]).to be_present
      expect(result.payload[:handshake_at]).to be_present
    end

    it "signs the child's CSR with our CA and returns the cert (no private key)" do
      result = described_class.call(**base_args)

      fed = result.payload[:federation_certificate]
      expect(fed).to be_present
      expect(fed[:cert_pem]).to include("BEGIN CERTIFICATE")
      expect(fed[:ca_chain_pem]).to include("BEGIN CERTIFICATE")
      # The child's key never leaves the child — the response carries no key.
      expect(fed).not_to have_key(:private_key_pem)

      # The CN is the identity WE assign, so the child can't claim another peer.
      leaf = OpenSSL::X509::Certificate.new(fed[:cert_pem])
      expect(leaf.subject.to_s).to include("fed:#{peer.id}")
    end

    it "stamps inbound_subject so future inbound mTLS calls resolve to this peer" do
      described_class.call(**base_args)
      expect(peer.reload.inbound_subject).to eq("fed:#{peer.id}")
    end

    it "persists capabilities, extension_slugs, endpoints on the peer" do
      described_class.call(**base_args)

      peer.reload
      expect(peer.capabilities).to eq("skill" => { "read" => true })
      expect(peer.extension_slugs).to eq([ "trading" ])
      expect(peer.endpoints.first["url"]).to eq("https://child.example.com:443")
    end

    it "consumes the acceptance token (single-use)" do
      described_class.call(**base_args)
      peer.reload
      expect(peer.acceptance_token_digest).to be_nil
      expect(peer.acceptance_token_expires_at).to be_nil
    end

    it "runs the SDWAN governance scan scoped to the accepting peer" do
      expect(::Sdwan::FederationGovernance)
        .to receive(:scan_peer).with(peer: peer).and_return([])

      result = described_class.call(**base_args)
      expect(result.payload[:governance][:status]).to eq("scanned")
    end
  end

  describe ".call — symmetric trust exchange (peer of equals)" do
    let(:peer_ca_pem) { "-----BEGIN CERTIFICATE-----\nPEERCA\n-----END CERTIFICATE-----\n" }
    # Symmetric peers send a CA bundle instead of a CSR.
    let(:symmetric_args) do
      base_args.except(:csr_pem).merge(
        peer_ca_bundle_pem: peer_ca_pem,
        caller_inbound_subject: "fed:caller-assigned-123"
      )
    end

    it "trusts the peer CA, assigns inbound_subject, and self-issues our cert" do
      result = described_class.call(**symmetric_args)

      peer.reload
      expect(peer.trusted_ca_pem).to eq(peer_ca_pem)
      expect(peer.inbound_subject).to eq("fed:#{peer.id}")
      leaf = OpenSSL::X509::Certificate.new(peer.outbound_certificate.credentials["cert_pem"])
      expect(leaf.subject.to_s).to include("fed:caller-assigned-123")

      ex = result.payload[:trust_exchange]
      expect(ex[:ca_bundle_pem]).to include("BEGIN CERTIFICATE")
      expect(ex[:assigned_inbound_subject]).to eq("fed:#{peer.id}")
    end

    it "does not return a federation_certificate (symmetric peers self-issue)" do
      result = described_class.call(**symmetric_args)
      expect(result.payload).not_to have_key(:federation_certificate)
    end
  end

  describe ".call — failure paths" do
    it "fails with 422 when token is blank" do
      result = described_class.call(**base_args.merge(token: ""))
      expect(result.ok?).to be false
      expect(result.status).to eq(422)
      expect(result.error).to match(/acceptance_token required/)
    end

    it "fails with 422 when contract_version is unsupported" do
      plaintext_token
      result = described_class.call(**base_args.merge(contract_version: 99))
      expect(result.ok?).to be false
      expect(result.status).to eq(422)
      expect(result.error).to match(/contract_version/)
    end

    it "fails with 401 when the token matches no peer" do
      result = described_class.call(**base_args.merge(token: "nope-#{SecureRandom.hex(16)}"))
      expect(result.ok?).to be false
      expect(result.status).to eq(401)
    end

    it "fails with 401 when the token is expired" do
      plaintext_token
      peer.update!(acceptance_token_expires_at: 1.hour.ago)
      result = described_class.call(**base_args)
      expect(result.ok?).to be false
      expect(result.status).to eq(401)
    end
  end

  describe ".call — managed_child grant cascade" do
    let(:peer) do
      create(:system_federation_peer, :spawned_parent_managed,
             account: account,
             status: "proposed",
             remote_instance_url: "https://child.example.com")
    end

    before { plaintext_token }

    it "ensures an operator-scope FederationGrant for the peer" do
      expect {
        described_class.call(**base_args)
      }.to change { ::System::FederationGrant.where(federation_peer: peer).count }.by(1)

      grant = ::System::FederationGrant.where(federation_peer: peer).last
      expect(grant.resource_kind).to eq("managed_child_operator")
      expect(grant.permission_scopes).to match_array(%w[read write admin])
      expect(grant.expires_at).to be > 364.days.from_now
      expect(grant.metadata["auto_issued_by"]).to eq("managed_child_accept_cascade")
    end

    it "is idempotent — does not duplicate an existing live grant" do
      ::System::FederationGrant.create!(
        account: peer.account, federation_peer: peer, grantor_user: nil,
        remote_subject: "parent-operator@#{peer.id}",
        resource_kind: "managed_child_operator",
        permission_scopes: %w[read write admin],
        issued_at: Time.current, expires_at: 365.days.from_now,
        metadata: { "auto_issued_by" => "managed_child_accept_cascade" }
      )

      expect {
        described_class.call(**base_args)
      }.not_to change { ::System::FederationGrant.where(federation_peer: peer).count }
    end

    it "does NOT issue a grant for symmetric out_of_band peers" do
      symmetric = create(:system_federation_peer, :platform,
                         account: account, status: "proposed",
                         remote_instance_url: "https://peer.example.com")
      token = symmetric.generate_acceptance_token!(ttl_seconds: 1.hour.to_i)

      expect {
        described_class.call(**base_args.merge(token: token))
      }.not_to change { ::System::FederationGrant.where(federation_peer: symmetric).count }
    end
  end

  describe ".call — node_enrollment issuance" do
    let(:enroll_node) { create(:system_node, account: account) }
    let(:enroll_instance) { create(:system_node_instance, :running, node: enroll_node) }
    let(:peer) do
      create(:system_federation_peer, :spawned_parent_managed,
             account: account, status: "proposed",
             remote_instance_url: "https://child.example.com",
             metadata: { "node_id" => enroll_node.id, "node_instance_id" => enroll_instance.id })
    end

    before { plaintext_token }

    it "issues a bootstrap token bound to the instance UUID and threads platform_url" do
      result = described_class.call(**base_args)
      ne = result.payload[:node_enrollment]

      expect(ne).to be_present
      expect(ne[:intended_subject]).to eq(enroll_instance.id)
      expect(ne[:intended_subject]).not_to eq(enroll_node.name)
      expect(ne[:platform_url]).to eq("https://parent.example.com")
      expect(ne[:bootstrap_token]).to be_present

      token = ::System::BootstrapToken.where(node_id: enroll_node.id).order(:created_at).last
      expect(token.intended_subject).to eq(enroll_instance.id)
      expect(token.purpose).to eq("federation_managed_child_accept")
    end
  end

  describe ".call — post-accept SDWAN attach (SDWAN-first)" do
    let(:network) { ::Sdwan::Network.create!(account_id: account.id, name: "fed-overlay") }
    let(:attach_node) { create(:system_node, account: account) }
    let(:attach_instance) { create(:system_node_instance, :running, node: attach_node) }
    let(:peer) do
      create(:system_federation_peer, :spawned_parent_managed,
             account: account, status: "proposed",
             remote_instance_url: "https://child.example.com",
             metadata: {
               "node_id" => attach_node.id,
               "node_instance_id" => attach_instance.id,
               "sdwan_network_id" => network.id
             })
    end

    before { plaintext_token }

    it "seats the bound instance into the overlay via PeerEnroller with the resolved network + instance" do
      # Assert the exact args — do not blanket-stub. Return a real-shaped
      # double so the service can read .id.
      seated = instance_double(::Sdwan::Peer, id: "seated-peer-id")
      expect(::Sdwan::PeerEnroller)
        .to receive(:call)
        .with(network: network, node_instance: attach_instance)
        .and_return(seated)

      result = described_class.call(**base_args)

      attach = result.payload[:sdwan_attach]
      expect(attach[:status]).to eq("attached")
      expect(attach[:sdwan_network_id]).to eq(network.id)
      expect(attach[:sdwan_peer_id]).to eq("seated-peer-id")
      expect(attach[:node_instance_id]).to eq(attach_instance.id)
    end

    it "activates a FederationNetworkBridge for the peer + network" do
      allow(::Sdwan::PeerEnroller).to receive(:call)
        .and_return(instance_double(::Sdwan::Peer, id: "seated-peer-id"))

      described_class.call(**base_args)

      bridge = ::System::FederationNetworkBridge.find_by(
        federation_peer_id: peer.id, sdwan_network_id: network.id
      )
      expect(bridge).to be_present
      expect(bridge.state).to eq("active")
    end

    it "reuses an existing Sdwan::Peer rather than re-enrolling (idempotent)" do
      existing = ::Sdwan::PeerEnroller.call(network: network, node_instance: attach_instance)

      # A second accept should NOT re-enroll; PeerEnroller must not be called again.
      expect(::Sdwan::PeerEnroller).not_to receive(:call)

      result = described_class.call(**base_args)
      attach = result.payload[:sdwan_attach]
      expect(attach[:status]).to eq("reused")
      expect(attach[:sdwan_peer_id]).to eq(existing.id)
    end

    it "skips attach cleanly when no overlay network is bound" do
      peer.update!(metadata: { "node_id" => attach_node.id, "node_instance_id" => attach_instance.id })
      expect(::Sdwan::PeerEnroller).not_to receive(:call)

      result = described_class.call(**base_args)
      expect(result.payload[:sdwan_attach][:status]).to eq("skipped")
      expect(result.payload[:sdwan_attach][:reason]).to eq("no_overlay_network")
    end

    it "degrades to a warning (not a hard failure) when PeerEnroller raises" do
      allow(::Sdwan::PeerEnroller).to receive(:call)
        .and_raise(StandardError, "enroll boom")

      result = described_class.call(**base_args)
      expect(result.ok?).to be true
      expect(result.payload[:sdwan_attach][:status]).to eq("error")
      expect(result.payload[:warnings].join).to match(/enroll boom/)
    end
  end
end
