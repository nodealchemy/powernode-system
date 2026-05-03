# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GET /api/v1/system/node_platforms/:id/disk_image", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:operator) { user_with_permissions("system.platforms.read", account: account) }
  let(:headers) { auth_headers_for(operator) }

  context "when no disk image has been built" do
    it "returns 404 with explanatory message" do
      get "/api/v1/system/node_platforms/#{platform.id}/disk_image", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]).to include("No disk image built")
    end
  end

  context "when disk image is set" do
    let(:file_storage) do
      fs = ::FileManagement::Storage.new(
        account: account,
        name: "test-local-storage-#{SecureRandom.hex(2)}",
        provider_type: "local",
        is_default: true,
        configuration: { "root_path" => "/tmp/test-storage" },
        capabilities: {}
      )
      fs.save(validate: false)
      fs
    end
    let(:file_object) do
      fo = ::FileManagement::Object.new(
        account: account,
        filename: "powernode-test.img",
        content_type: "application/octet-stream",
        file_size: 2_000_000_000,
        checksum_sha256: "abc123" * 10 + "abcd",
        storage_key: "test-disk-image",
        uploaded_by_id: operator.id,
        file_storage_id: file_storage.id
      )
      fo.save(validate: false)
      fo
    end

    before do
      platform.update!(
        disk_image_file_object_id: file_object.id,
        disk_image_sha256: file_object.checksum_sha256,
        disk_image_size_bytes: file_object.file_size,
        disk_image_built_at: 5.minutes.ago
      )
      # Stub FileStorageService entirely — instance creation requires a
      # default storage_config and provider lookup, which is environment-
      # dependent. The disk_image controller only consumes file_url.
      fake_service = instance_double(::FileStorageService,
                                     file_url: "https://files.example.com/signed/test-disk-image?expires=1234")
      allow(::FileStorageService).to receive(:new).and_return(fake_service)
    end

    it "returns signed URL + checksum + size" do
      get "/api/v1/system/node_platforms/#{platform.id}/disk_image", headers: headers
      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["url"]).to include("signed/test-disk-image")
      expect(data["sha256"]).to eq(file_object.checksum_sha256)
      expect(data["size_bytes"]).to eq(2_000_000_000)
      expect(data["filename"]).to include(platform.name)
    end

    it "emits a system.disk_image_downloaded FleetEvent" do
      expect {
        get "/api/v1/system/node_platforms/#{platform.id}/disk_image", headers: headers
      }.to change {
        System::FleetEvent.where(account: account, kind: "system.disk_image_downloaded").count
      }.by(1)
      event = System::FleetEvent.where(kind: "system.disk_image_downloaded").last
      expect(event.payload["platform_name"]).to eq(platform.name)
      expect(event.payload["by_user_id"]).to eq(operator.id)
    end
  end
end
