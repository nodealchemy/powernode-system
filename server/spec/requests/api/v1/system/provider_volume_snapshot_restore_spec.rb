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

    # SWEEP-2026-09-03 (carried out of IMP-e025722ef14e) — REST parity with
    # the MCP verb and the executor: `swap_into_place` is permitted and passed
    # through, and the answer says whether a swap happened (`swapped`) and, when
    # one was asked for but nothing was attached to swap out of, why not
    # (`swap_skipped`). Before this the param was silently dropped and neither
    # key was rendered, so a caller could not tell "not swapped" from "unknown".
    it "passes swap_into_place through and renders swapped / swap_skipped on a copy restore" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:copy)
      allow(adapter).to receive(:restore_volume_snapshot)
        .and_return({ success: true, volume_id: "vol-restored-2", size_gb: volume.size_gb })
      expect(::System::VolumeManagementService).to receive(:restore_snapshot)
        .with(snapshot: snapshot, swap_into_place: true).and_call_original

      post "/api/v1/system/provider_volumes/#{volume.id}/restore",
           params: { snapshot_id: snapshot.id, swap_into_place: true }.to_json,
           headers: auth_headers_for(user)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["data"] || response.parsed_body
      expect(body["restored_in_place"]).to be(false)
      expect(body).to have_key("swapped")
      expect(body["swapped"]).to be(false)
      expect(body["swap_skipped"]).to be_present
    end

    it "renders swapped: false with no swap_skipped when no swap was asked for" do
      allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
      allow(adapter).to receive(:volume_snapshot_restore_mode).and_return(:copy)
      allow(adapter).to receive(:restore_volume_snapshot)
        .and_return({ success: true, volume_id: "vol-restored-3", size_gb: volume.size_gb })

      post "/api/v1/system/provider_volumes/#{volume.id}/restore",
           params: { snapshot_id: snapshot.id }.to_json, headers: auth_headers_for(user)

      body = response.parsed_body["data"] || response.parsed_body
      expect(body).to have_key("swapped")
      expect(body["swapped"]).to be(false)
      expect(body["swap_skipped"]).to be_nil
    end

    # SWEEP-2026-09-03 review — permitting `swap_into_place` on this route made
    # a previously UNREACHABLE failure live: VolumeManagementService's swap can
    # fail at detach or attach AFTER the provider has already made the copy,
    # and it returns an `err` that CARRIES that copy. The route used to render
    # `result.error` alone, dropping the copy's id — leaving the operator a
    # billable, unattached disk they cannot find. The MCP twin has
    # SystemFleetTool#restore_error_result for exactly this; the REST door now
    # matches it. The envelope stays an error — the request was not completed.
    it "keeps the restored copy reachable when the swap fails after the copy was made" do
      restored = create(:system_provider_volume, account: account, status: "available",
                                                 external_id: "vol-restored-orphan")
      allow(::System::VolumeManagementService).to receive(:restore_snapshot).and_return(
        ::System::Runtime::Result.err(
          error: "Restored copy #{restored.name} is recorded but the swap failed at detach",
          data: { restored_in_place: false, restored_volume: restored,
                  restored_volume_id: restored.id, swapped: false, swap_stage: "detach" }
        )
      )

      post "/api/v1/system/provider_volumes/#{volume.id}/restore",
           params: { snapshot_id: snapshot.id, swap_into_place: true }.to_json,
           headers: auth_headers_for(user)

      expect(response).to have_http_status(:unprocessable_content)
      body = response.parsed_body
      expect(body["success"]).to be(false)
      expect(body["error"]).to include("swap failed at detach")
      expect(body.dig("details", "restored_volume_id")).to eq(restored.id)
      expect(body.dig("details", "restored_volume", "external_id")).to eq("vol-restored-orphan")
      expect(body.dig("details", "swapped")).to be(false)
      expect(body.dig("details", "swap_stage")).to eq("detach")
    end

    # The plain failure — nothing was created — must NOT grow a details blob
    # naming a copy that does not exist.
    it "renders a plain error with no copy details when the restore made nothing" do
      allow(::System::VolumeManagementService).to receive(:restore_snapshot).and_return(
        ::System::Runtime::Result.err(error: "provider refused the restore")
      )

      post "/api/v1/system/provider_volumes/#{volume.id}/restore",
           params: { snapshot_id: snapshot.id }.to_json, headers: auth_headers_for(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("provider refused the restore")
      expect(response.parsed_body).not_to have_key("details")
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
