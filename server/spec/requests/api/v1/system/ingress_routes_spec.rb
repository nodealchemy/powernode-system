# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::IngressRoutes", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.ingress.read", account: account) }
  let(:base)    { "/api/v1/system/ingress_routes" }

  include_examples "requires authentication", :get, "/api/v1/system/ingress_routes"

  describe "GET /ingress_routes" do
    let!(:valid_cert) do
      create(:system_acme_certificate, :valid, account: account,
                                               common_name: "ingress.example.com")
    end

    it "forbids without system.ingress.read permission" do
      anon = create(:user, account: account)
      get base, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns a derived route projection for a valid certificate" do
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      routes = json_response_data["routes"]
      route = routes.find { |r| r["common_name"] == "ingress.example.com" }
      expect(route).to be_present

      # status-derived fields
      expect(route["status"]).to eq("valid")
      expect(route["active"]).to be true
      expect(route["id"]).to eq(valid_cert.id)

      # host_rule reflects the common_name (matches the TraefikConfigWriter matcher)
      expect(route["host_rule"]).to eq("Host(`ingress.example.com`)")

      # derived routers array is present + carries the writer's metadata shape
      routers = route["routers"]
      expect(routers).to be_an(Array)
      expect(routers).not_to be_empty

      node_api = routers.find { |r| r["name"] == "ingress-example-com-node-api" }
      expect(node_api).to be_present
      expect(node_api["path_prefix"]).to eq("/api/v1/system/node_api")
      expect(node_api["backend_service"]).to eq("powernode-backend")
      expect(node_api["entrypoint"]).to eq("websecure")
      expect(node_api["tls_resolver"]).to eq("mtls-optional@file")

      # frontend catchall has a null/empty path prefix
      frontend = routers.find { |r| r["name"] == "ingress-example-com-frontend" }
      expect(frontend).to be_present
      expect(frontend["path_prefix"]).to be_nil
      expect(frontend["backend_service"]).to eq("powernode-frontend")

      # sidekiq dashboard router → worker-web service (routed via the bundled proxy)
      sidekiq = routers.find { |r| r["name"] == "ingress-example-com-sidekiq" }
      expect(sidekiq).to be_present
      expect(sidekiq["path_prefix"]).to eq("/sidekiq")
      expect(sidekiq["backend_service"]).to eq("powernode-worker-web")

      # public_endpoints convenience list reflects the common_name
      expect(route["public_endpoints"]).to include("https://ingress.example.com/")
    end

    it "projection is unchanged when the controller threads env values into the presenter" do
      # Fix #10: the controller resolves the env-derived reverse-proxy values
      # once per request and threads them into the presenter (instead of the
      # writer re-reading the env ~12x per cert). The threaded-through output
      # must be byte-for-byte identical to the presenter reading the env itself.
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)
      route = json_response_data["routes"].find { |r| r["common_name"] == "ingress.example.com" }

      # Default-arg presenter (reads env directly) == controller's threaded output.
      expected = ::Acme::IngressRoutePresenter.project(valid_cert).deep_stringify_keys
      expect(route).to eq(expected)
    end

    it "reflects POWERNODE_PROXY_EXTRA_HOSTS resolved once per request" do
      # Per-example env set (no class-level memo) must flow through to the
      # host_rule + public_endpoints of every cert in the response.
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POWERNODE_PROXY_EXTRA_HOSTS")
                                .and_return("public.example.com")

      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)
      route = json_response_data["routes"].find { |r| r["common_name"] == "ingress.example.com" }

      expect(route["host_rule"]).to eq("(Host(`ingress.example.com`) || Host(`public.example.com`))")
      expect(route["public_endpoints"]).to include(
        "https://ingress.example.com/", "https://public.example.com/"
      )
    end

    it "filters by status" do
      create(:system_acme_certificate, account: account, common_name: "pending.example.com",
                                       status: "pending")
      get base, headers: auth_headers_for(reader), params: { status: "valid" }
      expect(response).to have_http_status(:ok)
      names = json_response_data["routes"].map { |r| r["common_name"] }
      expect(names).to include("ingress.example.com")
      expect(names).not_to include("pending.example.com")
    end

    it "scopes to the current account only" do
      create(:system_acme_certificate, :valid, account: create(:account),
                                               common_name: "leak.example.com")
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)
      names = json_response_data["routes"].map { |r| r["common_name"] }
      expect(names).to include("ingress.example.com")
      expect(names).not_to include("leak.example.com")
    end
  end
end
