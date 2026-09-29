# frozen_string_literal: true

require "rails_helper"

# IMP-190834701b0a — the heartbeat is where the node's SSH host PUBLIC keys
# enter the platform. This file proves the LINK (the controller reads
# `ssh_host_keys` and hands it to System::SshHostKeyWriter) and that a bad
# report never bounces the heartbeat; the parsing itself is pinned in
# ssh_host_key_writer_spec.rb and ssh_host_keys_spec.rb.
RSpec.describe "Api::V1::System::NodeApi::Status#heartbeat — SSH host keys", type: :request do
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
    { boot_id: "boot-hostkey-1", agent_version: "1.5.0-test", mount_state: "mounted" }
  end

  def post_heartbeat(extra = {})
    post "/api/v1/system/node_api/status/heartbeat",
         params: base_body.merge(extra), headers: headers, as: :json
  end

  it "stores the reported host key and audits the first recording" do
    entry = SshHostKeyFixtures.entry

    post_heartbeat(ssh_host_keys: [ entry ])

    expect(response).to have_http_status(:ok)
    keys = instance.reload.ssh_host_keys["keys"]
    expect(keys).to eq([ entry.merge("fingerprint" => SshHostKeyFixtures.fingerprint(entry["key"])) ])
    expect(instance.ssh_host_keys["boot_id"]).to eq("boot-hostkey-1")
    expect(::AuditLog.where(action: System::SshHostKeyWriter::RECORDED_ACTION,
                            resource_id: instance.id.to_s)).to exist
  end

  it "leaves the column untouched for a heartbeat without the block (a pre-feature agent)" do
    post_heartbeat

    expect(response).to have_http_status(:ok)
    expect(instance.reload.ssh_host_keys).to be_nil
  end

  it "acknowledges a heartbeat carrying malformed or injected keys and records nothing" do
    good = SshHostKeyFixtures.entry
    post_heartbeat(ssh_host_keys: [ good.merge("key" => "#{good['key']}\n@cert-authority * ssh-ed25519 #{good['key']}"),
                                    { type: "ssh-ed25519", key: "A" * 10_000 } ])

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "acknowledged")).to be(true)
    expect(instance.reload.ssh_host_keys).to be_nil
  end

  it "acknowledges the heartbeat even when the ingest itself fails" do
    allow(System::SshHostKeyWriter).to receive(:write!).and_raise(StandardError, "boom")

    post_heartbeat(ssh_host_keys: [ SshHostKeyFixtures.entry ])

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "acknowledged")).to be(true)
  end
end
