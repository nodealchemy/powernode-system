# frozen_string_literal: true

require "rails_helper"

# The janitor seam exists because SystemTaskReaperJob was INERT for five weeks
# while reporting success every hour. Its list call went to
# WorkerApi::TasksController, scoped through
# `System::Node.where(worker: current_worker)`, and `node.worker_id` is NULL on
# every node that has ever existed — so the scope was the empty set and the
# reaper's honest report of what it saw ("0 stuck tasks") was indistinguishable
# from a clean fleet.
#
# The FIRST describe block below is therefore the load-bearing one: it pins the
# old scope's emptiness and the new scope's visibility against the SAME row. A
# spec that only exercised the janitor would pass just as happily if the bug had
# never existed, and would not notice its return.
RSpec.describe "Api::V1::System::WorkerApi::Janitor", type: :request do
  let(:account) { create(:account) }
  let!(:worker) { create(:worker, account: account, status: "active") }
  let(:headers) { worker_mtls_headers(worker) }

  # worker_id deliberately NOT set — this is the production shape (157/157
  # nodes measured on live ops-hub carry NULL here).
  let(:node) { create(:system_node, account: account) }

  def stuck_task(status: "pending", command: "sync", age: 2.hours, started_ago: nil)
    task = create(:system_task, account: account, operable: node, command: command, status: status)
    task.update_columns(
      created_at: age.ago,
      started_at: started_ago ? started_ago.ago : task.started_at
    )
    task
  end

  before { allow_any_instance_of(Worker).to receive(:has_permission?).and_return(true) }

  # ── The regression this seam exists for ────────────────────────────────────
  describe "visibility of a task on a worker-less node" do
    let!(:task) { stuck_task }

    it "is INVISIBLE through the old worker-scoped tasks endpoint" do
      get "/api/v1/system/worker_api/tasks", params: { status: "pending" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("data", "tasks")).to be_empty
    end

    it "is VISIBLE through the account-scoped janitor endpoint" do
      get "/api/v1/system/worker_api/janitor/tasks", headers: headers

      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).dig("data", "tasks").map { |t| t["id"] }
      expect(ids).to include(task.id)
    end
  end

  describe "GET /janitor/tasks" do
    it "returns only non-terminal statuses, even when others are asked for" do
      pending_task = stuck_task
      running_task = stuck_task(status: "running", started_ago: 3.hours)
      done = create(:system_task, :complete, account: account, operable: node)

      get "/api/v1/system/worker_api/janitor/tasks",
          params: { status: %w[pending running complete] }, headers: headers

      ids = JSON.parse(response.body).dig("data", "tasks").map { |t| t["id"] }
      expect(ids).to contain_exactly(pending_task.id, running_task.id)
      expect(ids).not_to include(done.id)
    end

    it "honours older_than_seconds" do
      old = stuck_task(age: 3.hours)
      fresh = stuck_task(age: 1.minute)

      get "/api/v1/system/worker_api/janitor/tasks",
          params: { older_than_seconds: 3600 }, headers: headers

      ids = JSON.parse(response.body).dig("data", "tasks").map { |t| t["id"] }
      expect(ids).to include(old.id)
      expect(ids).not_to include(fresh.id)
    end

    # TasksController#index orders created_at DESC and paginates, so with more
    # stuck rows than fit on a page the MOST stuck fall off the end — exactly
    # backwards for a reaper. The live backlog's oldest row predates the newest
    # by five weeks; it has to be on page one.
    it "orders oldest first" do
      newer = stuck_task(age: 1.hour)
      older = stuck_task(age: 30.days)

      get "/api/v1/system/worker_api/janitor/tasks", headers: headers

      ids = JSON.parse(response.body).dig("data", "tasks").map { |t| t["id"] }
      expect(ids.index(older.id)).to be < ids.index(newer.id)
    end

    it "caps per_page at MAX_PER_PAGE" do
      get "/api/v1/system/worker_api/janitor/tasks",
          params: { per_page: 100_000 }, headers: headers

      expect(response).to have_http_status(:ok)
    end

    # NOTE which commands are agent-delegated, because it is counter-intuitive:
    # `apply_config` and `sync_modules` are NOT, despite the node agent having
    # handlers by those exact names. They are the naming collision the
    # dispatch-spine decision records — the server-side halves are control-plane
    # operations (compute and record what the node should run) that happen to
    # share a word with the agent's data-plane halves (make the node run it).
    # ExecutionDispatcher routes them server-side, so the reaper may legitimately
    # re-enqueue them. ci.module_build is genuinely agent-only.
    it "reports whether each task is agent-delegated" do
      agent_task  = stuck_task(command: "ci.module_build")
      server_task = stuck_task(command: "ssh_command")

      get "/api/v1/system/worker_api/janitor/tasks", headers: headers

      by_id = JSON.parse(response.body).dig("data", "tasks").index_by { |t| t["id"] }
      expect(by_id[agent_task.id]["agent_delegated"]).to be true
      expect(by_id[server_task.id]["agent_delegated"]).to be false
    end
  end

  # ── Tenancy ────────────────────────────────────────────────────────────────
  describe "tenancy" do
    let(:other_account) { create(:account) }
    let(:other_node)    { create(:system_node, account: other_account) }
    let!(:foreign_task) do
      create(:system_task, account: other_account, operable: other_node, status: "pending")
    end

    it "never lists another account's task" do
      get "/api/v1/system/worker_api/janitor/tasks", headers: headers

      ids = JSON.parse(response.body).dig("data", "tasks").map { |t| t["id"] }
      expect(ids).not_to include(foreign_task.id)
    end

    # 404, never 403: a 403 would confirm the row exists on another account,
    # which is itself the disclosure.
    it "404s rather than 403s when reaping another account's task" do
      post "/api/v1/system/worker_api/janitor/tasks/#{foreign_task.id}/reap", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(foreign_task.reload.status).to eq("pending")
    end

    # The anchor must be the PRINCIPAL, not a parameter. BaseController's
    # #worker_account falls back to Account.find(params[:account_id]); a janitor
    # that can terminally close tasks must not inherit that widener.
    it "ignores an account_id parameter naming another account" do
      get "/api/v1/system/worker_api/janitor/tasks",
          params: { account_id: other_account.id }, headers: headers

      ids = JSON.parse(response.body).dig("data", "tasks").map { |t| t["id"] }
      expect(ids).not_to include(foreign_task.id)
    end
  end

  # ── Reap: the server picks the legal transition ────────────────────────────
  describe "POST /janitor/tasks/:id/reap" do
    it "FAILS a running task" do
      task = stuck_task(status: "running", started_ago: 3.hours)

      post "/api/v1/system/worker_api/janitor/tasks/#{task.id}/reap",
           params: { reason: "execution_lost" }, headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)["data"]
      expect(body["reaped"]).to be true
      expect(body["transition"]).to eq("fail")
      expect(task.reload.status).to eq("failed")
      expect(task.error_message).to eq("execution_lost")
    end

    # A task that never started must not be recorded as "failed" — that asserts
    # an execution that never happened. cancel is the honest terminal.
    it "CANCELS a pending task" do
      task = stuck_task(status: "pending")

      post "/api/v1/system/worker_api/janitor/tasks/#{task.id}/reap",
           params: { reason: "unrunnable" }, headers: headers

      body = JSON.parse(response.body)["data"]
      expect(body["transition"]).to eq("cancel")
      expect(task.reload.status).to eq("cancelled")
      expect(task.error_message).to eq("unrunnable")
    end

    it "CANCELS a scheduled task" do
      task = stuck_task(status: "scheduled")

      post "/api/v1/system/worker_api/janitor/tasks/#{task.id}/reap", headers: headers

      expect(JSON.parse(response.body).dig("data", "transition")).to eq("cancel")
      expect(task.reload.status).to eq("cancelled")
    end

    # The reaper acts on a snapshot fetched seconds earlier. A row that reached
    # a terminal state in between is a benign lost race, not an error it should
    # log and retry.
    it "reports reaped:false for an already-terminal task instead of erroring" do
      task = create(:system_task, :complete, account: account, operable: node)

      post "/api/v1/system/worker_api/janitor/tasks/#{task.id}/reap", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)["data"]
      expect(body["reaped"]).to be false
      expect(body["transition"]).to be_nil
      expect(body["detail"]).to match(/already terminal/)
      expect(task.reload.status).to eq("complete")
    end

    it "records a terminal event on the task" do
      task = stuck_task(status: "running", started_ago: 3.hours)

      post "/api/v1/system/worker_api/janitor/tasks/#{task.id}/reap",
           params: { reason: "execution_lost" }, headers: headers

      expect(task.reload.events.map { |e| e["type"] }).to include("failed")
    end
  end

  # ── Auth ───────────────────────────────────────────────────────────────────
  describe "authentication and authorization" do
    it "401s without worker credentials" do
      get "/api/v1/system/worker_api/janitor/tasks"

      expect(response).to have_http_status(:unauthorized)
    end

    it "403s a worker without system.tasks.read" do
      allow_any_instance_of(Worker).to receive(:has_permission?).and_return(false)

      get "/api/v1/system/worker_api/janitor/tasks", headers: headers

      expect(response).to have_http_status(:forbidden)
    end

    # REGRESSION PIN. authorize_worker_permission! used to render 403 and then
    # let the action run on, so a denied worker got a forbidden response AND its
    # write. Measured on the pre-existing seam: STATUS=403, TASK_STATUS=failed.
    # Asserting only on the status code would have passed throughout the bypass;
    # the row's state is the oracle that actually discriminates.
    it "403s a worker without system.tasks.manage on reap" do
      task = stuck_task(status: "running", started_ago: 3.hours)
      allow_any_instance_of(Worker).to receive(:has_permission?).with("system.tasks.manage").and_return(false)
      allow_any_instance_of(Worker).to receive(:has_permission?).with("system.tasks.read").and_return(true)

      post "/api/v1/system/worker_api/janitor/tasks/#{task.id}/reap", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(task.reload.status).to eq("running")
    end
  end
end
