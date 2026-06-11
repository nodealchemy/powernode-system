# frozen_string_literal: true

require "rails_helper"

# Audit F5-02 — WorkerApi::TasksController is the task lifecycle callback
# surface every async fleet operation (module commit, image creation, pool
# ops, storage migration) round-trips through complete/fail/progress, yet it
# had no spec file and no indirect coverage.
RSpec.describe "Api::V1::System::WorkerApi::Tasks", type: :request do
  let(:account)  { create(:account) }
  let!(:worker)  { create(:worker, :system_worker, account: account, status: "active") }
  let(:headers)  { worker_mtls_headers(worker) }
  let(:node)     { create(:system_node, account: account, worker: worker) }

  before do
    allow_any_instance_of(Worker).to receive(:has_permission?).and_return(true)
  end

  def task_with(status:)
    create(:system_task, account: account, operable: node, command: "sync", status: status)
  end

  # F5-02 case 1 — completing an already-terminal task must be a structured
  # error, not a 500 (the ci_workers double-transition bug class).
  describe "POST /tasks/:id/complete" do
    it "completes a running task" do
      task = task_with(status: "running")

      post "/api/v1/system/worker_api/tasks/#{task.id}/complete",
           params: { result: { ok: true } }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(task.reload.status).to eq("complete")
      expect(task.progress).to eq(100)
    end

    it "returns a structured error (not 500) for an already-complete task" do
      task = task_with(status: "complete")

      post "/api/v1/system/worker_api/tasks/#{task.id}/complete", headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["success"]).to be false
      expect(JSON.parse(response.body)["error"]).to match(/running/i)
    end

    it "returns a structured error for an already-failed task" do
      task = task_with(status: "failed")

      post "/api/v1/system/worker_api/tasks/#{task.id}/complete", headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["success"]).to be false
    end
  end

  # F5-02 case 2 — fail records an operation event and persists error details.
  describe "POST /tasks/:id/fail" do
    it "records the error message and a failed event" do
      task = task_with(status: "running")

      post "/api/v1/system/worker_api/tasks/#{task.id}/fail",
           params: { error_message: "disk full" }, headers: headers

      expect(response).to have_http_status(:ok)
      task.reload
      expect(task.status).to eq("failed")
      expect(task.error_message).to eq("disk full")
      expect(task.events.last["type"]).to eq("failed")
      expect(task.events.last["message"]).to eq("disk full")
    end

    it "rejects failing an already-complete task" do
      task = task_with(status: "complete")

      post "/api/v1/system/worker_api/tasks/#{task.id}/fail",
           params: { error_message: "late" }, headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(task.reload.status).to eq("complete")
    end
  end

  # F5-02 case 3 — progress only updates running tasks.
  describe "PUT /tasks/:id/progress" do
    it "updates percent + appends a message event for a running task" do
      task = task_with(status: "running")

      put "/api/v1/system/worker_api/tasks/#{task.id}/progress",
          params: { progress: 42, message: "halfway" }, headers: headers

      expect(response).to have_http_status(:ok)
      task.reload
      expect(task.progress).to eq(42)
      expect(task.events.last["message"]).to eq("halfway")
    end

    it "rejects progress on a non-running (pending) task" do
      task = task_with(status: "pending")

      put "/api/v1/system/worker_api/tasks/#{task.id}/progress",
          params: { progress: 10 }, headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(task.reload.progress).to eq(0)
    end
  end

  # F5-02 (discovered) — the route declares `post :events` → action :events,
  # but the controller method is add_event and the before_action only-list
  # names :add_event, so the endpoint was dead (ActionNotFound 500).
  describe "POST /tasks/:id/events" do
    it "appends an event to a running task" do
      task = task_with(status: "running")

      post "/api/v1/system/worker_api/tasks/#{task.id}/events",
           params: { event_type: "info", message: "checkpoint" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(task.reload.events.last["message"]).to eq("checkpoint")
    end
  end

  # F5-02 case 4 — worker mTLS auth required; a user JWT is rejected.
  describe "authentication" do
    it "rejects a user JWT (no worker cert header)" do
      user = create(:user, account: account)
      task = task_with(status: "running")

      post "/api/v1/system/worker_api/tasks/#{task.id}/complete",
           headers: auth_headers_for(user)

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects an unauthenticated request" do
      task = task_with(status: "running")

      post "/api/v1/system/worker_api/tasks/#{task.id}/complete"

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
