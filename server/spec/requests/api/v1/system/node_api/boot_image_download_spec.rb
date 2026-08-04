# frozen_string_literal: true

require "rails_helper"

# Tests for GET /api/v1/system/node_api/boot_image/download — UKI artifact proxy
# (campaign 019f505f increment 2). The agent executing an upgrade_boot_image task
# pulls the standalone UKI blob through this endpoint, which content-addresses it
# via OciBlobProxyService (digest-mode) for fleet-wide caching.
#
# The pin source is the DiskImagePublication row, NOT the NodePlatform
# disk_image_uki_* columns (IMP-b55869029a57). This endpoint is the third copy of
# the resolution that f2d0a32b unified for the plan + dispatch paths; serving from
# the columns made it authoritative on BYTES while the dispatcher stayed
# authoritative on PINS, so any column-vs-publication skew failed EVERY upgrade
# on-node with "UKI sha256 mismatch".
RSpec.describe "Api::V1::System::NodeApi::BootImage#download", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:platform)      { create(:system_node_platform, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "pending") }

  let(:digest_a) { "a1" + ("0" * 62) }
  let(:digest_b) { "b2" + ("0" * 62) }

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

  # Promoted publication A + platform columns pointing at it — the healthy,
  # consistent state every context starts from unless it deliberately skews one.
  def promote!(publication)
    publication.node_platform.update!(
      disk_image_git_sha:     publication.git_sha,
      disk_image_oci_ref:     publication.oci_ref,
      disk_image_uki_oci_ref: publication.uki_oci_ref,
      disk_image_uki_sha256:  publication.uki_sha256
    )
  end

  def stub_blob(contents)
    temp_file = Tempfile.new("uki-blob")
    temp_file.write(contents)
    temp_file.rewind
    allow(::System::OciBlobProxyService).to receive(:new).and_return(
      double("OciBlobProxyService", fetch_blob!: temp_file.path)
    )
    temp_file
  end

  describe "GET /api/v1/system/node_api/boot_image/download" do
    context "when the promoted publication carries a UKI artifact" do
      let!(:publication) do
        create(:system_disk_image_publication, :published,
               account: account, node_platform: platform,
               git_sha: "platform-sha-abc123",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
               uki_sha256: digest_a)
      end

      before do
        node_template.update!(node_platform: platform)
        promote!(publication)
      end

      it "returns 200 with UKI blob bytes and sets response headers" do
        blob_data = "UEFI-UKI-BINARY-DATA-12345"
        temp_file = stub_blob(blob_data)

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to eq(blob_data)

        expect(response.headers["X-Boot-Image-Digest"]).to eq(digest_a)
        expect(response.headers["X-Boot-Image-Git-SHA"]).to eq("platform-sha-abc123")
        expect(response.headers["ETag"]).to eq(%("#{digest_a}"))
        expect(response.headers["Content-Disposition"]).to include("BOOTX64.EFI")

        temp_file.close
      end

      it "constructs OciBlobProxyService from the publication's pins" do
        temp_file = stub_blob("test-blob-data")

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)
        expect(::System::OciBlobProxyService).to have_received(:new).with(
          hash_including(
            oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
            media_type: "application/vnd.powernode.uki.v1",
            digest: digest_a,
            account: account
          )
        )

        temp_file.close
      end

      it "streams the blob with buffer_size and octet-stream content-type" do
        blob_data = "LARGE-BLOB-DATA" * 1000
        temp_file = stub_blob(blob_data)

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to eq("application/octet-stream")
        expect(response.body.length).to eq(blob_data.length)

        temp_file.close
      end
    end

    # The bug this endpoint existed to have: a task pinned to publication A, a
    # promote to B mid-flight, and a download that served B's bytes against A's
    # digest — every in-flight upgrade dying on "UKI sha256 mismatch".
    context "when a promote lands between dispatch and download" do
      let!(:publication_a) do
        create(:system_disk_image_publication, :retired,
               account: account, node_platform: platform,
               git_sha: "sha-a-pinned",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:A",
               uki_sha256: digest_a)
      end

      let!(:publication_b) do
        create(:system_disk_image_publication, :published,
               account: account, node_platform: platform,
               git_sha: "sha-b-promoted",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:B",
               uki_sha256: digest_b)
      end

      before do
        node_template.update!(node_platform: platform)
        promote!(publication_b) # B is now the platform's promoted image
      end

      it "serves the digest the task was pinned to, not the newly promoted one" do
        temp_file = stub_blob("uki-A-bytes")

        get "/api/v1/system/node_api/boot_image/download",
            params: { digest: digest_a }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(::System::OciBlobProxyService).to have_received(:new).with(
          hash_including(oci_ref: "ghcr.io/nodealchemy/system/uki:A", digest: digest_a)
        )
        expect(response.headers["X-Boot-Image-Digest"]).to eq(digest_a)
        # The git-sha header must describe the BYTES served, not the platform's
        # current promotion — the agent records it as what it booted.
        expect(response.headers["X-Boot-Image-Git-SHA"]).to eq("sha-a-pinned")

        temp_file.close
      end

      it "accepts the sha256: prefixed form of the digest" do
        temp_file = stub_blob("uki-A-bytes")

        get "/api/v1/system/node_api/boot_image/download",
            params: { digest: "sha256:#{digest_a}" }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(::System::OciBlobProxyService).to have_received(:new).with(
          hash_including(digest: digest_a)
        )

        temp_file.close
      end

      it "still serves the promoted publication when no digest is supplied" do
        temp_file = stub_blob("uki-B-bytes")

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)
        expect(::System::OciBlobProxyService).to have_received(:new).with(
          hash_including(oci_ref: "ghcr.io/nodealchemy/system/uki:B", digest: digest_b)
        )

        temp_file.close
      end
    end

    # The stronger corollary: the dispatcher pins from the publication row, so a
    # partial-field promote writer that leaves the columns behind breaks EVERY
    # boot-image upgrade on-node until someone repairs the columns.
    context "when the platform columns are stale relative to the promoted publication" do
      let!(:publication) do
        create(:system_disk_image_publication, :published,
               account: account, node_platform: platform,
               git_sha: "sha-current",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:current",
               uki_sha256: digest_a)
      end

      before do
        node_template.update!(node_platform: platform)
        platform.update!(
          disk_image_git_sha:     "sha-current",
          disk_image_uki_oci_ref: "ghcr.io/nodealchemy/system/uki:stale",
          disk_image_uki_sha256:  digest_b
        )
      end

      it "serves the publication's pins, not the stale columns" do
        temp_file = stub_blob("uki-current-bytes")

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)
        expect(::System::OciBlobProxyService).to have_received(:new).with(
          hash_including(oci_ref: "ghcr.io/nodealchemy/system/uki:current", digest: digest_a)
        )
        expect(response.headers["X-Boot-Image-Digest"]).to eq(digest_a)

        temp_file.close
      end

      it "serves the publication even when the UKI columns were never written" do
        platform.update!(disk_image_uki_oci_ref: nil, disk_image_uki_sha256: nil)
        temp_file = stub_blob("uki-current-bytes")

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)
        expect(::System::OciBlobProxyService).to have_received(:new).with(
          hash_including(oci_ref: "ghcr.io/nodealchemy/system/uki:current", digest: digest_a)
        )

        temp_file.close
      end
    end

    context "when a requested digest cannot be resolved" do
      let!(:publication) do
        create(:system_disk_image_publication, :published,
               account: account, node_platform: platform,
               git_sha: "sha-current",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:current",
               uki_sha256: digest_a)
      end

      before do
        node_template.update!(node_platform: platform)
        promote!(publication)
      end

      it "404s rather than falling back to the promoted artifact" do
        allow(::System::OciBlobProxyService).to receive(:new)

        get "/api/v1/system/node_api/boot_image/download",
            params: { digest: digest_b }, headers: headers

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)["error"]).to include("No UKI artifact matching digest")
        expect(::System::OciBlobProxyService).not_to have_received(:new)
      end

      it "404s for a digest belonging to another account's platform" do
        other_account  = create(:account)
        other_platform = create(:system_node_platform, account: other_account)
        create(:system_disk_image_publication, :published,
               account: other_account, node_platform: other_platform,
               git_sha: "sha-other",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:other",
               uki_sha256: digest_b)

        allow(::System::OciBlobProxyService).to receive(:new)

        get "/api/v1/system/node_api/boot_image/download",
            params: { digest: digest_b }, headers: headers

        expect(response).to have_http_status(:not_found)
        # Message-pinned: a bare 404 here is indistinguishable from a routing
        # 404, which is how an earlier version of this spec passed without ever
        # reaching the controller.
        expect(JSON.parse(response.body)["error"]).to include("No UKI artifact matching digest")
        expect(::System::OciBlobProxyService).not_to have_received(:new)
      end

      # Same ACCOUNT, different PLATFORM — a sibling platform is a different
      # arch or image line, so serving across platforms hands a node a UKI it
      # cannot boot. An account-scoped lookup passes every cross-ACCOUNT test
      # and fails only this one.
      it "404s for a digest published by a sibling platform in the same account" do
        sibling_platform = create(:system_node_platform, account: account)
        create(:system_disk_image_publication, :published,
               account: account, node_platform: sibling_platform,
               git_sha: "sha-sibling",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:sibling",
               uki_sha256: digest_b)

        allow(::System::OciBlobProxyService).to receive(:new)

        get "/api/v1/system/node_api/boot_image/download",
            params: { digest: digest_b }, headers: headers

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)["error"]).to include("No UKI artifact matching digest")
        expect(::System::OciBlobProxyService).not_to have_received(:new)
      end

      it "404s for a digest whose publication failed verification" do
        create(:system_disk_image_publication, :failed,
               account: account, node_platform: platform,
               git_sha: "sha-failed",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:failed",
               uki_sha256: digest_b)

        allow(::System::OciBlobProxyService).to receive(:new)

        get "/api/v1/system/node_api/boot_image/download",
            params: { digest: digest_b }, headers: headers

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)["error"]).to include("No UKI artifact matching digest")
        expect(::System::OciBlobProxyService).not_to have_received(:new)
      end

      # The laundering path: `retire` transitions from FAILED as well as
      # published (DiskImageRetentionService#retire_stuck! cleans up abandoned CI
      # runs), so a build that failed cosign/sha verification at ingest can end
      # up status=retired. Status alone cannot tell it apart from a legitimately
      # promoted-then-retired image; published_at can, because only
      # mark_published and reactivate ever set it.
      it "404s for a failed publication laundered into retired by the reaper" do
        laundered = create(:system_disk_image_publication, :failed,
                           account: account, node_platform: platform,
                           git_sha: "sha-laundered",
                           uki_oci_ref: "ghcr.io/nodealchemy/system/uki:laundered",
                           uki_sha256: digest_b)
        laundered.retire
        laundered.save!
        expect(laundered.reload).to have_attributes(status: "retired", published_at: nil)

        allow(::System::OciBlobProxyService).to receive(:new)

        get "/api/v1/system/node_api/boot_image/download",
            params: { digest: digest_b }, headers: headers

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)["error"]).to include("No UKI artifact matching digest")
        expect(::System::OciBlobProxyService).not_to have_received(:new)
      end

      it "400s when the digest parameter is supplied but empty" do
        allow(::System::OciBlobProxyService).to receive(:new)

        get "/api/v1/system/node_api/boot_image/download",
            params: { digest: "" }, headers: headers

        # NOT a silent fall-through to the promoted artifact: that would
        # reinstate the promote-window race a pin-serialization bug is trying
        # to cause.
        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)["error"]).to include("supplied but empty")
        expect(::System::OciBlobProxyService).not_to have_received(:new)
      end
    end

    context "when platform is nil (defensive check)" do
      it "returns 404 when current_node.node_platform is nil" do
        allow_any_instance_of(Api::V1::System::NodeApi::BootImageController).to receive(:current_node).and_return(
          double("System::Node", node_platform: nil)
        )

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :json

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json["error"]).to be_present
      end
    end

    context "when the platform has no promoted image" do
      before { node_template.update!(node_platform: platform) }

      it "returns 404 with 'No promoted UKI artifact' error" do
        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :json

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("No promoted UKI artifact")
      end
    end

    context "when the promoted git_sha has no publication row" do
      before do
        node_template.update!(node_platform: platform)
        platform.update!(
          disk_image_git_sha:     "sha-with-no-row",
          disk_image_uki_oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
          disk_image_uki_sha256:  digest_a
        )
      end

      it "returns 404 instead of serving the orphaned columns" do
        allow(::System::OciBlobProxyService).to receive(:new)

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :json

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)["error"]).to include("No promoted UKI artifact")
        expect(::System::OciBlobProxyService).not_to have_received(:new)
      end
    end

    context "when the promoted publication has no UKI artifact" do
      let!(:publication) do
        create(:system_disk_image_publication, :published,
               account: account, node_platform: platform,
               git_sha: "sha-no-uki",
               uki_oci_ref: nil, uki_sha256: nil)
      end

      before do
        node_template.update!(node_platform: platform)
        platform.update!(disk_image_git_sha: "sha-no-uki", disk_image_oci_ref: publication.oci_ref)
      end

      it "returns 404 with 'No promoted UKI artifact' error" do
        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :json

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("No promoted UKI artifact")
      end
    end

    context "when OciBlobProxyService raises PullError" do
      let!(:publication) do
        create(:system_disk_image_publication, :published,
               account: account, node_platform: platform,
               git_sha: "sha-current",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
               uki_sha256: digest_a)
      end

      before do
        node_template.update!(node_platform: platform)
        promote!(publication)
      end

      it "returns 502 bad_gateway with error message" do
        service_double = double("OciBlobProxyService")
        allow(service_double).to receive(:fetch_blob!).and_raise(::System::OciBlobProxyService::PullError, "registry unreachable")
        allow(::System::OciBlobProxyService).to receive(:new).and_return(service_double)

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :json

        expect(response).to have_http_status(:bad_gateway)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("UKI blob fetch failed")
      end

      it "logs the error before returning 502" do
        service_double = double("OciBlobProxyService")
        allow(service_double).to receive(:fetch_blob!).and_raise(::System::OciBlobProxyService::PullError, "network timeout")
        allow(::System::OciBlobProxyService).to receive(:new).and_return(service_double)

        expect(::Rails.logger).to receive(:error).with(/UKI proxy failed/)

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :json

        expect(response).to have_http_status(:bad_gateway)
      end
    end

    context "authentication" do
      let!(:publication) do
        create(:system_disk_image_publication, :published,
               account: account, node_platform: platform,
               git_sha: "sha-current",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
               uki_sha256: digest_a)
      end

      before do
        node_template.update!(node_platform: platform)
        promote!(publication)
      end

      it "rejects requests without mTLS certificate" do
        get "/api/v1/system/node_api/boot_image/download", as: :octet_stream

        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects requests with invalid certificate subject" do
        bad_headers = { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=invalid-id")) }

        get "/api/v1/system/node_api/boot_image/download", headers: bad_headers, as: :octet_stream

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "scoping to instance's platform" do
      let!(:publication) do
        create(:system_disk_image_publication, :published,
               account: account, node_platform: platform,
               git_sha: "sha-current",
               uki_oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
               uki_sha256: digest_a)
      end

      before do
        node_template.update!(node_platform: platform)
        promote!(publication)
      end

      it "serves only the instance's own platform UKI (not cross-platform)" do
        # The controller resolves the publication through current_node
        # (mTLS-derived), so an instance can only ever pull its own platform's
        # UKI history.
        other_account  = create(:account)
        other_platform = create(:system_node_platform, account: other_account)
        other_template = create(:system_node_template, account: other_account, node_platform: other_platform)
        create(:system_node, account: other_account, node_template: other_template)

        temp_file = stub_blob("should-not-be-served")

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)
        expect(::System::OciBlobProxyService).to have_received(:new).with(
          hash_including(account: account, oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0")
        )

        temp_file.close
      end
    end
  end
end
