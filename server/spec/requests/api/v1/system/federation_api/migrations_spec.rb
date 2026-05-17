# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::System::FederationApi::Migrations", type: :request do
  let(:account) { create(:account) }
  let(:grantor) { create(:user, account: account) }
  let(:node_module) { create(:system_node_module, account: account) }

  let(:cert) do
    ::System::NodeCertificate.create!(
      account: account, subject_kind: "federation_peer",
      subject: "federation-peer-#{SecureRandom.uuid}",
      serial: SecureRandom.hex(16),
      not_before: 1.day.ago, not_after: 180.days.from_now,
      pem_chain: "stub", issuer_subject: "Powernode Internal CA"
    )
  end
  let(:peer) do
    create(:system_federation_peer, :active,
           account: account, node_certificate: cert)
  end
  let(:mtls_headers) { { "SSL_CLIENT_S_DN_CN" => cert.id } }
  let(:auth_headers) { mtls_headers.merge("Authorization" => "Bearer #{grant.bearer_token}") }

  let(:path) { "/api/v1/system/federation_api/migrations" }

  let(:new_resource_id) { SecureRandom.uuid }
  let(:base_payload) do
    {
      operation: "duplicate",
      root_resource_kind: "module_service",
      root_resource_id: new_resource_id,
      plan_summary: { "total_steps" => 1 },
      steps: [
        {
          step_order: 0,
          resource_kind: "module_service",
          resource_id: new_resource_id,
          action: "create",
          conflict_policy: "fail",
          payload: {
            "id" => new_resource_id,
            "node_module_id" => node_module.id,
            # Source-account id — should be rewritten on destination
            "account_id" => SecureRandom.uuid,
            "name" => "migrated-svc",
            "start_command" => "/usr/bin/true",
            "restart_policy" => "always",
            "health_method" => "GET",
            "health_interval_seconds" => 30,
            "health_timeout_seconds" => 5,
            "health_initial_delay_seconds" => 10,
            "env" => {},
            "metadata" => {}
          }
        }
      ]
    }
  end

  before do
    fake_registry = ::System::Federation::InventoryRegistry.new
    fake_registry.register_kind(
      ::System::Federation::InventoryRegistry::Kind.new(
        extension: "system",
        kind: "module_service",
        dependencies: [],
        duplicable: true,
        migratable: true,
        metadata: {}
      )
    )
    ::System::Federation::InventoryRegistry.install_test_double(fake_registry)
  end

  after { ::System::Federation::InventoryRegistry.install_test_double(nil) }

  describe "POST /migrations (happy path)" do
    let!(:grant) do
      create(:system_federation_grant,
             account: account, federation_peer: peer,
             grantor_user: grantor,
             remote_subject: "alice@a",
             resource_kind: "module_service",
             resource_id: nil, # kind-wide grant for migrations
             permission_scopes: [ "migrate" ])
    end

    it "creates the destination Migration + applies it + returns 201" do
      post path, params: base_payload.to_json,
                 headers: auth_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      data = body["data"] || body
      expect(data["status"]).to eq("completed")
      expect(data["applied_count"]).to eq(1)
      expect(data["migration_id"]).to be_present

      migration = ::System::Migration.find(data["migration_id"])
      expect(migration.account_id).to eq(account.id)
      expect(migration.metadata["source_peer_id"]).to eq(peer.id)
      expect(migration.metadata["grant_id"]).to eq(grant.id)

      record = ::System::ModuleService.find_by(id: new_resource_id)
      expect(record).to be_present
      expect(record.account_id).to eq(account.id)
      expect(record.name).to eq("migrated-svc")
    end

    it "rewrites the payload's account_id to the destination's account" do
      post path, params: base_payload.to_json,
                 headers: auth_headers.merge("Content-Type" => "application/json")

      record = ::System::ModuleService.find_by(id: new_resource_id)
      expect(record.account_id).to eq(account.id)
    end
  end

  describe "POST /migrations (validation failures)" do
    let!(:grant) do
      create(:system_federation_grant,
             account: account, federation_peer: peer,
             grantor_user: grantor,
             remote_subject: "alice@a",
             resource_kind: "module_service",
             resource_id: nil,
             permission_scopes: [ "migrate" ])
    end

    it "rejects missing top-level fields with 400" do
      post path,
           params: { operation: "duplicate" }.to_json,
           headers: auth_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to match(/Missing required fields/)
    end

    it "rejects an empty steps array with 400" do
      post path,
           params: base_payload.merge(steps: []).to_json,
           headers: auth_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to match(/at least one step/)
    end

    it "rejects an unknown operation with 400" do
      post path,
           params: base_payload.merge(operation: "teleport").to_json,
           headers: auth_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to match(/operation must be one of/)
    end

    it "rejects steps missing required fields with 400" do
      bad_payload = base_payload.deep_dup
      bad_payload[:steps][0].delete(:action)
      post path, params: bad_payload.to_json,
                 headers: auth_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to match(/missing required fields/)
    end
  end

  describe "POST /migrations (auth failures)" do
    let!(:grant) do
      create(:system_federation_grant,
             account: account, federation_peer: peer,
             grantor_user: grantor,
             remote_subject: "alice@a",
             resource_kind: "module_service",
             resource_id: nil,
             permission_scopes: [ "migrate" ])
    end

    it "returns 401 when the Bearer token is missing" do
      post path, params: base_payload.to_json,
                 headers: mtls_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when the grant's resource_kind mismatches the migration root_kind" do
      mismatched = create(:system_federation_grant,
                           account: account, federation_peer: peer,
                           grantor_user: grantor,
                           remote_subject: "alice@a",
                           resource_kind: "different_kind",
                           permission_scopes: [ "migrate" ])
      post path, params: base_payload.to_json,
                 headers: mtls_headers.merge(
                   "Authorization" => "Bearer #{mismatched.bearer_token}",
                   "Content-Type" => "application/json"
                 )
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 when the grant lacks the :migrate scope" do
      # Distinct remote_subject — the (peer, subject, kind) tuple has a
      # unique index, so we can't have two grants for the same triple.
      read_only = create(:system_federation_grant,
                          account: account, federation_peer: peer,
                          grantor_user: grantor,
                          remote_subject: "alice-readonly@a",
                          resource_kind: "module_service",
                          permission_scopes: [ "read" ])
      post path, params: base_payload.to_json,
                 headers: mtls_headers.merge(
                   "Authorization" => "Bearer #{read_only.bearer_token}",
                   "Content-Type" => "application/json"
                 )
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /migrations (apply failures)" do
    let!(:grant) do
      create(:system_federation_grant,
             account: account, federation_peer: peer,
             grantor_user: grantor,
             remote_subject: "alice@a",
             resource_kind: "module_service",
             resource_id: nil,
             permission_scopes: [ "migrate" ])
    end

    it "returns 422 when ApplyExecutor rolls back on conflict_policy=fail" do
      existing = create(:system_module_service, account: account, node_module: node_module)
      # Conflict-policy=fail only triggers for migrate operations under
      # LD #14 — duplicate plans can't PK-collide (executor rejects that
      # case as a composer bug before checking the policy).
      colliding_payload = base_payload.deep_dup
      colliding_payload[:operation] = "migrate"
      colliding_payload[:steps][0][:resource_id] = existing.id
      colliding_payload[:steps][0][:payload]["id"] = existing.id
      colliding_payload[:root_resource_id] = existing.id

      post path, params: colliding_payload.to_json,
                 headers: auth_headers.merge("Content-Type" => "application/json")

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("failed")
      expect(body["error"]).to match(/policy=fail/)
      expect(body["migration_id"]).to be_present
    end
  end

  describe "POST /migrations (unknown kind)" do
    let!(:grant) do
      create(:system_federation_grant,
             account: account, federation_peer: peer,
             grantor_user: grantor,
             remote_subject: "alice@a",
             resource_kind: "module_service",
             resource_id: nil,
             permission_scopes: [ "migrate" ])
    end

    it "returns 422 when the root_resource_kind isn't in the inventory registry" do
      # Tear down the test-double — now no kind is known
      ::System::Federation::InventoryRegistry.install_test_double(
        ::System::Federation::InventoryRegistry.new
      )

      post path, params: base_payload.to_json,
                 headers: auth_headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/not declared in federation_inventory/)
    end
  end
end
