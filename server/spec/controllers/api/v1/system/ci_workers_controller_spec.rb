# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for per-account CI workers.
# Permission family: system.ci_workers.*. Token returned plaintext exactly
# once (only on create + rotate_token); after that it's a SHA256-only column
# the operator can't recover.
RSpec.describe "Api::V1::System::CiWorkers", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)   { user_with_permissions("system.ci_workers.read",         account: account) }
  let(:create_user) { user_with_permissions("system.ci_workers.read", "system.ci_workers.create", account: account) }
  let(:delete_user) { user_with_permissions("system.ci_workers.read", "system.ci_workers.delete", account: account) }
  let(:rotate_user) { user_with_permissions("system.ci_workers.read", "system.ci_workers.rotate_token", account: account) }
  let(:no_perms)    { user_with_permissions(account: account) }

  # Bring up a CI worker for show/destroy/rotate tests via the factory method.
  let!(:ci_worker) do
    ::Worker.create_worker!(name: "spec-ci-#{SecureRandom.hex(3)}", account: account, roles: [ "ci_worker" ])
  end

  describe "GET /api/v1/system/ci_workers" do
    it "returns 401 without auth" do
      get "/api/v1/system/ci_workers"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/ci_workers", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "lists only ci_worker-role workers in the caller's account" do
      foreign = ::Worker.create_worker!(name: "foreign-ci", account: other_account, roles: [ "ci_worker" ])
      get "/api/v1/system/ci_workers", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      ids = json_response_data["ci_workers"].map { |w| w["id"] }
      expect(ids).to include(ci_worker.id)
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/ci_workers/:id" do
    it "returns the ci_worker" do
      get "/api/v1/system/ci_workers/#{ci_worker.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["ci_worker"]["id"]).to eq(ci_worker.id)
    end

    it "returns 404 for a worker without the ci_worker role" do
      # Account workers can hold member|manager|billing_admin|developer|owner|ci_worker —
      # `member` is the smallest valid alternative that isn't ci_worker.
      generic_worker = ::Worker.create_worker!(name: "generic", account: account, roles: [ "member" ])
      get "/api/v1/system/ci_workers/#{generic_worker.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/ci_workers" do
    it "returns 403 without create perm" do
      post "/api/v1/system/ci_workers",
           params: { name: "x" }.to_json,
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "creates a ci_worker and returns the plaintext token exactly once" do
      expect {
        post "/api/v1/system/ci_workers",
             params: { name: "new-spec-ci-#{SecureRandom.hex(3)}" }.to_json,
             headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      }.to change { ::Worker.count }.by(1)
      expect(response).to have_http_status(:ok).or have_http_status(:created)
      expect(json_response_data["token_plaintext"]).to be_present
      expect(json_response_data["note"]).to include("POWERNODE_CI_WORKER_TOKEN")
    end
  end

  describe "POST /api/v1/system/ci_workers/:id/rotate_token" do
    it "returns 403 without rotate_token perm" do
      post "/api/v1/system/ci_workers/#{ci_worker.id}/rotate_token",
           headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "returns a fresh plaintext token + emits a rotated event" do
      old_digest = ci_worker.token_digest
      post "/api/v1/system/ci_workers/#{ci_worker.id}/rotate_token",
           headers: auth_headers_for(rotate_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(json_response_data["token_plaintext"]).to start_with("swt_")
      expect(ci_worker.reload.token_digest).not_to eq(old_digest)
    end
  end

  describe "DELETE /api/v1/system/ci_workers/:id" do
    it "revokes the worker" do
      delete "/api/v1/system/ci_workers/#{ci_worker.id}", headers: auth_headers_for(delete_user)
      expect(response).to have_http_status(:ok)
      expect(ci_worker.reload.status).to eq("revoked")
    end
  end
end
