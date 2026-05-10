# frozen_string_literal: true

require "rails_helper"

# Phase O6 of the OVS+OVN dual-profile networking roadmap.
RSpec.describe "Api::V1::System::Sdwan::OvnDeployments", type: :request do
  let(:user)    { user_with_permissions("sdwan.ovn.read") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }

  before do
    Sdwan::OvnLogicalSwitchPort.where(account_id: account.id).delete_all
    Sdwan::OvnLogicalSwitch.where(account_id: account.id).delete_all
    Sdwan::OvnDeployment.where(account_id: account.id).delete_all
  end

  describe "GET /api/v1/system/sdwan/ovn_deployments" do
    it "returns an empty list when no deployment exists" do
      get "/api/v1/system/sdwan/ovn_deployments", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response_data["ovn_deployments"]).to eq([])
      expect(json_response_data["count"]).to eq(0)
    end

    it "returns the per-account deployment with summary counts" do
      d = ::Sdwan::OvnDeployment.create!(
        account_id: account.id,
        nb_db_endpoint: "tcp:127.0.0.1:6641",
        sb_db_endpoint: "tcp:127.0.0.1:6642"
      )
      s = ::Sdwan::OvnLogicalSwitch.create!(
        account_id: account.id, sdwan_ovn_deployment_id: d.id, name: "ls-app"
      )
      s.mark_active!
      p = ::Sdwan::OvnLogicalSwitchPort.create!(
        account_id: account.id, sdwan_ovn_logical_switch_id: s.id,
        name: "p-app", kind: "external"
      )
      p.mark_active!

      get "/api/v1/system/sdwan/ovn_deployments", headers: headers
      expect(response).to have_http_status(:ok)
      payload = json_response_data["ovn_deployments"].first
      expect(payload["id"]).to eq(d.id)
      expect(payload["switch_count"]).to eq(1)
      expect(payload["port_count"]).to eq(1)
    end

    it "is account-scoped — does not return another account's deployment" do
      other = create(:account)
      ::Sdwan::OvnDeployment.create!(
        account_id: other.id,
        nb_db_endpoint: "tcp:127.0.0.1:6641", sb_db_endpoint: "tcp:127.0.0.1:6642"
      )
      get "/api/v1/system/sdwan/ovn_deployments", headers: headers
      expect(json_response_data["ovn_deployments"]).to eq([])
    end

    it "rejects without the read permission" do
      no_perm_user = user_with_permissions("sdwan.networks.read")
      get "/api/v1/system/sdwan/ovn_deployments", headers: auth_headers_for(no_perm_user)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/system/sdwan/ovn_deployments/:id" do
    let(:deployment) do
      ::Sdwan::OvnDeployment.create!(
        account_id: account.id,
        nb_db_endpoint: "tcp:127.0.0.1:6641", sb_db_endpoint: "tcp:127.0.0.1:6642"
      )
    end

    it "returns the deployment with nested switches + ports + compiled plan" do
      s = ::Sdwan::OvnLogicalSwitch.create!(
        account_id: account.id, sdwan_ovn_deployment_id: deployment.id,
        name: "ls-web", cidr: "10.10.0.0/24"
      )
      s.mark_active!
      p = ::Sdwan::OvnLogicalSwitchPort.create!(
        account_id: account.id, sdwan_ovn_logical_switch_id: s.id,
        name: "p-web", kind: "external"
      )
      p.mark_active!

      get "/api/v1/system/sdwan/ovn_deployments/#{deployment.id}", headers: headers
      expect(response).to have_http_status(:ok)
      payload = json_response_data["ovn_deployment"]
      expect(payload["id"]).to eq(deployment.id)
      expect(payload["logical_switches"].size).to eq(1)
      switch = payload["logical_switches"].first
      expect(switch["name"]).to eq("ls-web")
      expect(switch["cidr"]).to eq("10.10.0.0/24")
      expect(switch["ports"].size).to eq(1)
      expect(switch["ports"].first["name"]).to eq("p-web")

      compiled = json_response_data["compiled_plan"]
      expect(compiled["plan"]).to be_present
    end

    it "returns 404 for a deployment in a different account" do
      other = create(:account)
      other_deployment = ::Sdwan::OvnDeployment.create!(
        account_id: other.id,
        nb_db_endpoint: "tcp:127.0.0.1:6641", sb_db_endpoint: "tcp:127.0.0.1:6642"
      )
      get "/api/v1/system/sdwan/ovn_deployments/#{other_deployment.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
