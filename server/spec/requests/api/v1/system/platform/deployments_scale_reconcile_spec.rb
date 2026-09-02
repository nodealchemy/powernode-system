# frozen_string_literal: true

require "rails_helper"

# IMP-f4fe1ed1ec1e (APO-3b remainder).
#
# The Scaling panel's PATCH was the last target_replicas writer with no
# actuator behind it: it wrote the column, emitted an event, and left the
# convergence to an operator who was told nothing. APO-3b built
# System::Platform::ReplicaReconciler and wired the skill door to it; this
# spec pins the operator door onto the same rail — including the hub refusal
# (checked BEFORE the write, so the panel can never leave a target_replicas
# nothing will ever converge) and the reconciler's per-pass clamp.
RSpec.describe "Api::V1::System::Platform::Deployments scale reconcile", type: :request do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let!(:node)    { create(:system_node, account: account, node_template: template, name: "api-node") }
  let(:deployment) do
    create(:system_platform_deployment, account: account, name: "api-tier",
                                        node_template: template, target_replicas: 1)
  end
  let(:operator) do
    user_with_permissions("system.platform.read", "system.platform.scale",
                          "system.instances.create", "system.instances.control",
                          account: account)
  end
  let(:base) { "/api/v1/system/platform/deployments" }

  def live_instance!
    create(:system_node_instance, node: node, account: account, status: "running")
  end

  def stub_provision!
    allow(::System::ProvisioningService).to receive(:provision_instance) do
      ::System::Runtime::Result.ok(data: { instance: live_instance! })
    end
  end

  def patch_target(value, as: operator)
    patch "#{base}/#{deployment.id}", params: { target_replicas: value },
                                      headers: auth_headers_for(as), as: :json
  end

  it "reconciles the live replica count after writing target_replicas" do
    live_instance!
    stub_provision!

    patch_target(3)

    expect(response).to have_http_status(:ok)
    reconciled = json_response_data["reconciled"]
    expect(reconciled).to be_present
    expect(reconciled["ok"]).to be true
    expect(reconciled["actual_before"]).to eq(1)
    expect(reconciled["actual_after"]).to eq(3)
    expect(reconciled["provisioned_instance_ids"].size).to eq(2)
  end

  it "applies the reconciler's per-pass clamp rather than provisioning the whole delta" do
    live_instance!
    SiteSetting.set(::System::Platform::ReplicaReconciler::MAX_DELTA_SETTING_KEY, "1")
    stub_provision!

    patch_target(5)

    expect(response).to have_http_status(:ok)
    reconciled = json_response_data["reconciled"]
    expect(reconciled["provisioned_instance_ids"].size).to eq(1)
    expect(reconciled["actual_after"]).to eq(2)
  end

  it "refuses the control plane's own hosting deployment WITHOUT writing target_replicas" do
    SiteSetting.set("self_hosting_node_id", node.id)
    expect(::System::ProvisioningService).not_to receive(:provision_instance)

    patch_target(4)

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["error"]).to match(/own hosting|self-remediat|consensus group/i)
    expect(deployment.reload.target_replicas).to eq(1)
  end

  it "reports a refused reconcile instead of an unqualified success" do
    live_instance!
    scaler = user_with_permissions("system.platform.read", "system.platform.scale", account: account)

    patch_target(3, as: scaler)

    reconciled = json_response_data["reconciled"]
    expect(reconciled["ok"]).to be false
    expect(reconciled["refused_reason"]).to eq("insufficient_permission")
    expect(reconciled["message"]).to match(/system\.instances\.create/)
  end

  it "does not reconcile a patch that never names target_replicas" do
    expect(::System::Platform::ReplicaReconciler).not_to receive(:new)

    patch "#{base}/#{deployment.id}", params: { public_dns_hostname: "api.example.test" },
                                      headers: auth_headers_for(operator), as: :json

    expect(response).to have_http_status(:ok)
    expect(json_response_data["deployment"]["public_dns_hostname"]).to eq("api.example.test")
    expect(json_response_data).not_to have_key("reconciled")
  end

  # REVIEW FINDING (blocker). The reconcile must NOT be gated on the value
  # CHANGING. target == stored is the state every deployment last written by
  # the GitOps bridge is in, and the state the reconciler's own per-pass clamp
  # leaves behind; skipping the actuator there reports a matching COLUMN as a
  # matching FLEET — this task's defect one layer up. The skill door says so
  # in as many words (platform_resilience_executor.rb, "RECONCILE
  # UNCONDITIONALLY"); this pins the operator door to the same rule.
  describe "re-asserting the SAME target" do
    it "still reconciles, so a clamped pass can be resumed" do
      live_instance!
      deployment.update!(target_replicas: 3)
      stub_provision!

      patch_target(3)

      expect(response).to have_http_status(:ok)
      reconciled = json_response_data["reconciled"]
      expect(reconciled).to be_present
      expect(reconciled["ok"]).to be true
      expect(reconciled["actual_before"]).to eq(1)
      expect(reconciled["actual_after"]).to eq(3)
    end

    it "still refuses the hub on a re-assert, without reaching the actuator" do
      SiteSetting.set("self_hosting_node_id", node.id)
      expect(::System::ProvisioningService).not_to receive(:provision_instance)

      patch_target(1)

      expect(response).to have_http_status(:unprocessable_content)
    end

    # Only the WRITE and the intent EVENT are conditional on a real change —
    # a re-assert must not mint a second "operator scaled this" record.
    it "emits no second scale-intent event for an unchanged target" do
      live_instance!
      deployment.update!(target_replicas: 3)
      stub_provision!

      expect {
        patch_target(3)
      }.not_to change {
        ::System::FleetEvent.where(account: account, kind: "platform.scale.intent").count
      }
    end
  end

  it "emits the scale-intent fleet event it has always claimed to emit" do
    live_instance!
    stub_provision!

    expect {
      patch_target(2)
    }.to change {
      ::System::FleetEvent.where(account: account, kind: "platform.scale.intent").count
    }.by(1)
  end
end
