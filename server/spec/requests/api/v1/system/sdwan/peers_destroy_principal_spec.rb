# frozen_string_literal: true

require "rails_helper"

# IMP-dbf945e7e4db — a REST park wrote no principal block, so the row was
# invisible to Ai::Approvals::ParkPrincipal.parked_by_instance and never
# machine_requested?. Ai::AutonomyGate derives one from the session's user.
RSpec.describe "SDWAN peer destroy — parked principal", type: :request do
  let(:user)    { user_with_permissions("system.sdwan.peers.manage") }
  let(:account) { user.account }
  let(:network) { create(:sdwan_network, account: account, name: "wan-core") }

  it "records the requesting user as the principal on the parked row" do
    peer = create(:sdwan_peer, :hub, account: account, network: network)

    delete "/api/v1/system/sdwan/networks/#{network.id}/peers/#{peer.id}", headers: auth_headers_for(user)

    expect(response.status).to be_in([ 200, 202 ])
    operation = ::Ai::DeferredOperation.where(action_category: "sdwan.peer_delete").order(:created_at).last
    expect(operation.params["principal"]).to include("kind" => "user", "user_id" => user.id)
  end
end
