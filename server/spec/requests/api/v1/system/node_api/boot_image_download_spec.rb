# frozen_string_literal: true

require "rails_helper"

# Tests for GET /api/v1/system/node_api/boot_image/download — UKI artifact proxy
# (campaign 019f505f increment 2). The agent executing an upgrade_boot_image task
# pulls the standalone UKI blob through this endpoint, which content-addresses it
# via OciBlobProxyService (digest-mode) for fleet-wide caching.
RSpec.describe "Api::V1::System::NodeApi::BootImage#download", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:platform)      { create(:system_node_platform, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "pending") }

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

  describe "GET /api/v1/system/node_api/boot_image/download" do
    context "when platform has promoted UKI artifact" do
      before do
        # Set the platform through the node_template
        node_template.update!(node_platform: platform)
        platform.update!(
          disk_image_git_sha: "platform-sha-abc123",
          disk_image_uki_oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
          disk_image_uki_sha256: "sha256:abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz01"
        )
      end

      it "returns 200 with UKI blob bytes and sets response headers" do
        # Create a temp file with test data
        blob_data = "UEFI-UKI-BINARY-DATA-12345"
        temp_file = Tempfile.new("uki-blob")
        temp_file.write(blob_data)
        temp_file.rewind

        # Stub OciBlobProxyService to return the temp file path
        allow(::System::OciBlobProxyService).to receive(:new).and_return(
          double("OciBlobProxyService", fetch_blob!: temp_file.path)
        )

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to eq(blob_data)

        # Verify response headers
        expect(response.headers["X-Boot-Image-Digest"])
          .to eq("sha256:abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz01")
        expect(response.headers["X-Boot-Image-Git-SHA"]).to eq("platform-sha-abc123")
        expect(response.headers["ETag"])
          .to eq(%("sha256:abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz01"))

        # Verify Content-Disposition
        expect(response.headers["Content-Disposition"]).to include("BOOTX64.EFI")

        temp_file.close
      end

      it "constructs OciBlobProxyService with correct parameters" do
        temp_file = Tempfile.new("uki-blob")
        temp_file.write("test-blob-data")
        temp_file.rewind

        allow(::System::OciBlobProxyService).to receive(:new).and_return(
          double("OciBlobProxyService", fetch_blob!: temp_file.path)
        )

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)

        # Verify the proxy was created with the correct parameters
        expect(::System::OciBlobProxyService).to have_received(:new).with(
          hash_including(
            oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
            media_type: "application/vnd.powernode.uki.v1",
            digest: "sha256:abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz01",
            account: account
          )
        )

        temp_file.close
      end

      it "streams the blob with buffer_size and octet-stream content-type" do
        blob_data = "LARGE-BLOB-DATA" * 1000  # Make it larger
        temp_file = Tempfile.new("uki-blob")
        temp_file.write(blob_data)
        temp_file.rewind

        allow(::System::OciBlobProxyService).to receive(:new).and_return(
          double("OciBlobProxyService", fetch_blob!: temp_file.path)
        )

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to eq("application/octet-stream")
        expect(response.body.length).to eq(blob_data.length)

        temp_file.close
      end
    end

    context "when platform is nil (defensive check)" do
      it "returns 404 when current_node.node_platform is nil" do
        # Mock current_node to return a node with nil platform
        allow_any_instance_of(Api::V1::System::NodeApi::BootImageController).to receive(:current_node).and_return(
          double("System::Node", node_platform: nil)
        )

        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :json

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json["error"]).to be_present
      end
    end

    context "when platform has no disk_image_uki_oci_ref" do
      before do
        node_template.update!(node_platform: platform)
        platform.update!(
          disk_image_uki_oci_ref: nil,
          disk_image_uki_sha256: "sha256:abcdef123456"
        )
      end

      it "returns 404 with 'No promoted UKI artifact' error" do
        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :json

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("No promoted UKI artifact")
      end
    end

    context "when platform has no disk_image_uki_sha256" do
      before do
        node_template.update!(node_platform: platform)
        platform.update!(
          disk_image_uki_oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
          disk_image_uki_sha256: nil
        )
      end

      it "returns 404 with 'No promoted UKI artifact' error" do
        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :json

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("No promoted UKI artifact")
      end
    end

    context "when OciBlobProxyService raises PullError" do
      before do
        node_template.update!(node_platform: platform)
        platform.update!(
          disk_image_uki_oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
          disk_image_uki_sha256: "sha256:abcdef123456"
        )
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
      before do
        node_template.update!(node_platform: platform)
        platform.update!(
          disk_image_uki_oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
          disk_image_uki_sha256: "sha256:abcdef123456"
        )
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
      before do
        node_template.update!(node_platform: platform)
        platform.update!(
          disk_image_uki_oci_ref: "ghcr.io/nodealchemy/system/uki:v1.0.0",
          disk_image_uki_sha256: "sha256:abcdef123456"
        )
      end

      it "serves only the instance's own platform UKI (not cross-platform)" do
        # This test verifies the controller uses current_node (auth-derived) to scope platform
        # The mTLS auth ensures only the authenticated instance can pull its platform's UKI
        other_account = create(:account)
        other_platform = create(:system_node_platform, account: other_account)
        other_template = create(:system_node_template, account: other_account, node_platform: other_platform)
        other_node = create(:system_node, account: other_account, node_template: other_template)

        # Create a blob for the other platform
        temp_file = Tempfile.new("uki-blob")
        temp_file.write("should-not-be-served")
        temp_file.rewind

        # Even if we could somehow spoof the proxy service, the instance can only access
        # its own platform via current_node (which is mTLS-derived)
        allow(::System::OciBlobProxyService).to receive(:new).and_return(
          double("OciBlobProxyService", fetch_blob!: temp_file.path)
        )

        # Request from our instance
        get "/api/v1/system/node_api/boot_image/download", headers: headers, as: :octet_stream

        expect(response).to have_http_status(:ok)
        # Proxy was called with OUR account and platform
        expect(::System::OciBlobProxyService).to have_received(:new).with(
          hash_including(account: account)
        )

        temp_file.close
      end
    end
  end
end
