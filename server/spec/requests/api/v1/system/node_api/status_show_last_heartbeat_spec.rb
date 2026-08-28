# frozen_string_literal: true

require "rails_helper"

# IMP-51e13639258d — GET /status served last_heartbeat out of a config key that
# nothing writes.
#
# Heartbeats persist to the last_heartbeat_at COLUMN via
# System::NodeInstance#record_heartbeat!. A grep for the config key
# "last_heartbeat" across server/ and extensions/system/server/ returns exactly
# one hit: the read in this serializer. So the field was permanently null on
# every instance, including one heartbeating every 30 seconds.
#
# The cost lands precisely where the endpoint is most trusted: an operator or
# runbook diagnosing a node sees last_heartbeat: null on a healthy node and
# concludes heartbeats are not landing. Inverted evidence during outage triage.
RSpec.describe "Api::V1::System::NodeApi::Status#show last_heartbeat", type: :request do
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

  def body = JSON.parse(response.body)

  it "reports the heartbeat an instance actually recorded" do
    beat_at = 30.seconds.ago
    instance.update_columns(last_heartbeat_at: beat_at)

    get "/api/v1/system/node_api/status", headers: headers

    expect(response).to have_http_status(:ok)
    reported = body.dig("data", "instance", "last_heartbeat")

    expect(reported).to be_present,
                        "a node that heartbeated 30s ago reported last_heartbeat: null — " \
                        "inverted evidence for anyone triaging this node"
    expect(Time.iso8601(reported)).to be_within(1.second).of(beat_at)
  end

  # THE WRITE PATH, not just the read. The example above sets the column with
  # update_columns, so on its own it pins "the serializer reads
  # last_heartbeat_at" and NOT "a heartbeat writes last_heartbeat_at". If the
  # heartbeat's persistence ever moved — a new column, a jsonb document — that
  # example stays green while this field goes stale and then frozen, which is a
  # worse lie than the null it replaced. Drive the real endpoint instead.
  it "reports a heartbeat that arrived through the heartbeat endpoint" do
    instance.update_columns(last_heartbeat_at: nil)

    post "/api/v1/system/node_api/status/heartbeat",
         params: { boot_id: SecureRandom.uuid, agent_version: "test", uptime_seconds: 42 }.to_json,
         headers: headers.merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:ok)

    get "/api/v1/system/node_api/status", headers: headers

    expect(response).to have_http_status(:ok)
    reported = body.dig("data", "instance", "last_heartbeat")
    expect(reported).to be_present
    expect(Time.iso8601(reported)).to be_within(30.seconds).of(Time.current)
  end

  it "reports null only when the instance has genuinely never heartbeated" do
    instance.update_columns(last_heartbeat_at: nil)

    get "/api/v1/system/node_api/status", headers: headers

    expect(response).to have_http_status(:ok)
    expect(body.dig("data", "instance", "last_heartbeat")).to be_nil
  end
end
