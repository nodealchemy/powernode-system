# frozen_string_literal: true

require "rails_helper"

# APO-5 / DR-2 (IMP-4b4bed6967ed) — the REST half.
#
# `POST /provider_volumes/:id/snapshot` USED TO FABRICATE ITS ANSWER: it
# INSERTed a ProviderVolumeSnapshot row with status "pending" and returned 201,
# without ever asking a provider anything. No provider adapter in the tree had
# a volume-snapshot method to ask, so every 201 it returned was the same lie —
# an operator who read that row believed they had a restore point that did not
# exist. These specs pin the two properties that replaced it: the endpoint asks
# the PROVIDER, and it refuses instead of recording when the provider cannot.
RSpec.describe "Provider volume snapshots + restore", type: :request do
  let(:account) { create(:account) }
  let(:user) do
    create(:user, account: account,
                  permissions: %w[system.volumes.read system.volumes.snapshot
                                  system.volumes.delete system.volumes.manage])
  end
  let(:volume) do
    create(:system_provider_volume, account: account, status: "available",
                                    external_id: "vol-abc123")
  end
  let(:adapter) { instance_double(System::Providers::BaseProvider) }

  before do
    allow(System::Providers::Registry).to receive(:for_volume).and_return(adapter)
  end

  describe "POST /api/v1/system/provider_volumes/:id/snapshot" do
    it "refuses — and records NOTHING — when the provider cannot snapshot" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(false)

      expect {
        post "/api/v1/system/provider_volumes/#{volume.id}/snapshot",
             params: { name: "nightly" }.to_json, headers: auth_headers_for(user)
      }.not_to change(System::ProviderVolumeSnapshot, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"] || response.parsed_body["message"]).to match(/snapshot/i)
    end

    it "records a COMPLETED snapshot only when the provider confirms one" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      allow(adapter).to receive(:create_volume_snapshot)
        .and_return({ success: true, snapshot_id: "provider-snap-1" })

      post "/api/v1/system/provider_volumes/#{volume.id}/snapshot",
           params: { name: "nightly" }.to_json, headers: auth_headers_for(user)

      expect(response).to have_http_status(:created)
      snap = System::ProviderVolumeSnapshot.find_by(account: account, name: "nightly")
      expect(snap.status).to eq("completed")
      expect(snap.external_id).to eq("provider-snap-1")
    end

    it "leaves an ERROR row — never a pending or completed one — when the provider call fails" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      allow(adapter).to receive(:create_volume_snapshot)
        .and_return({ success: false, error: "storage busy" })

      post "/api/v1/system/provider_volumes/#{volume.id}/snapshot",
           params: { name: "nightly" }.to_json, headers: auth_headers_for(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(System::ProviderVolumeSnapshot.find_by(account: account, name: "nightly").status)
        .to eq("error")
    end
  end

  describe "POST /api/v1/system/provider_volumes/:id/restore" do
    let(:snapshot) do
      create(:system_provider_volume_snapshot, account: account, volume: volume,
                                               status: "completed", external_id: "provider-snap-1")
    end

    it "restores through the provider" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:in_place)
      allow(adapter).to receive(:restore_volume_snapshot).and_return({ success: true })

      post "/api/v1/system/provider_volumes/#{volume.id}/restore",
           params: { snapshot_id: snapshot.id }.to_json, headers: auth_headers_for(user)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["data"] || response.parsed_body
      expect(body["restored_in_place"]).to be(true)
    end

    # On a copy-semantics provider (Azure) the SOURCE volume is untouched and
    # the restored data lands in a new provider-side disk. The response must
    # say so and must name the volume row the platform recorded for it —
    # otherwise the caller reads 200 as "my volume is back" and the new disk is
    # an untracked, unattachable, billable orphan.
    it "reports a copy restore as a NEW volume rather than claiming the source was restored" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:copy)
      allow(adapter).to receive(:restore_volume_snapshot)
        .and_return({ success: true, volume_id: "vol-restored-1", size_gb: volume.size_gb })

      post "/api/v1/system/provider_volumes/#{volume.id}/restore",
           params: { snapshot_id: snapshot.id }.to_json, headers: auth_headers_for(user)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["data"] || response.parsed_body
      expect(body["restored_in_place"]).to be(false)
      expect(body.dig("restored_volume", "external_id")).to eq("vol-restored-1")
      expect(body.dig("restored_volume", "id")).not_to eq(volume.id)
    end

    it "refuses a snapshot that is not a restore point" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      # Stubbed so the negative assertion below is a real observation, not the
      # vacuous pass an unstubbed double gives.
      allow(adapter).to receive(:restore_volume_snapshot).and_return({ success: true })
      snapshot.update!(status: "error")

      post "/api/v1/system/provider_volumes/#{volume.id}/restore",
           params: { snapshot_id: snapshot.id }.to_json, headers: auth_headers_for(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(adapter).not_to have_received(:restore_volume_snapshot)
    end
  end

  describe "GET /api/v1/system/provider_volumes/:id/snapshots" do
    it "lists the volume's snapshots" do
      snap = create(:system_provider_volume_snapshot, account: account, volume: volume,
                                                      status: "completed")

      get "/api/v1/system/provider_volumes/#{volume.id}/snapshots",
          headers: auth_headers_for(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "snapshots")&.map { |s| s["id"] } ||
             response.parsed_body["snapshots"].map { |s| s["id"] }).to include(snap.id)
    end
  end
end
