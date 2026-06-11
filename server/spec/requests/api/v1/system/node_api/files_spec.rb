# frozen_string_literal: true

require "rails_helper"

# Audit F5-03 — the files endpoint (module/script artifact delivery to the
# on-node agent) had zero request-spec coverage. Pins: both module URL
# shapes (M1 OCI bare + back-compat with :filename), node-scoped module
# visibility, traversal safety of the :filename param, and script delivery.
RSpec.describe "Api::V1::System::NodeApi::Files", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, node: node, status: "running") }

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

  describe "module_file" do
    let(:node_module) do
      create(:system_node_module, account: account, node_platform: platform,
             category: category, name: "nginx-mod")
    end
    let!(:assignment) do
      System::NodeModuleAssignment.create!(node: node, node_module: node_module,
                                           enabled: true, priority: 0)
    end

    let(:blob_bytes) { "EROFS-BLOB-BYTES" }
    let(:blob_path) do
      path = Rails.root.join("tmp", "f5_03_blob_#{SecureRandom.hex(4)}.erofs").to_s
      File.write(path, blob_bytes)
      path
    end

    let(:artifact) do
      { "oci_ref" => "registry.local/mods/nginx:1", "media_type" => "application/vnd.powernode.composefs",
        "oci_digest" => "sha256:" + Digest::SHA256.hexdigest(blob_bytes), "size" => blob_bytes.bytesize }
    end

    before do
      version = create(:system_node_module_version, node_module: node_module,
                       artifacts: { "erofs" => artifact })
      node_module.update!(current_version: version)
      allow_any_instance_of(System::OciBlobProxyService)
        .to receive(:fetch_blob!).and_return(blob_path)
    end

    after { File.delete(blob_path) if File.exist?(blob_path) }

    it "rejects unauthenticated requests" do
      get "/api/v1/system/node_api/files/modules/#{node_module.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it "streams the artifact via the M1 OCI URL shape with digest headers" do
      get "/api/v1/system/node_api/files/modules/#{node_module.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(blob_bytes)
      expect(response.headers["Content-Type"]).to eq(artifact["media_type"])
      expect(response.headers["X-Module-Digest"]).to eq(artifact["oci_digest"])
      expect(response.headers["ETag"]).to eq(%("#{artifact["oci_digest"]}"))
    end

    it "streams the same artifact via the back-compat :filename URL shape" do
      get "/api/v1/system/node_api/files/modules/#{node_module.id}/nginx-mod.tar.gz",
          headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(blob_bytes)
    end

    it "never lets :filename reach the filesystem — a dot-dot filename still serves the module's own artifact" do
      get "/api/v1/system/node_api/files/modules/#{node_module.id}/..", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(blob_bytes)
      expect(response.headers["Content-Disposition"]).to include("nginx-mod.erofs")
    end

    it "serves only the module's own artifact even for an encoded traversal filename" do
      # %2F-encoded slashes stay one path segment; the filename param is
      # never used for filesystem access, so the response is still the
      # module's own artifact — no path interpretation happens at all.
      get "/api/v1/system/node_api/files/modules/#{node_module.id}/..%2F..%2Fetc%2Fpasswd",
          headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(blob_bytes)
      expect(response.headers["Content-Disposition"]).to include("nginx-mod.erofs")
    end

    it "404s a module not assigned to this node (no cross-node artifact reads)" do
      foreign_node = create(:system_node, account: account, node_template: template)
      foreign_mod = create(:system_node_module, account: account, node_platform: platform,
                           category: category, name: "other-mod")
      System::NodeModuleAssignment.create!(node: foreign_node, node_module: foreign_mod,
                                           enabled: true, priority: 0)

      get "/api/v1/system/node_api/files/modules/#{foreign_mod.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it "404s when the module has no published artifact" do
      bare = create(:system_node_module, account: account, node_platform: platform,
                    category: category, name: "bare-mod")
      System::NodeModuleAssignment.create!(node: node, node_module: bare,
                                           enabled: true, priority: 0)

      get "/api/v1/system/node_api/files/modules/#{bare.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("ModuleArtifact")
    end
  end

  describe "script_file" do
    let!(:script) do
      create(:system_node_script, account: account, name: "bootstrap",
             data: "#!/bin/bash\necho 'hello'")
    end

    # The route is files/scripts/:id but the controller read params[:script_id]
    # (always-404) and served script.content / script.interpreter — attributes
    # NodeScript does not have (the body column is data). Same phantom-attr
    # drift class as F4-04/F4-09.
    it "serves the script body with checksum and content type" do
      get "/api/v1/system/node_api/files/scripts/#{script.id}", headers: headers

      expect(response).to have_http_status(:ok)
      file = JSON.parse(response.body).dig("data", "file")
      expect(file["name"]).to eq("bootstrap.sh")
      expect(file["content"]).to eq("#!/bin/bash\necho 'hello'")
      expect(file["checksum"]).to eq(Digest::SHA256.hexdigest("#!/bin/bash\necho 'hello'"))
      expect(file["content_type"]).to eq("text/plain")
    end

    it "404s an unknown script id" do
      get "/api/v1/system/node_api/files/scripts/#{SecureRandom.uuid}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
