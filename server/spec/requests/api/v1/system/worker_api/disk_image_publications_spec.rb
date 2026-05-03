# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Worker API: disk_image_publications", type: :request do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account, name: "ubuntu-24.04-rpi4") }
  let(:plain_token) { "wrk-tok-#{SecureRandom.hex(8)}" }
  let!(:worker) do
    w = create(:worker, account: account, status: "active")
    w.update_columns(token_digest: Digest::SHA256.hexdigest(plain_token))
    w
  end

  let(:headers) { { "X-Worker-Token" => plain_token, "Content-Type" => "application/json" } }

  before do
    # Mirror the existing worker_api spec pattern: stub has_permission?
    # rather than seeding Permission rows (avoids coupling to schema
    # details that aren't this controller's concern).
    allow_any_instance_of(Worker).to receive(:has_permission?)
      .with("system.platforms.publish_disk_image").and_return(true)

    platform.update!(
      cosign_identity_regexp: "https://git.ipnode.org/.+",
      cosign_issuer_regexp:   "https://git.ipnode.org"
    )
  end

  describe "POST /process" do
    let!(:publication) do
      create(:system_disk_image_publication, account: account, node_platform: platform, status: "queued")
    end

    it "401 when X-Worker-Token is missing" do
      post "/api/v1/system/worker_api/disk_image_publications/process",
           params: { publication_id: publication.id }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "404 when publication doesn't exist" do
      post "/api/v1/system/worker_api/disk_image_publications/process",
           params: { publication_id: SecureRandom.uuid }.to_json, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "403 when worker.account_id != publication.account_id (cross-tenant)" do
      other_account = create(:account)
      other_platform = create(:system_node_platform, account: other_account)
      other_pub = create(:system_disk_image_publication, account: other_account, node_platform: other_platform)
      post "/api/v1/system/worker_api/disk_image_publications/process",
           params: { publication_id: other_pub.id }.to_json, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "200 + invokes processor on happy path" do
      fake_result = ::System::DiskImagePublicationProcessor::Result.new(
        ok?: true, publication: publication, file_object: nil
      )
      allow(::System::DiskImagePublicationProcessor).to receive(:process!).and_return(fake_result)

      post "/api/v1/system/worker_api/disk_image_publications/process",
           params: { publication_id: publication.id }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["data"]["publication_id"]).to eq(publication.id)
    end

    it "422 on processor failure (don't retry on validation-class)" do
      fake_result = ::System::DiskImagePublicationProcessor::Result.new(
        ok?: false, error: "cosign verify failed", publication: publication
      )
      allow(::System::DiskImagePublicationProcessor).to receive(:process!).and_return(fake_result)

      post "/api/v1/system/worker_api/disk_image_publications/process",
           params: { publication_id: publication.id }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("cosign verify failed")
    end
  end

  describe "POST /sweep_retention" do
    it "200 + dispatches per-platform sweep when platform_id given" do
      allow(::System::DiskImageRetentionService).to receive(:sweep!).and_return(
        ::System::DiskImageRetentionService::Result.new(retired_count: 2, purged_count: 1, errors: [])
      )

      post "/api/v1/system/worker_api/disk_image_publications/sweep_retention",
           params: { platform_id: platform.id, grace_days: 7 }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["retired"]).to eq(2)
      expect(data["purged"]).to eq(1)
    end

    it "200 + dispatches account-wide sweep when platform_id absent" do
      allow(::System::DiskImageRetentionService).to receive(:sweep_account!).and_return({
        platform.id => ::System::DiskImageRetentionService::Result.new(retired_count: 0, purged_count: 0, errors: [])
      })

      post "/api/v1/system/worker_api/disk_image_publications/sweep_retention",
           params: {}.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)["data"]
      expect(data["account_id"]).to eq(account.id)
      expect(data["per_platform"]).to be_present
    end
  end
end
