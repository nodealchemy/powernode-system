# frozen_string_literal: true

require "rails_helper"

# IMP-9ce0ed39c557 — the REST operator door onto System::Executors::OutOfBandExec.
RSpec.describe "Api::V1::System::NodeInstances#out_of_band_exec", type: :request do
  let(:account)       { create(:account) }
  let(:control_user)  { user_with_permissions("system.instances.control", account: account) }
  let(:read_user)     { user_with_permissions("system.instances.read", account: account) }
  let(:node)          { create(:system_node, account: account) }
  let!(:instance)     { create(:system_node_instance, :running, :with_ssh_host_key, node: node, account: account) }

  let(:ssh_result) do
    ::System::Runtime::Result.ok(data: { stdout: "ok", stderr: "", exit_code: 0, timed_out: false, truncated: false })
  end

  # Security review finding S2 — self_hosting_node_id must be CONFIGURED for
  # out-of-band-exec to run at all (fail-closed when unset). A decoy,
  # unrelated to `node`/`instance`, so ordinary tests are unaffected.
  let(:self_hosting_node) { create(:system_node, account: create(:account)) }

  before do
    allow(::System::SshExecutionService).to receive(:execute_bounded).and_return(ssh_result)
    ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY,
                       self_hosting_node.id, setting_type: "string")
  end

  # A worker HOLDING system.instances.control — the strongest form of the S3
  # test: if the worker had no permission at all, #require_permission would
  # refuse first and the new worker/node-cert guard in
  # #gate_out_of_band_exec would never actually be reached.
  def worker_headers
    worker = create(:worker, status: "active", account: account)
    role = ::Role.find_or_create_by!(name: "oob_exec_test_worker_role") do |r|
      r.role_type = "user"
      r.display_name = "OOB Exec Test Worker Role"
    end
    role.role_permissions.find_or_create_by!(permission_name: "system.instances.control")
    # NOT #assign_role — Worker#valid_worker_role? only allows a "user"-type
    # role whose NAME is on its own explicit allowlist (member/manager/
    # billing_admin/developer/owner/ci_worker), so a fresh test-only role
    # name is silently REFUSED (returns false, no raise) rather than
    # assigned. Building the join row directly is test-only scaffolding to
    # exercise the permission check itself; it is not a statement that
    # workers should generally be assignable to arbitrary roles.
    worker.worker_roles.find_or_create_by!(role: role)

    jwt = ::Security::JwtService.encode(
      { sub: worker.id, type: "worker", version: ::Security::JwtService::CURRENT_TOKEN_VERSION }
    )
    { "Authorization" => "Bearer #{jwt}", "Content-Type" => "application/json" }
  end

  def exec!(headers:, command: "uptime", **extra)
    post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/out_of_band_exec",
         params: { command: command }.merge(extra), headers: headers, as: :json
  end

  it "returns 401 without auth" do
    post "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}/out_of_band_exec", params: { command: "uptime" }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 403 without system.instances.control" do
    exec!(headers: auth_headers_for(read_user))
    expect(response).to have_http_status(:forbidden)
  end

  it "returns 422 for a blank command, never calling SshExecutionService" do
    exec!(headers: auth_headers_for(control_user), command: "")

    expect(response).to have_http_status(:unprocessable_content)
    expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
  end

  it "parks an approval by default and never calls SshExecutionService" do
    exec!(headers: auth_headers_for(control_user))

    expect(response).to have_http_status(:accepted)
    body = response.parsed_body
    expect(body["data"]["pending"]).to be true
    expect(::System::SshExecutionService).not_to have_received(:execute_bounded)

    deferred = ::Ai::DeferredOperation.find_by(
      account_id: account.id, action_category: ::System::OutOfBandExecService::ACTION_CATEGORY
    )
    expect(deferred).to be_present
    expect(deferred.executor_class).to eq("System::Executors::OutOfBandExec")
    expect(deferred.params["pinned_ip"]).to eq(instance.ssh_ip_address)
    # Review finding R2-1 — the approver must see WHERE this will run, not
    # just the instance's name.
    expect(deferred.description).to include(instance.ssh_ip_address)
    expect(deferred.params["call_origin"]).to be_nil

    # Security review finding S1 — requires_human_session marks the request
    # regardless of resolved policy, so no tool door can decide it either.
    expect(deferred.approval_request.requires_human_session?).to be true
    expect(body["data"]["requires_human_session"]).to be true
  end

  # Security review finding S1 — human_only wins over ANY resolved policy.
  # This replaces the pre-security-review version of this test, which
  # asserted the OPPOSITE (ran inline, HTTP 200): requires_human_session
  # forces Ai::AutonomyGate#evaluate to require_approval regardless of what
  # the policy service resolves.
  it "still parks under auto_approve rather than running inline" do
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )

    exec!(headers: auth_headers_for(control_user))

    expect(response).to have_http_status(:accepted)
    body = response.parsed_body
    expect(body["data"]["pending"]).to be true
    expect(body["data"]["requires_human_session"]).to be true
    expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
  end

  # Review finding C2-5 — :proceed is truly unreachable now (requires_human_session
  # forces require_approval regardless of policy), so the controller REFUSES
  # it rather than rendering a fabricated success nobody confirmed (mirrors
  # BaseTool's identical arm). Replaces the earlier "renders stdout/stderr
  # from a :proceed gate result" test, which exercised code this round
  # deliberately deleted.
  it "refuses rather than proceeding, if the gate ever returned :proceed for this human_only category" do
    proceed_result = ::Ai::AutonomyGate::Result.new(
      decision: :proceed,
      result: { success: true, data: { success: true, exit_code: 0, timed_out: false, truncated: false,
                                       stdout: "ok", stderr: "" } }
    )
    allow(::Ai::AutonomyGate).to receive(:evaluate).and_return(proceed_result)

    exec!(headers: auth_headers_for(control_user))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to match(/person's confirmation/i)
  end

  it "refuses with a 500 on an unknown gate decision, rather than silently rendering nothing" do
    unknown_result = ::Ai::AutonomyGate::Result.new(decision: :something_new)
    allow(::Ai::AutonomyGate).to receive(:evaluate).and_return(unknown_result)

    exec!(headers: auth_headers_for(control_user))

    expect(response).to have_http_status(:internal_server_error)
    expect(response.parsed_body["error"]).to match(/unknown gate decision/i)
  end

  # Security review finding S3 — a worker or node-cert principal must never
  # even REQUEST this, human_only approval notwithstanding.
  it "refuses a worker/node-cert principal outright, never parking" do
    exec!(headers: worker_headers)

    expect(response).to have_http_status(:forbidden)
    expect(::Ai::DeferredOperation.where(account: account)).to be_empty
    expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
  end

  # Security review finding S2 — fails closed, unlike SelfManagementFence's
  # own inert-by-default for every other consumer.
  it "returns 422 when self_hosting_node_id has never been configured, never parking" do
    ::SiteSetting.where(key: ::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY).delete_all

    exec!(headers: auth_headers_for(control_user))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to match(/self_hosting_node_id/i)
    expect(::Ai::DeferredOperation.where(account: account)).to be_empty
  end

  it "returns 422 for a loopback SSH address, never parking" do
    instance.update_columns(private_ip_address: "127.0.0.1", vpn_ip_address: nil, public_ip_address: nil)

    exec!(headers: auth_headers_for(control_user))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to match(/loopback/i)
    expect(::Ai::DeferredOperation.where(account: account)).to be_empty
  end

  # Security review, command-text decision — refused before parking, and
  # never echoed in the error.
  it "returns 422 for a secret-shaped command, without echoing it" do
    exec!(headers: auth_headers_for(control_user), command: "export PASSWORD=hunter2-secret-pw")

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to match(/secret-shaped/i)
    expect(response.parsed_body["error"]).not_to include("hunter2-secret-pw")
    expect(::Ai::DeferredOperation.where(account: account)).to be_empty
  end

  # Review finding #5 — mirrors the MCP tool's identical check: parking with
  # a blank ssh_ip_address would gate a nil pinned_ip, which
  # OutOfBandExecService's own repoint-refusal can never fire against later.
  it "returns 422 when the instance has no SSH IP address to pin, never parking" do
    instance.update_columns(vpn_ip_address: nil, private_ip_address: nil, public_ip_address: nil)

    exec!(headers: auth_headers_for(control_user))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to match(/no SSH IP/i)
    expect(::Ai::DeferredOperation.where(account: account)).to be_empty
    expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
  end

  it "refuses this control plane's own self-hosting node before gating (INV-1), never parking" do
    ::SiteSetting.set(::System::Autonomy::SelfManagementFence::SELF_HOSTING_NODE_ID_KEY, node.id, setting_type: "string")

    exec!(headers: auth_headers_for(control_user))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to match(/INV-1|self-management/i)
    expect(::Ai::DeferredOperation.where(account: account)).to be_empty
    expect(::System::SshExecutionService).not_to have_received(:execute_bounded)
  end

  it "refuses a foreign account's instance id with a 404, never leaking the row" do
    other_account = create(:account)
    foreign = create(:system_node_instance, :running, node: create(:system_node, account: other_account))

    post "/api/v1/system/nodes/#{node.id}/node_instances/#{foreign.id}/out_of_band_exec",
         params: { command: "uptime" }, headers: auth_headers_for(control_user), as: :json

    expect(response).to have_http_status(:not_found)
  end
end
