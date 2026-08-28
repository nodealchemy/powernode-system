# frozen_string_literal: true

require "rails_helper"

# IMP-68d71157b68e — #report read-modify-writes the WHOLE config document.
#
# NodeInstance#config is written from several independent request cycles: the
# operator API, this status endpoint, and the per-heartbeat telemetry writers
# (System::BootLkgStateWriter, System::ModuleVerifyStateWriter,
# Sdwan::AgentApplyStateWriter). Those three defend themselves with a
# jsonb_set UPDATE that never reads the rest of the document —
# BootLkgStateWriter#merge_config_key!'s own comment names "the status report
# endpoint" as a writer it is guarding against.
#
# #report never got that treatment: it loads config into memory, merges two
# keys, and writes the whole jsonb back. Anything another writer stored in the
# interval is erased.
RSpec.describe "Api::V1::System::NodeApi::Status#report config clobber", type: :request do
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

  # The telemetry documents the heartbeat writers own, already on the row.
  before do
    System::NodeInstance.where(id: instance.id).update_all(
      "config = '#{{
        'boot_lkg' => { 'arm_state' => 'armed' },
        'module_verify_state' => { 'ok' => true },
        'sdwan_state' => { 'applied' => true }
      }.to_json}'::jsonb"
    )
  end

  # THE RACE, made deterministic. A concurrent writer lands between the moment
  # #report loads the instance and the moment it saves. Simulated by making the
  # controller's in-memory copy stale — which is exactly the state a real
  # interleaving produces — while the DB row carries the newer keys.
  it "does not erase telemetry written after the instance was loaded" do
    allow_any_instance_of(::System::NodeInstance).to receive(:config).and_return({})

    post "/api/v1/system/node_api/status",
         params: { status: "running", metrics: { "cpu" => 1 } }.to_json,
         headers: headers.merge("CONTENT_TYPE" => "application/json")

    expect(response).to have_http_status(:ok)

    persisted = System::NodeInstance.where(id: instance.id).pick(:config)
    expect(persisted["boot_lkg"]).to eq("arm_state" => "armed")
    expect(persisted["module_verify_state"]).to eq("ok" => true)
    expect(persisted["sdwan_state"]).to eq("applied" => true)
  end

  it "still records its own keys" do
    post "/api/v1/system/node_api/status",
         params: { status: "running", metrics: { "cpu" => 42 } }.to_json,
         headers: headers.merge("CONTENT_TYPE" => "application/json")

    expect(response).to have_http_status(:ok)

    persisted = System::NodeInstance.where(id: instance.id).pick(:config)
    expect(persisted["metrics"]).to eq("cpu" => 42)
    expect(persisted["last_report"]).to be_present
    # and it did not drop what was already there
    expect(persisted["boot_lkg"]).to eq("arm_state" => "armed")
  end
end
