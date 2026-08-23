# frozen_string_literal: true

require "rails_helper"

# IMP-3855ff9908f2 — the heartbeat is where the agent's `verify:` PROBE
# outcome enters the platform.
#
# This file exists to prove the LINK, not the parsing: that the controller
# actually reads `module_verify_state` and hands it to the writer. A producer
# whose payload no server code reads is the half-lane shape this campaign
# exists to stop — and it is invisible to unit specs on either side, because
# both pass while the wire between them is cut.
#
# The oracle contract pinned here:
#
#   * a per-shell outcome is recorded as the agent OBSERVED it;
#   * absence of the block is absence — nothing is stamped, and nothing
#     renders as verified;
#   * a probe reported for only ONE shell is recorded as NOT MEASURED, never
#     as a pass. An agent that predates the probe runner sends no block at
#     all, which is the live shape across the fleet today.
RSpec.describe "Api::V1::System::NodeApi::Status#heartbeat — module verify state", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }

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

  let(:base_body) do
    { boot_id: "boot-verify-1", agent_version: "1.5.0-test", mount_state: "mounted" }
  end

  def post_heartbeat(extra = {})
    post "/api/v1/system/node_api/status/heartbeat",
         params: base_body.merge(extra), headers: headers, as: :json
  end

  def recorded
    instance.reload.config[System::ModuleVerifyStateWriter::CONFIG_KEY]
  end

  # The exact wire shape from agent/internal/probe/probe.go — ModuleReport
  # nesting ProbeReport nesting ShellResult. Per-shell FACTS only; there is
  # deliberately no roll-up field on the wire.
  def wire_module(probes:, module_id: "mod-a", module_name: "gh")
    {
      module_id: module_id, module_name: module_name,
      declared_count: probes.size,
      observed_at: Time.current.utc.iso8601,
      probes: probes
    }
  end

  def wire_probe(shells:, name: "gh-binary", command: "gh", expected: "/usr/local/bin/gh")
    { name: name, command: command, expected: expected, shells: shells }
  end

  def wire_shell(shell, status:, resolved: "", message: "")
    { shell: shell, status: status, resolved: resolved, message: message }
  end

  it "acknowledges a heartbeat with no verify block and stamps NOTHING" do
    post_heartbeat
    expect(response).to have_http_status(:ok)
    expect(recorded).to be_nil
  end

  it "records a clean two-shell observation" do
    post_heartbeat(module_verify_state: [ wire_module(probes: [ wire_probe(shells: [
      wire_shell("login", status: "pass", resolved: "/usr/local/bin/gh"),
      wire_shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
    ]) ]) ])

    expect(response).to have_http_status(:ok)
    probe = recorded.dig("modules", 0, "probes", 0)
    expect(probe["status"]).to eq("pass")
    expect(probe["shells_covered"]).to be(true)
  end

  # The incident, arriving over the wire: the name resolved in both shells,
  # and the login one resolved to the wrong file.
  it "records a shadowed binary with the path the node actually resolved" do
    post_heartbeat(module_verify_state: [ wire_module(probes: [ wire_probe(shells: [
      wire_shell("login", status: "fail", resolved: "/usr/bin/gh",
                 message: "resolved to /usr/bin/gh, manifest declares /usr/local/bin/gh"),
      wire_shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
    ]) ]) ])

    probe = recorded.dig("modules", 0, "probes", 0)
    expect(probe["status"]).to eq("fail")
    expect(probe["shells"].find { |s| s["shell"] == "login" }["resolved"]).to eq("/usr/bin/gh")
  end

  # An agent that only ran one shell has not tested the divergence that broke
  # VM-9000. The server refuses to score it as passing regardless of what the
  # shell it DID run reported.
  it "refuses to score a one-shell report as passing" do
    post_heartbeat(module_verify_state: [ wire_module(probes: [ wire_probe(shells: [
      wire_shell("login", status: "pass", resolved: "/usr/local/bin/gh")
    ]) ]) ])

    probe = recorded.dig("modules", 0, "probes", 0)
    expect(probe["status"]).to eq("unknown")
    expect(probe["shells_covered"]).to be(false)
  end

  it "never lets an ingest failure bounce the heartbeat" do
    allow(System::ModuleVerifyStateWriter).to receive(:write!).and_raise(StandardError, "boom")
    post_heartbeat(module_verify_state: [ wire_module(probes: []) ])
    expect(response).to have_http_status(:ok)
    expect(instance.reload.last_heartbeat_at).to be_present
  end

  it "leaves the sibling telemetry keys alone" do
    instance.update!(config: instance.config.merge("sdwan_state" => { "keep" => "me" }))
    post_heartbeat(module_verify_state: [ wire_module(probes: []) ])
    expect(instance.reload.config["sdwan_state"]).to eq({ "keep" => "me" })
  end
end
