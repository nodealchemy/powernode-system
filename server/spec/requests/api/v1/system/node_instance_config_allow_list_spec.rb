# frozen_string_literal: true

require "rails_helper"

# IMP-1b65222b8d5f — the two REST writers of System::NodeInstance#config
# stopped accepting an arbitrary document.
#
# Both controllers permitted `config: {}`, so a request body carried the WHOLE
# jsonb document into `update`. Two consequences, and they are different
# defects that happen to share a permit list:
#
#   1. CLOBBER (the IMP-044cf93b class). `config` is shared with the agent's
#      telemetry lanes — boot_lkg, module_verify_state, runtime_metrics,
#      sdwan_state — which write several times a minute per node. A PUT
#      carrying a document assembled from a page load erases whatever landed
#      in the interval, silently, on both sides.
#   2. UNVALIDATED STAGE KEYS. Nothing checked what a key MEANT, so a body
#      could set `network_profile_source` (provenance, not config) or invent
#      keys no reader knows about.
#
# The ruling (operator, 2026-09-02, bulk review D18) is an ALLOW-LIST:
# System::NodeInstance::WRITABLE_CONFIG_KEYS names what a request body may
# write; anything else is refused as a 422, and the accepted keys go through
# the per-key seam (System::ConfigDocument#merge_config!) rather than replacing
# the document.
#
# WHY THE ROW, NOT THE STATUS. A 422 is also what a validation failure
# produces, so every refusal example below asserts the STORED DOCUMENT as well
# — a guard that renders 422 from an action body does not halt the action, and
# the write would land anyway.
RSpec.describe "System::NodeInstance config allow-list (REST writers)", type: :request do
  # A telemetry lane document, in the shape RuntimeMetricsWriter stores. The
  # oracle for the clobber arm: it must survive an accepted write.
  let(:telemetry) { { "cpu_pct" => 7, "observed_at" => "2026-09-02T00:00:00Z" } }

  describe "the operator API" do
    let(:user) do
      user_with_permissions("system.instances.create", "system.instances.update",
                            "system.instances.read", "system.nodes.read")
    end
    let(:account)  { user.account }
    let(:node)     { create(:system_node, account: account) }
    let!(:instance) do
      create(:system_node_instance, node: node, status: "running",
                                    config: { "runtime_metrics" => telemetry })
    end

    def put_config(document)
      put "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}",
          params: { node_instance: { config: document } },
          headers: auth_headers_for(user), as: :json
    end

    it "refuses a body that names a platform-written telemetry lane" do
      put_config("runtime_metrics" => { "cpu_pct" => 99 })

      expect(response).to have_http_status(:unprocessable_content)
      expect(instance.reload.config["runtime_metrics"]).to eq(telemetry)
    end

    it "refuses a body that names the network-profile provenance stamp" do
      put_config("network_profile_source" => "operator")

      expect(response).to have_http_status(:unprocessable_content)
      expect(instance.reload.config).not_to have_key("network_profile_source")
    end

    it "refuses an invented key no reader knows about, naming it in the error" do
      put_config("zz_unknown_stage_key" => 1)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("zz_unknown_stage_key")
      expect(instance.reload.config).not_to have_key("zz_unknown_stage_key")
    end

    it "accepts an allow-listed key WITHOUT erasing the telemetry lane beside it" do
      put_config("hardware_model" => "raspberry_pi_5")

      expect(response).to have_http_status(:ok)
      instance.reload
      expect(instance.config["hardware_model"]).to eq("raspberry_pi_5")
      expect(instance.config["runtime_metrics"]).to eq(telemetry)
    end

    it "refuses a config that is not an object at all, rather than 500ing" do
      put "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}",
          params: { node_instance: { config: "boot_lkg" } },
          headers: auth_headers_for(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(instance.reload.config["runtime_metrics"]).to eq(telemetry)
    end

    # THE ALLOW-LIST CHECK RUNS BEFORE THE STRONG-PARAMS `require`, so it has to
    # be careful about a malformed root: `params.dig(:node_instance, :config)`
    # on a String root raises NoMethodError inside the CHECK, which would move
    # the failure from the params layer into the new code and read as a bug
    # this change introduced.
    #
    # This pins that the outcome is UNCHANGED, and it is an honest record of a
    # PRE-EXISTING defect rather than an endorsement: a String root reaches
    # `params.require(:node_instance).permit(...)`, which is a NoMethodError on
    # String and a 500. That is the behaviour on HEAD, it is not this task's
    # finding, and narrowing it is a separate change. The ROW is the assertion
    # that matters here — whatever the params layer does with the root, the
    # allow-list path must not have written anything.
    it "does not write, and does not change the outcome, for a malformed node_instance root" do
      put "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}",
          params: { node_instance: "not-an-object" },
          headers: auth_headers_for(user), as: :json

      expect(instance.reload.config["runtime_metrics"]).to eq(telemetry)
      expect(response).to have_http_status(:internal_server_error)
    end

    it "still updates the scalar columns when no config is supplied" do
      put "/api/v1/system/nodes/#{node.id}/node_instances/#{instance.id}",
          params: { node_instance: { name: "renamed-by-operator" } },
          headers: auth_headers_for(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(instance.reload.name).to eq("renamed-by-operator")
    end

    it "refuses a create whose config carries a non-writable key, and inserts nothing" do
      post "/api/v1/system/nodes/#{node.id}/node_instances",
           params: { node_instance: { name: "zz-refused-instance", variety: "cloud",
                                      status: "pending", config: { "boot_lkg" => { "arm_state" => "armed" } } } },
           headers: auth_headers_for(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(::System::NodeInstance.where(name: "zz-refused-instance").count).to eq(0)
    end

    it "accepts a create whose config is entirely allow-listed" do
      post "/api/v1/system/nodes/#{node.id}/node_instances",
           params: { node_instance: { name: "zz-accepted-instance", variety: "cloud",
                                      status: "pending",
                                      config: { "provider_region_id" => "r-1", "boot_mode" => "erofs_overlay" } } },
           headers: auth_headers_for(user), as: :json

      expect(response).to have_http_status(:created)
      created = ::System::NodeInstance.find_by!(name: "zz-accepted-instance")
      expect(created.config["provider_region_id"]).to eq("r-1")
      expect(created.config["boot_mode"]).to eq("erofs_overlay")
    end
  end

  describe "the worker API" do
    let(:account)  { create(:account) }
    let(:worker)   { create(:worker, status: "active") }
    let(:node)     { create(:system_node, account: account, worker: worker) }
    let(:headers)  { worker_mtls_headers(worker) }
    let!(:instance) do
      create(:system_node_instance, node: node, status: "running",
                                    config: { "runtime_metrics" => telemetry })
    end

    before do
      allow_any_instance_of(Worker).to receive(:has_permission?).and_return(true)
    end

    it "refuses an update body that names a platform-written telemetry lane" do
      put "/api/v1/system/worker_api/node_instances/#{instance.id}",
          params: { instance: { config: { "sdwan_state" => { "observed_at" => "now" } } } },
          headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(instance.reload.config).not_to have_key("sdwan_state")
      expect(instance.config["runtime_metrics"]).to eq(telemetry)
    end

    it "accepts an allow-listed key WITHOUT erasing the telemetry lane beside it" do
      put "/api/v1/system/worker_api/node_instances/#{instance.id}",
          params: { instance: { config: { "memory_mb" => 8192 } } },
          headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      instance.reload
      expect(instance.config["memory_mb"]).to eq(8192)
      expect(instance.config["runtime_metrics"]).to eq(telemetry)
    end

    it "refuses a create whose config carries a non-writable key, and inserts nothing" do
      post "/api/v1/system/worker_api/node_instances",
           params: { node_id: node.id,
                     instance: { name: "zz-worker-refused", variety: "cloud", status: "pending",
                                 config: { "module_verify_state" => { "modules" => [] } } } },
           headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(::System::NodeInstance.where(name: "zz-worker-refused").count).to eq(0)
    end
  end
end
