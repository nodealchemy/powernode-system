# frozen_string_literal: true

require "rails_helper"

# Plan reference: Decentralized Federation §G + §I + P7.3.
RSpec.describe "Api::V1::System::Platform::Deployments", type: :request do
  let(:account) { create(:account) }
  let(:reader)  { user_with_permissions("system.platform.read", account: account) }
  let(:scaler)  { user_with_permissions("system.platform.read", "system.platform.scale", account: account) }
  let(:base)    { "/api/v1/system/platform/deployments" }

  describe "GET /deployments" do
    let!(:dep_a) { create(:system_platform_deployment, account: account, name: "api-tier", service_role: "api") }
    let!(:dep_b) { create(:system_platform_deployment, account: account, name: "worker-tier", service_role: "worker") }
    let!(:other) { create(:system_platform_deployment, account: create(:account)) }

    it "lists this account's deployments only with computed actual_replicas" do
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)

      data = json_response_data
      expect(data["count"]).to eq(2)
      names = data["deployments"].map { |d| d["name"] }
      expect(names).to contain_exactly("api-tier", "worker-tier")
      expect(data["deployments"].first).to include("actual_replicas", "actual_by_status", "target_replicas")
    end

    it "forbids without read permission" do
      anon = create(:user, account: account)
      get base, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

  # IMP-3d4058389afa. The panel's `actual_replicas` and
  # System::Platform::ReplicaReconciler#live_scope must read ONE number:
  # active rows MINUS cordoned rows (the marker System::InstanceCordonService
  # owns, via the NodeInstance.not_cordoned scope). Before this, the panel
  # counted cordoned rows and the reconciler did not, so a cordon followed by
  # its reconciled replacement rendered target+1 with nothing labelling why.
  # The cordoned rows are still disclosed — as `cordoned_count`, a second,
  # labelled number — not hidden.
  describe "GET /deployments — cordoned replicas are counted separately" do
    let(:template) { create(:system_node_template, account: account) }
    let(:node)     { create(:system_node, account: account, node_template: template) }
    let!(:dep)     { create(:system_platform_deployment, account: account, node_template: template, target_replicas: 2) }

    let!(:live)     { create(:system_node_instance, node: node, account: account, status: "running") }
    let!(:cordoned) { create(:system_node_instance, node: node, account: account, status: "running") }

    before do
      result = ::System::InstanceCordonService.cordon!(instance: cordoned, user: reader, reason: "maintenance")
      raise result.error unless result.ok?
    end

    def deployment_payload
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)
      json_response_data["deployments"].find { |d| d["id"] == dep.id }
    end

    it "excludes the cordoned replica from actual_replicas, the same count #live_scope reads" do
      payload = deployment_payload
      live_count = ::System::Platform::ReplicaReconciler.new(account: account, internal: true)
                                                         .send(:live_scope, dep).count

      expect(payload["actual_replicas"]).to eq(1)
      expect(payload["actual_replicas"]).to eq(live_count)
    end

    it "reports the cordoned replica as cordoned_count" do
      expect(deployment_payload["cordoned_count"]).to eq(1)
    end

    it "keeps the per-status breakdown over every row, cordoned included" do
      expect(deployment_payload["actual_by_status"]).to eq("running" => 2)
    end

    it "does not count a cordoned replica that is no longer active" do
      cordoned.update_column(:status, "terminated")
      expect(deployment_payload["cordoned_count"]).to eq(0)
    end

    it "reports cordoned_count 0 on a deployment with nothing cordoned" do
      cordoned.update_column(:config, {})
      payload = deployment_payload
      expect(payload["actual_replicas"]).to eq(2)
      expect(payload["cordoned_count"]).to eq(0)
    end
  end

  describe "PATCH /deployments/:id" do
    let!(:dep) { create(:system_platform_deployment, account: account, name: "api-tier", target_replicas: 1) }

    it "updates target_replicas and reports the reconcile outcome (IMP-f4fe1ed1ec1e)" do
      patch "#{base}/#{dep.id}", params: { target_replicas: 3 },
                                  headers: auth_headers_for(scaler), as: :json
      expect(response).to have_http_status(:ok)
      expect(json_response_data["deployment"]["target_replicas"]).to eq(3)
      # The write is no longer the whole story: the panel's PATCH drives
      # System::Platform::ReplicaReconciler and says what converged. Full
      # coverage in deployments_scale_reconcile_spec.rb.
      expect(json_response_data).to have_key("reconciled")
    end

    it "rejects negative target_replicas" do
      patch "#{base}/#{dep.id}", params: { target_replicas: -1 },
                                  headers: auth_headers_for(scaler), as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects empty body" do
      patch "#{base}/#{dep.id}", params: {}, headers: auth_headers_for(scaler), as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "forbids without scale permission" do
      patch "#{base}/#{dep.id}", params: { target_replicas: 2 },
                                  headers: auth_headers_for(reader), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
