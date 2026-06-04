# frozen_string_literal: true

require "rails_helper"

# node_api task lifecycle: the agent's task loop acknowledges a pending task,
# executes it, then completes it. acknowledge MUST transition pending -> running
# so the subsequent complete (which requires running) succeeds. Surfaced by the
# live A2A execution-loop proof: a2a_call tasks executed but never completed
# because acknowledge only logged an event and left the task pending.
RSpec.describe "Api::V1::System::NodeApi::Status task lifecycle", type: :request do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance, serial: SecureRandom.hex(16), subject: "CN=#{instance.id}",
      not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) { { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) } }
  let(:task) { System::Task.create!(account: account, operable: instance, command: "a2a_call", status: "pending") }

  it "acknowledge transitions pending -> running, then complete succeeds" do
    post "/api/v1/system/node_api/status/tasks/#{task.id}/acknowledge", headers: headers
    expect(response).to have_http_status(:ok)
    expect(task.reload.status).to eq("running")

    post "/api/v1/system/node_api/status/tasks/#{task.id}/complete",
         params: { result: { "ok" => true } }.to_json,
         headers: headers.merge("Content-Type" => "application/json")
    expect(response).to have_http_status(:ok)
    expect(task.reload.status).to eq("complete")
    completed = task.events.find { |e| e["type"] == "completed" }
    expect(completed["result"]).to eq({ "ok" => true })
  end

  it "complete is rejected from a never-acknowledged (pending) task" do
    post "/api/v1/system/node_api/status/tasks/#{task.id}/complete",
         params: {}.to_json, headers: headers.merge("Content-Type" => "application/json")
    expect(response).not_to have_http_status(:ok)
    expect(task.reload.status).to eq("pending")
  end
end
