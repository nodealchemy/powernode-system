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
  let!(:task) { create(:system_task, account: account, operable: node, command: "sync_modules", status: "pending") }

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
      foreign = create(:system_task, account: other_account, operable: foreign_node, command: "sync_modules")
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
      foreign = create(:system_task, account: other_account, operable: foreign_node, command: "sync_modules")
      get "/api/v1/system/tasks/#{foreign.id}", headers: auth_headers_for(read_user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/system/tasks (create — gated through Ai::AutonomyGate)" do
    let(:create_params) do
      { task: { command: "sync_modules", operable_type: "System::Node", operable_id: node.id } }
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

    # IMP-973670faeba9 — the live reachability of the unanchored operable.
    # The gate opened with no source anchors and the executor mass-assigned the
    # caller's operable_type/operable_id, so this route let a caller attach
    # another account's record to a task running under their own account.
    context "when the caller names a record it does not own as the operable" do
      let(:foreign_node) { create(:system_node, account: other_account) }
      let(:own_node)     { create(:system_node, account: account) }

      def post_operable(type:, id:)
        post "/api/v1/system/tasks",
             params: { task: { command: "sync_modules", operable_type: type, operable_id: id } }.to_json,
             headers: auth_headers_for(create_user).merge("Content-Type" => "application/json")
      end

      def last_operation
        ::Ai::DeferredOperation.where(executor_class: "System::Executors::ExecuteTask")
                               .order(created_at: :desc).first
      end

      # The seeded policy defers this route (202), so the executor runs at
      # APPROVAL time, not during the request — asserting on the response alone
      # would pass vacuously against the unfixed code, because nothing has
      # executed yet. Replaying the operation for real is the only way to reach
      # the executor, and it is exactly the moment the recorded source anchors
      # exist to be re-checked.
      def replay!(operation)
        operation.execute_now!
        nil
      rescue StandardError => e
        e
      end

      # Control: proves the replay really does create tasks, so the refusals
      # below are not passing for want of a working path. Uses its own node —
      # the file-level `let!(:task)` already occupies (node, "sync").
      it "creates the task when the operable is its own" do
        post_operable(type: "System::Node", id: own_node.id)
        error = replay!(last_operation)

        expect(error).to be_nil, "the in-account replay failed: #{error&.message}"
        expect(account.system_tasks.where(operable_type: "System::Node", operable_id: own_node.id))
          .to exist, "the in-account create path no longer works — the refusals below prove nothing"
      end

      # Defense 1: the anchors the gate had been opened without.
      it "records the operable as the operation's source so the replay can re-anchor it" do
        post_operable(type: "System::Node", id: foreign_node.id)
        operation = last_operation

        expect(operation.source_type).to eq("System::Node")
        expect(operation.source_id).to eq(foreign_node.id),
                                       "the gate opened with no source anchors — assert_source_within_account! skips entirely"
      end

      it "creates no task against the foreign record, even once approved" do
        post_operable(type: "System::Node", id: foreign_node.id)
        error = replay!(last_operation)

        planted = ::System::Task.where(operable_type: "System::Node", operable_id: foreign_node.id)
        expect(planted.count).to eq(0),
                                 "POST /api/v1/system/tasks attached account #{other_account.id}'s node to a task: " \
                                 "#{planted.map { |t| "#{t.id}(account #{t.account_id})" }.inspect}"
        expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
      end

      it "refuses without echoing the owning account back to the caller" do
        post_operable(type: "System::Node", id: foreign_node.id)
        error = replay!(last_operation)

        expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
        expect(error.message).not_to include(other_account.id),
                                     "the refusal names the victim's account — a working cross-tenant ownership oracle"
      end

      # Account is in-account by construction, so the source re-anchor passes it
      # through: the allowlist is the only thing that can refuse this one.
      it "refuses a model that is not a task operable at all" do
        post_operable(type: "Account", id: account.id)
        error = replay!(last_operation)

        expect(::System::Task.where(operable_type: "Account").count).to eq(0),
                                                                        "an arbitrary model was attached as a task operable"
        expect(error).to be_a(::System::Task::BadOperableType)
      end
    end

    it "honors idempotency_key — duplicate POST returns the existing task" do
      key = "spec-idem-#{SecureRandom.hex(3)}"
      existing = create(:system_task, account: account, operable: node, command: "sync_modules", idempotency_key: key)
      post "/api/v1/system/tasks",
           params: { task: { command: "sync_modules", operable_type: "System::Node",
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
      running = create(:system_task, account: account, operable: node, command: "sync_modules", status: "complete")
      post "/api/v1/system/tasks/#{running.id}/cancel",
           headers: auth_headers_for(control_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content).or have_http_status(:unprocessable_content)
    end
  end

  # IMP-8153d1952ff8 — the AASM abort event (legal from :running) existed but
  # was deliberately unexposed, leaving operators with no recourse on a wedged
  # provision/build/ssh task short of the hourly reaper's 60-min threshold.
  describe "POST /api/v1/system/tasks/:id/abort" do
    let!(:running_task) { create(:system_task, account: account, operable: node, command: "ssh_command", status: "running", started_at: Time.current) }

    it "returns 403 without control perm" do
      post "/api/v1/system/tasks/#{running_task.id}/abort",
           headers: auth_headers_for(read_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:forbidden)
    end

    it "aborts a running task" do
      post "/api/v1/system/tasks/#{running_task.id}/abort",
           params: { reason: "operator abort" }.to_json,
           headers: auth_headers_for(control_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      running_task.reload
      expect(running_task.status).to eq("aborted")
      expect(running_task.error_message).to eq("operator abort")
    end

    it "returns 422 when the task is not abortable (state-machine guard)" do
      post "/api/v1/system/tasks/#{task.id}/abort",
           headers: auth_headers_for(control_user).merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
