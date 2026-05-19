# frozen_string_literal: true

require "rails_helper"

# Audit plan P0.1 wave 1 — controller spec for system tasks.
#
# Permission family: system.infra_tasks.* (read, create, control). Create
# flows through Ai::AutonomyGate; cancel is a direct AASM transition (no
# gate). Other transitions (start/complete/fail/abort) are deliberately
# not exposed on the operator API — they belong to the worker dispatch
# chain.
RSpec.describe "Api::V1::System::Tasks", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  let(:read_user)    { user_with_permissions("system.infra_tasks.read",    account: account) }
  let(:create_user)  { user_with_permissions("system.infra_tasks.create",  account: account) }
  let(:control_user) { user_with_permissions("system.infra_tasks.read", "system.infra_tasks.control", account: account) }
  let(:no_perms)     { user_with_permissions(account: account) }

  let(:node) { create(:system_node, account: account) }
  let!(:task) { create(:system_task, account: account, operable: node, command: "sync", status: "pending") }

  describe "GET /api/v1/system/tasks" do
    it "returns 401 without auth" do
      get "/api/v1/system/tasks"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without read perm" do
      get "/api/v1/system/tasks", headers: auth_headers_for(no_perms)
      expect(response).to have_http_status(:forbidden)
    end

    it "scopes to the caller's account" do
      foreign_node = create(:system_node, account: other_account)
      foreign = create(:system_task, account: other_account, operable: foreign_node, command: "sync")
      get "/api/v1/system/tasks", headers: auth_headers_for(read_user)
      ids = json_response_data["tasks"].map { |t| t["id"] }
      expect(ids).to include(task.id)
      expect(ids).not_to include(foreign.id)
    end
  end

  describe "GET /api/v1/system/tasks/:id" do
    it "returns the task" do
      get "/api/v1/system/tasks/#{task.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["task"]["id"]).to eq(task.id)
    end

    it "returns 404 for another account's task" do
      foreign_node = create(:system_node, account: other_account)
      foreign = create(:system_task, account: other_account, operable: foreign_node, command: "sync")
      get "/api/v1/system/tasks/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/tasks (create — gated through Ai::AutonomyGate)" do
    let(:create_params) do
      { task: { command: "sync", operable_type: "System::Node", operable_id: node.id } }
    end

    it "returns 403 without create perm" do
      post "/api/v1/system/tasks", params: create_params.to_json,
                                   headers: auth_headers_for(no_perms).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "returns a 2xx status (created/accepted) when the gate permits" do
      post "/api/v1/system/tasks", params: create_params.to_json,
                                   headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      # The exact decision depends on the seeded intervention policy for
      # system.task.sync — accept any 2xx as a successful gate traversal.
      expect(response.status).to be_between(200, 299)
    end

    it "honors idempotency_key — duplicate POST returns the existing task" do
      key = "spec-idem-#{SecureRandom.hex(3)}"
      existing = create(:system_task, account: account, operable: node, command: "sync", idempotency_key: key)
      post "/api/v1/system/tasks",
           params: { task: { command: "sync", operable_type: "System::Node",
                              operable_id: node.id, idempotency_key: key } }.to_json,
           headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(json_response_data["task"]["id"]).to eq(existing.id)
    end
  end

  describe "POST /api/v1/system/tasks/:id/cancel" do
    it "returns 403 without control perm" do
      post "/api/v1/system/tasks/#{task.id}/cancel",
           headers: auth_headers_for(read_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "cancels a pending task" do
      post "/api/v1/system/tasks/#{task.id}/cancel",
           headers: auth_headers_for(control_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(task.reload.status).to eq("cancelled").or eq("canceled")
    end

    it "returns 422 when the task is not cancellable (state-machine guard)" do
      running = create(:system_task, account: account, operable: node, command: "sync", status: "complete")
      post "/api/v1/system/tasks/#{running.id}/cancel",
           headers: auth_headers_for(control_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_entity)
    end
  end
end
