# frozen_string_literal: true

require "rails_helper"

# Audit F5-03 — the storage_volume endpoint feeds the on-node agent's
# mount.ReconcileStorageVolume every reconcile tick; a shape regression
# breaks durable-storage mounts fleet-wide. Pins the orchestrator-stamped
# config["storage_volume"] passthrough and the nil (nothing-to-reconcile)
# contract.
RSpec.describe "Api::V1::System::NodeApi::StorageVolume#show", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }

  let(:binding) do
    {
      "volume_id" => "vol-123",
      "device" => "/dev/vdb",
      "mount_path" => "/srv/data",
      "fs_type" => "ext4"
    }
  end

  let(:instance) do
    create(:system_node_instance, node: node, status: "running",
           config: { "storage_volume" => binding })
  end

  let!(:cert) do
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

  it "rejects unauthenticated requests" do
    get "/api/v1/system/node_api/storage_volume"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns the orchestrator-stamped binding verbatim" do
    get "/api/v1/system/node_api/storage_volume", headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "storage_volume")).to eq(binding)
  end

  it "returns storage_volume: nil when no volume is bound (nothing to reconcile)" do
    instance.update_columns(config: {})

    get "/api/v1/system/node_api/storage_volume", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["data"]).to have_key("storage_volume")
    expect(body.dig("data", "storage_volume")).to be_nil
  end
end
