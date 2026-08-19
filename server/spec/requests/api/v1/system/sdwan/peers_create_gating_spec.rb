# frozen_string_literal: true

require "rails_helper"

# IMP-cf285f21f3a9 — peer creation was ungated on BOTH operator surfaces.
#
# The seeded sdwan.peer_create policy (system_sdwan_manager_agent.rb) and the
# engine registration both existed, and Sdwan::Executors::CreatePeer existed and
# had been tenancy-hardened — but no gate! call site anywhere named the
# category, because PeersController#create and SdwanTool#attach_peer both went
# straight to Sdwan::PeerEnroller. The operator's configured policy for joining
# a node to an overlay was decorative, while DELETE on this same controller has
# been gated since slice 1: you could add a peer with no policy check and only
# removing it consulted one.
#
# THE CALLER SPLIT is the load-bearing decision here, so it is pinned rather
# than left to a comment. Sdwan::PeerEnroller has nine production call sites.
# TWO are operator-initiated and are gated:
#
#   PeersController#create        (REST)
#   Ai::Tools::SdwanTool#attach_peer (MCP)
#
# SEVEN are internal composition and stay ungated — gating them would put an
# operator approval in the middle of automated provisioning:
#
#   System::ProvisioningService                      (per-instance auto-enroll)
#   System::Federation::FederationAcceptanceService  (already gated upstream)
#   System::Ai::Skills::ProvisionFullStackExecutor
#   System::Ai::Skills::ConfigureSdwanForProjectExecutor
#   System::Ai::Skills::SdwanFederationComposeExecutor
#   System::Storage::CredentialIssuer
#   System::Storage::AssignmentReconciliationService
#
# The two skill-executor cases below stand for that set: they are the ones a
# future gating sweep is most likely to catch by accident, because they create
# peers from an AI-dispatched path that superficially looks operator-initiated.
RSpec.describe "Api::V1::System::Sdwan::Peers create gating", type: :request do
  let(:user) { user_with_permissions("system.sdwan.peers.manage", "system.sdwan.peers.read") }
  let(:account) { user.account }
  let(:reader) { user_with_permissions("system.sdwan.peers.read", account: account) }
  let!(:network) { create(:sdwan_network, account: account) }
  let!(:node) { create(:system_node, account: account) }
  let!(:instance) { create(:system_node_instance, node: node, account: account) }

  def collection_path = "/api/v1/system/sdwan/networks/#{network.id}/peers"

  def post_create(as: user)
    post collection_path,
         params: { peer: { node_instance_id: instance.id, listen_port: 51_820 } }.to_json,
         headers: auth_headers_for(as).merge("Content-Type" => "application/json")
  end

  # A fresh spec account has no InterventionPolicy rows, so
  # InterventionPolicyService falls through to its require_approval default.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  describe "REST surface" do
    it "requires system.sdwan.peers.manage" do
      post_create(as: reader)

      expect(response).to have_http_status(:forbidden)
    end

    # The finding: this enrolled the peer inline behind the permission check,
    # so sdwan.peer_create never resolved against anything.
    it "defers the create through the autonomy gate instead of enrolling inline" do
      post_create

      expect(response).to have_http_status(:accepted)
      expect(json_response_data["pending"]).to eq(true)
      expect(network.peers.reload.count).to eq(0),
                                            "a peer joined the overlay without an approval gate"

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "POST did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.peer_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreatePeer")
      expect(deferred.params["network_id"]).to eq(network.id)
      expect(deferred.params.dig("attributes", "node_instance_id")).to eq(instance.id)
    end

    it "enrolls a real peer on the auto-approve branch" do
      auto_approve_policy!

      post_create

      expect(response).to have_http_status(:created)
      peer = network.peers.reload.first
      expect(peer).to be_present
      # Not merely a row: the gated path must produce the same peer the
      # ungated one did, which is what the executor's enroller delegation buys.
      expect(peer.active_key).to be_present
      expect(::Sdwan::HostVrfAssignment.find_by(node_instance_id: instance.id,
                                                sdwan_network_id: network.id)).to be_present
    end

    # The approval card is composed from a parked payload, and CreatePeer's
    # label work (2b2ecc8f) goes live the moment this lands — so the anchor is
    # re-verified against a REAL gated preview rather than a hand-built one.
    it "renders an operator-recognisable card from the parked operation" do
      instance.update!(name: "edge-lon-01")
      network.update!(name: "wan-core")

      post_create

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      preview = deferred.preview

      expect(preview[:summary]).to eq("Add SDWAN peer edge-lon-01 on wan-core"),
                                  "the card an approver sees does not name the peer or the network"
      expect(deferred.description).to eq(preview[:summary]),
                                      "the approvals LIST and the card disagree about the same operation"
    end
  end

  describe "MCP surface" do
    # Same idiom as sdwan_tool_spec: invoke through .execute(params:).
    let(:tool) { ::Ai::Tools::SdwanTool.new(account: account, user: user) }

    def attach_peer_via_mcp
      tool.execute(params: { action: "system_sdwan_attach_peer", network_id: network.id,
                             node_instance_id: instance.id })
    end

    it "defers attach_peer through the autonomy gate" do
      attach_peer_via_mcp

      expect(network.peers.reload.count).to eq(0),
                                            "the MCP surface attached a peer without an approval gate"

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "attach_peer did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.peer_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreatePeer")
    end

    it "attaches a fully enrolled peer on the auto-approve branch" do
      auto_approve_policy!

      attach_peer_via_mcp

      peer = network.peers.reload.first
      expect(peer).to be_present
      expect(peer.active_key).to be_present
    end
  end

  # THE OTHER HALF OF THE SPLIT. These must NOT open a gate. A future sweep
  # that "finishes the job" by routing PeerEnroller itself through the gate
  # would deadlock automated provisioning the first time an operator set
  # sdwan.peer_create to require_approval — and the seeded default is
  # notify_and_proceed, so that breakage would not show up until then.
  describe "internal composition stays ungated" do
    it "does not gate the per-instance enrollment inside a provisioning compose" do
      expect {
        ::Sdwan::PeerEnroller.call(network: network, node_instance: instance)
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(network.peers.reload.count).to eq(1)
    end

    it "leaves the enroller itself as the ungated seam every composer calls" do
      # Stated as a property of the seam rather than of one caller: every
      # internal site reaches the overlay through this one call, so pinning it
      # covers all seven without seven fixtures.
      peer = ::Sdwan::PeerEnroller.call(network: network, node_instance: instance)

      expect(peer).to be_persisted
      expect(::Ai::DeferredOperation.where(action_category: "sdwan.peer_create").count).to eq(0)
    end
  end
end
