# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::Ingress::ForwardAuth", type: :request do
  let(:account) { Account.first || create(:account) }
  let(:user)    { user_with_permissions("system.ingress.read", account: account) }
  let(:path)    { "/api/v1/system/ingress/forward_auth" }

  def create_service(**attrs)
    Sdwan::Service.create!(
      { account: account, slug: "svc-#{SecureRandom.hex(3)}", name: "Grafana",
        protocol: "https", backend_host: "10.20.0.5", backend_port: 3000,
        local_enabled: true, local_auth_mode: "authenticated" }.merge(attrs)
    )
  end

  it "denies an unauthenticated request" do
    svc = create_service
    get path, params: { service: svc.id }
    expect(response).to have_http_status(:unauthorized)
  end

  it "allows an authenticated user and returns identity headers" do
    svc = create_service
    get path, params: { service: svc.id }, headers: auth_headers_for(user)

    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Powernode-User"]).to eq(user.id.to_s)
    expect(response.headers["X-Powernode-Account"]).to eq(account.id.to_s)
    expect(response.headers).to have_key("X-Powernode-Groups")
  end

  it "denies (404) an unknown or foreign-account service" do
    get path, params: { service: SecureRandom.uuid }, headers: auth_headers_for(user)
    expect(response).to have_http_status(:not_found)

    foreign = Sdwan::Service.create!(account: create(:account), slug: "foreign-#{SecureRandom.hex(3)}",
                                     name: "x", protocol: "https", backend_host: "h", backend_port: 80)
    get path, params: { service: foreign.id }, headers: auth_headers_for(user)
    expect(response).to have_http_status(:not_found)
  end

  context "with a scoped service" do
    let(:perm) { "system.ingress.read" }

    it "forbids a user lacking the required permission" do
      svc = create_service(local_auth_mode: "scoped", local_required_permission: "services.privileged.view")
      get path, params: { service: svc.id }, headers: auth_headers_for(user)
      expect(response).to have_http_status(:forbidden)
    end

    it "allows a user holding the required permission" do
      svc = create_service(local_auth_mode: "scoped", local_required_permission: perm)
      get path, params: { service: svc.id }, headers: auth_headers_for(user)
      expect(response).to have_http_status(:ok)
    end
  end
end
