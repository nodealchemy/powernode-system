# frozen_string_literal: true

require "rails_helper"

# IMP-ee57d0fbe859 — the LISTED approval card. PeersController#destroy passes
# `description:` to Ai::AutonomyGate, which persists it on the
# Ai::DeferredOperation and copies it onto the Ai::ApprovalRequest
# (autonomy_gate.rb:124). Both approvals serializers read
# ApprovalRequest#description — Ai::AutonomyApprovalActions#approval_request_json
# and Api::V1::Ai::GovernanceController#approval_request_json — so this string
# IS what an operator reads in the approvals list.
#
# It previously interpolated `@peer.try(:endpoint) || @peer.id`, and Sdwan::Peer
# defines no `endpoint` method and system_sdwan_peers has no `endpoint` column
# (verified by reflection: Sdwan::Peer.new.respond_to?(:endpoint) => false), so
# the card always degraded to the bare UUID rung.
RSpec.describe "SDWAN peer destroy — approval description", type: :request do
  let(:user)    { user_with_permissions("system.sdwan.peers.manage") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }
  let(:network) { create(:sdwan_network, account: account, name: "wan-core") }

  it "names the peer and its network on the approval card, never a bare UUID" do
    peer = create(:sdwan_peer, :hub, account: account, network: network)
    peer.node_instance.update!(name: "edge-lon-01")

    delete "/api/v1/system/sdwan/networks/#{network.id}/peers/#{peer.id}", headers: headers

    expect(response.status).to be_in([ 200, 202 ])
    operation = ::Ai::DeferredOperation.where(action_category: "sdwan.peer_delete").order(:created_at).last
    expect(operation).to be_present
    expect(operation.description).to eq("Delete SDWAN peer edge-lon-01 on wan-core")
    expect(operation.description).not_to include(peer.id)
  end

  it "renders the same label the notification body does — one labeler, two surfaces" do
    peer = create(:sdwan_peer, :hub, account: account, network: network)
    peer.node_instance.update!(name: "edge-lon-01")
    # The notification content renders preview[:summary]
    # (Ai::DeferredOperationApprovalContent#title/#message); the listed card
    # renders `description`. Drift between them is the defect this pins.
    # Taken before the request because an auto-proceeding gate (core mode, no
    # Ai::ApprovalChain) destroys the peer inline, after which preview can only
    # report its missing-peer fallback.
    #
    # IMP-8e4674f4d62d — through a PreviewContext, which is exactly what
    # Ai::DeferredOperation#preview hands the executor in production. The
    # stand-in used to pass nothing; now that the label is account-anchored
    # that would compare the description against the unanchored floor (a bare
    # UUID) and pin the wrong thing.
    notification_summary = ::Sdwan::Executors::DeletePeer.preview(
      { peer_id: peer.id, network_id: network.id },
      deferred_operation: ::Ai::DeferredOperation::PreviewContext.new(account)
    )[:summary]

    delete "/api/v1/system/sdwan/networks/#{network.id}/peers/#{peer.id}", headers: headers

    operation = ::Ai::DeferredOperation.where(action_category: "sdwan.peer_delete").order(:created_at).last
    expect(operation.description).to eq(notification_summary)
  end
end
