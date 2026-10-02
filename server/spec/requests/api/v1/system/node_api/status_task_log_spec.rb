# frozen_string_literal: true

require "rails_helper"

# IMP-dbc22946e05c — the agent uploads a task's full scrubbed log through the
# node API. Only the task's own instance may upload, only for a task it is
# running or has finished, and nothing but the redacted, capped text is stored.
RSpec.describe "Api::V1::System::NodeApi::Status#upload_task_log", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }
  let(:other_instance) { create(:system_node_instance, node: node, status: "running") }

  def cert_for(inst)
    System::NodeCertificate.create!(
      node_instance: inst, serial: SecureRandom.hex(16), subject: "CN=#{inst.id}",
      not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let!(:cert)       { cert_for(instance) }
  let!(:other_cert) { cert_for(other_instance) }

  def headers_for(inst)
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{inst.id}")) }
  end

  def make_task(inst, status: "running")
    System::Task.create!(account: account, command: "ci.module_build", status: status,
                         operable_type: "System::NodeInstance", operable_id: inst.id)
  end

  def upload(task, body, as: instance)
    post "/api/v1/system/node_api/status/tasks/#{task.id}/log", params: body, headers: headers_for(as), as: :json
  end

  it "stores the uploaded log, redacted, for a running task of this instance" do
    task = make_task(instance)

    upload(task, { log: "build step\npassword=FAKEhunter2FAKE\nok\n", original_bytes: 40, truncated: false })

    expect(response).to have_http_status(:ok)
    row = System::TaskLog.find_by!(task_id: task.id)
    expect(row.node_instance_id).to eq(instance.id)
    expect(row.content).to include("build step", "ok")
    expect(row.content).not_to include("FAKEhunter2FAKE")
  end

  it "accepts a log for a task that already finished (the failure path uploads before it reports)" do
    task = make_task(instance, status: "failed")

    upload(task, { log: "late\n" })

    expect(response).to have_http_status(:ok)
    expect(System::TaskLog.where(task_id: task.id)).to exist
  end

  it "does not let one instance write another instance's task log, and creates no row" do
    task = make_task(other_instance)

    upload(task, { log: "mine now\n" }, as: instance)

    expect(response).to have_http_status(:not_found)
    expect(System::TaskLog.where(task_id: task.id)).to be_empty
  end

  it "refuses a task that has not started (pending) and creates no row" do
    task = make_task(instance, status: "pending")

    upload(task, { log: "early\n" })

    expect(response).to have_http_status(:unprocessable_entity)
    expect(System::TaskLog.where(task_id: task.id)).to be_empty
  end

  it "caps an oversize upload, keeps its end, and states the truncation" do
    stub_const("System::TaskLogStore::MAX_BYTES", 64)
    task = make_task(instance)

    upload(task, { log: ("z" * 500) + "TAIL\n" })

    expect(response).to have_http_status(:ok)
    row = System::TaskLog.find_by!(task_id: task.id)
    expect(row.byte_size).to be <= 64
    expect(row.content).to end_with("TAIL\n")
    expect(row.truncated).to be(true)
  end

  it "refuses a body past the upload limit before storing anything" do
    stub_const("System::TaskLogStore::MAX_UPLOAD_BYTES", 100)
    task = make_task(instance)

    upload(task, { log: "z" * 500 })

    expect(response).to have_http_status(:payload_too_large)
    expect(System::TaskLog.where(task_id: task.id)).to be_empty
  end

  it "does not 500 on a hostile original_bytes" do
    task = make_task(instance)

    upload(task, { log: "ok\n", original_bytes: { "a" => 1 } })
    expect(response).to have_http_status(:ok)

    upload(task, { log: "ok\n", original_bytes: 10**30 })
    expect(response).to have_http_status(:ok)
  end

  it "rejects a body with no log string and creates no row" do
    task = make_task(instance)

    upload(task, { log: nil })

    expect(response).to have_http_status(:unprocessable_entity)
    expect(System::TaskLog.where(task_id: task.id)).to be_empty
  end
end
