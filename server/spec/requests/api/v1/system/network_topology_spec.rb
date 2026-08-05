# frozen_string_literal: true

require "rails_helper"

# Audit F8-08 — TopologyController#show originally had no permission gate
# (any authenticated account member could read the full topology) and a
# current_account fallback to Account.find(params[:account_id]) — a
# cross-account read hazard should any auth path ever yield a user
# without an account. The gate landed in 6b485b5; these specs pin it and
# the fallback removal.
RSpec.describe "GET /api/v1/system/network/topology", type: :request do
  let(:account) { create(:account) }

  it "returns the topology for a user with sdwan.networks.read" do
    user = user_with_permissions("system.sdwan.networks.read", account: account)

    get "/api/v1/system/network/topology", headers: auth_headers_for(user)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.dig("data", "nodes")).to be_an(Array)
    expect(body.dig("data", "edges")).to be_an(Array)
  end

  it "returns 403 without sdwan.networks.read" do
    user = user_with_permissions("system.nodes.read", account: account)

    get "/api/v1/system/network/topology", headers: auth_headers_for(user)

    expect(response).to have_http_status(:forbidden)
  end
end

RSpec.describe Api::V1::System::Network::TopologyController do
  describe "#current_account (F8-08 cross-account hazard)" do
    it "never falls back to Account.find(params[:account_id])" do
      other = create(:account)
      controller = described_class.new
      allow(controller).to receive(:current_user).and_return(nil)
      allow(controller).to receive(:params)
        .and_return(ActionController::Parameters.new(account_id: other.id))

      expect(controller.send(:current_account)).to be_nil
    end
  end
end
