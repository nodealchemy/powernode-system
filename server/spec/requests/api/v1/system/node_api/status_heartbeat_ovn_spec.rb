# frozen_string_literal: true

require "rails_helper"

# IMP-57e9a90598ee — the heartbeat is where the agent's OVN NB replay
# observation enters the platform.
#
# Before this, agent/internal/sdwan/manager.go's OvnNbStatus() had ZERO callers
# and its doc comment falsely claimed "the heartbeat integration nests this into
# the SDWAN status payload". The observation was computed on every tick and
# thrown away, which is why mark_degraded! / readopt! on Sdwan::OvnDeployment
# had no sensor that owned them.
RSpec.describe "Api::V1::System::NodeApi::Status#heartbeat — OVN NB observation", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance) do
    create(:system_node_instance, node: node, status: "running", network_profile: "heavyweight")
  end

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance,
      serial:         SecureRandom.hex(16),
      subject:        "CN=#{instance.id}",
      not_before:     1.hour.ago,
      not_after:      90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:headers) do
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }
  end

  let!(:deployment) do
    create(:sdwan_ovn_deployment, account: account, status: "active", activated_at: 1.hour.ago)
  end

  let(:base_body) do
    { boot_id: "boot-ovn-1", agent_version: "1.0.0-test", mount_state: "mounted" }
  end

  before do
    allow(Sdwan::Ovn::NbProbe).to receive(:probe_cached)
      .and_return(Sdwan::Ovn::NbProbe::Result.not_measured(reason: "tls_probe_unsupported"))
  end

  def post_heartbeat(extra = {})
    post "/api/v1/system/node_api/status/heartbeat",
         params: base_body.merge(extra), headers: headers, as: :json
  end

  it "degrades the deployment when the agent reports a failed NB replay" do
    post_heartbeat(
      sdwan_ovn_state: {
        deployment_id:    deployment.id,
        nb_db_endpoint:   deployment.nb_db_endpoint,
        plan_commands:    5,
        applied_commands: 2,
        last_replay_at:   Time.current.utc.iso8601,
        last_error:       "ovn-nbctl: connection timed out"
      }
    )

    expect(response).to have_http_status(:ok)
    expect(deployment.reload.status).to eq("degraded")
  end

  it "readopts a degraded deployment when the same chassis reports a full replay" do
    post_heartbeat(
      sdwan_ovn_state: {
        deployment_id: deployment.id, plan_commands: 5, applied_commands: 0,
        last_error: "no route to host"
      }
    )
    expect(deployment.reload.status).to eq("degraded")

    post_heartbeat(
      sdwan_ovn_state: {
        deployment_id: deployment.id, plan_commands: 5, applied_commands: 5
      }
    )

    expect(deployment.reload.status).to eq("active")
  end

  it "does not touch the deployment when the heartbeat carries no OVN block" do
    post_heartbeat

    expect(response).to have_http_status(:ok)
    expect(deployment.reload.status).to eq("active")
  end

  it "acknowledges the heartbeat even when the reconciler blows up — telemetry must not bounce" do
    allow(Sdwan::Ovn::DeploymentReconciler).to receive(:reconcile!).and_raise(StandardError, "boom")

    post_heartbeat

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "acknowledged")).to be(true)
  end

  it "ignores an OVN block from a lightweight instance" do
    instance.update_columns(network_profile: "lightweight")
    deployment.update_columns(status: "bootstrapping", bootstrapped_at: 1.hour.ago)

    post_heartbeat(
      sdwan_ovn_state: {
        deployment_id: deployment.id, plan_commands: 5, applied_commands: 5
      }
    )

    expect(deployment.reload.status).to eq("bootstrapping")
  end

  # IMP-3bc311f9bc5c — the OVN observation is a BODY field. Rails merges the
  # query string over the parsed body, so before the fix a query-string block
  # reached the reconciler as if the agent had reported it. This lane is the
  # one that drives an AASM lifecycle (degrade / readopt), so a fabricated
  # observation here moves a real deployment's state. The oracle is the
  # deployment ROW, not the response status.
  it "reads the OVN block from the body, never from the query string" do
    post "/api/v1/system/node_api/status/heartbeat" \
         "?sdwan_ovn_state[deployment_id]=#{deployment.id}" \
         "&sdwan_ovn_state[plan_commands]=5" \
         "&sdwan_ovn_state[applied_commands]=2" \
         "&sdwan_ovn_state[last_error]=fabricated",
         params: base_body, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(deployment.reload.status).to eq("active")
  end
end
