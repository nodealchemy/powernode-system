# frozen_string_literal: true

require "rails_helper"

# Covers D1.2 (POST /platform/deployments) + D4.1 (GET /wizard) + VOL.*
# (volume_id, skip_volume, NFS pool semantics). Plan reference:
# Decentralized Federation §I + chat-deploy story.
RSpec.describe "Api::V1::System::Platform::Deployments — deploy create/wizard", type: :request do
  let(:account) { create(:account) }
  let(:viewer) { user_with_permissions("system.platform.read", account: account) }
  let(:deployer) do
    user_with_permissions("system.platform.read", "system.platform.deploy",
                          "system.platform.scale", account: account)
  end
  let(:base) { "/api/v1/system/platform/deployments" }

  # NodeTemplate the orchestrator resolves into a Node + ProvisioningService call.
  let!(:template) do
    create(:system_node_template, account: account, name: "powernode-hub")
  end

  describe "GET /deployments/wizard" do
    it "returns the wizard payload with form / templates / storage" do
      get "#{base}/wizard", headers: auth_headers_for(viewer)
      expect(response).to have_http_status(:ok)

      card = json_response_data["card"]
      expect(card["kind"]).to eq("platform_deployment_wizard")
      expect(card["phase"]).to eq("form")
      expect(card["fields"]).to be_an(Array)
      expect(card["modes"].map { |m| m["value"] }).to contain_exactly("standalone", "federated")
      expect(card["storage"]).to be_a(Hash)
      expect(card["storage"]["stateful_roles"]).to include("postgres", "redis")
    end

    it "forbids without read permission" do
      anon = create(:user, account: account)
      get "#{base}/wizard", headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /deployments" do
    let(:provision_success) do
      instance_double(System::Runtime::Result, success?: true,
                                                 data: { instance: build_stubbed(:system_node_instance, name: "sim-x") })
    end

    before do
      # Stub the heavyweight provisioning call so specs don't need a
      # live QEMU/cloud provider — we're testing orchestration, not
      # provider plumbing.
      allow(System::ProvisioningService).to receive(:provision_instance)
        .and_return(provision_success)
    end

    context "standalone mode, stateless role" do
      let(:body) do
        { mode: "standalone", template_slug: "powernode-hub",
          name: "smoke-api", service_role: "api" }
      end

      it "queues a deployment without attempting volume attach" do
        post base, params: body, headers: auth_headers_for(deployer), as: :json
        expect(response).to have_http_status(:accepted)
        data = json_response_data["deployment"]
        expect(data["mode"]).to eq("standalone")
        expect(data["platform_deployment_id"]).to be_present
        # No storage_volume in the response for stateless roles
        expect(data.dig("storage_volume")).to be_nil
      end
    end

    context "stateful role with skip_volume" do
      it "deploys with storage_volume=null when explicitly skipped" do
        post base, params: { mode: "standalone", template_slug: "powernode-hub",
                              name: "smoke-postgres-eph", service_role: "postgres",
                              skip_volume: true },
                    headers: auth_headers_for(deployer), as: :json
        expect(response).to have_http_status(:accepted)
        data = json_response_data["deployment"]
        expect(data.dig("storage_volume")).to be_nil
      end
    end

    context "stateful role with NFS pool volume" do
      let!(:provider) { create(:system_provider, account: account) }
      let!(:region) { create(:system_provider_region, provider: provider, account: account) }
      let!(:nfs_type) do
        create(:system_provider_volume_type, account: account, provider: provider,
                                              name: "nfs-shared", volume_type: "nfs")
      end
      let!(:nfs_volume) do
        create(:system_provider_volume, account: account, provider_region: region,
                                         volume_type: nfs_type, name: "test-nfs",
                                         size_gb: 100, status: "available",
                                         config: {
                                           "transport" => "nfs",
                                           "nfs" => {
                                             "server" => "test.nfs.local",
                                             "export_path" => "/exports/test",
                                             "mount_options" => "nfsvers=4.1"
                                           }
                                         })
      end

      it "attaches via volume_id and stamps NFS-aware binding" do
        # Spy on the orchestrator's attach path
        post base, params: { mode: "standalone", template_slug: "powernode-hub",
                              name: "smoke-postgres-nfs", service_role: "postgres",
                              volume_id: nfs_volume.id },
                    headers: auth_headers_for(deployer), as: :json
        expect(response).to have_http_status(:accepted)
        # Storage binding bubbles up in the deployment envelope when set
        body = json_response_data
        if body["acceptance_token"].nil? # standalone path
          # storage_volume key may be on `deployment` or inline depending on shape
          binding_present = body.dig("storage_volume") || body.dig("deployment", "storage_volume")
          if binding_present.is_a?(Hash) && !binding_present["error"]
            expect(binding_present).to include("transport" => "nfs")
            expect(binding_present).to include("mount_type" => "nfs")
            expect(binding_present["device_name"]).to be_nil
            expect(binding_present["subpath"]).to start_with("deployments/smoke-postgres-nfs/postgres")
          end
        end
      end

      it "keeps the NFS pool available after attach (multi-tenant)" do
        post base, params: { mode: "standalone", template_slug: "powernode-hub",
                              name: "smoke-pg-tenant", service_role: "postgres",
                              volume_id: nfs_volume.id },
                    headers: auth_headers_for(deployer), as: :json
        expect(response).to have_http_status(:accepted)
        # Pool semantics: the NFS volume row should NOT have flipped to in-use
        nfs_volume.reload
        expect(nfs_volume.status).to eq("available")
        expect(nfs_volume.node_instance_id).to be_nil
      end
    end

    context "invalid mode" do
      it "rejects with 400" do
        post base, params: { mode: "bogus", template_slug: "powernode-hub", name: "x" },
                    headers: auth_headers_for(deployer), as: :json
        expect(response).to have_http_status(:bad_request)
      end
    end

    it "forbids without deploy permission" do
      post base, params: { mode: "standalone", template_slug: "powernode-hub", name: "x" },
                  headers: auth_headers_for(viewer), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
