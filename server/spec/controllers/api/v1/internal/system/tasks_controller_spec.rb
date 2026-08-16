# frozen_string_literal: true

require "rails_helper"

# IMP-45e854f605dc — the internal system task API must not serve one account's
# tasks to another account's worker.
#
# NOTE ON `with_routing`: this controller family is NOT mounted. `rails routes`
# yields 2931 routes, 270 under `api/v1/internal/`, and ZERO under
# `api/v1/internal/system/` — no routes.rb (core, system, marketing,
# supply-chain) draws it, and it has never been drawn since the extension's
# initial import. The only would-be caller is the worker's
# OperationReportingConcern, which PATCHes `/api/v1/internal/system/operations/:id`
# and swallows the resulting 404 in a `rescue StandardError`. So the scoping
# defect is LATENT, not live. We draw the routes for the duration of each
# example so the guard exercises the real controller + real mTLS auth without
# widening the mounted attack surface.
RSpec.describe "Api::V1::Internal::System::Tasks", type: :request do
  let(:account)       { create(:account) }
  let(:other_account) { create(:account) }

  # Account worker (is_system: false) — constrained to its own account.
  let(:worker) { create(:worker, account: account) }

  def headers_for(w)
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{w.node_instance_id}")) }
  end

  let(:node)       { create(:system_node, account: account) }
  let(:other_node) { create(:system_node, account: other_account) }

  let!(:own_task)   { create(:system_task, account: account, operable: node, command: "sync") }
  let!(:other_task) { create(:system_task, account: other_account, operable: other_node, command: "sync") }

  around do |example|
    with_routing do |set|
      set.draw do
        namespace :api do
          namespace :v1 do
            namespace :internal do
              namespace :system do
                resources :tasks, only: %i[index show update] do
                  member { post :events }
                end
              end
            end
          end
        end
      end
      example.run
    end
  end

  describe "GET /api/v1/internal/system/tasks" do
    it "does not return another account's task when the caller supplies that account's operable" do
      get "/api/v1/internal/system/tasks",
          params: { operable_type: "System::Node", operable_id: other_node.id },
          headers: headers_for(worker)

      expect(response).to have_http_status(:ok)
      ids = json_response_data["tasks"].map { |t| t["id"] }
      expect(ids).not_to include(other_task.id)
    end

    # Control: the refusal above must not be over-tightening. An assertion that
    # only checks the refusal cannot tell "scoped correctly" from "returns nothing".
    it "still returns the caller's own account's tasks" do
      get "/api/v1/internal/system/tasks",
          params: { operable_type: "System::Node", operable_id: node.id },
          headers: headers_for(worker)

      expect(response).to have_http_status(:ok)
      ids = json_response_data["tasks"].map { |t| t["id"] }
      expect(ids).to include(own_task.id)
    end

    # Control: the single global system worker (workers.is_system, uniquely
    # indexed) processes every account's work by design — the same rule core
    # states at Api::V1::Worker::WorkerBaseController#account_scoped. Scoping
    # must not constrain it.
    it "leaves the system worker unconstrained across accounts" do
      system_worker = create(:worker, account: account, is_system: true)

      get "/api/v1/internal/system/tasks",
          params: { operable_type: "System::Node", operable_id: other_node.id },
          headers: headers_for(system_worker)

      expect(response).to have_http_status(:ok)
      ids = json_response_data["tasks"].map { |t| t["id"] }
      expect(ids).to include(other_task.id)
    end
  end

  describe "GET /api/v1/internal/system/tasks/:id" do
    it "does not disclose another account's task by id" do
      get "/api/v1/internal/system/tasks/#{other_task.id}", headers: headers_for(worker)

      expect(response).to have_http_status(:not_found)
    end

    it "still returns the caller's own task by id" do
      get "/api/v1/internal/system/tasks/#{own_task.id}", headers: headers_for(worker)

      expect(response).to have_http_status(:ok)
      expect(json_response_data["id"]).to eq(own_task.id)
    end
  end

  # update and events resolve through the same set_operation, so the exposure
  # was mutation of a foreign account's row, not merely disclosure of it. That
  # is the claim that carries the severity, so it gets its own examples rather
  # than riding on the shared mechanism.
  describe "writes against another account's task" do
    it "refuses to transition it" do
      expect {
        patch "/api/v1/internal/system/tasks/#{other_task.id}",
              params: { status: "running" }, headers: headers_for(worker)
      }.not_to change { other_task.reload.status }

      expect(response).to have_http_status(:not_found)
    end

    it "refuses to append an event to it" do
      expect {
        post "/api/v1/internal/system/tasks/#{other_task.id}/events",
             params: { event_type: "info", message: "injected" }, headers: headers_for(worker)
      }.not_to change { other_task.reload.events.size }

      expect(response).to have_http_status(:not_found)
    end

    it "still transitions the caller's own task" do
      patch "/api/v1/internal/system/tasks/#{own_task.id}",
            params: { status: "running" }, headers: headers_for(worker)

      expect(response).to have_http_status(:ok)
      expect(own_task.reload.status).to eq("running")
    end
  end
end
