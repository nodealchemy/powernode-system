# frozen_string_literal: true

require "rails_helper"

# Audit F5-03 — the LUKS passphrase endpoint (the most security-sensitive
# node_api surface: it issues mount-encryption keys) had zero request-spec
# coverage. These pin the security model the controller documents:
# per-(instance, partition_label) key separation, reboot determinism,
# label validation, and a durable audit record per issuance.
RSpec.describe "Api::V1::System::NodeApi::Luks#show", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, node: node, status: "running") }

  let(:other_node)     { create(:system_node, account: account, node_template: template) }
  let(:other_instance) { create(:system_node_instance, node: other_node, status: "running") }

  def cert_for!(inst)
    System::NodeCertificate.create!(
      node_instance: inst,
      serial:         SecureRandom.hex(16),
      subject:        "CN=#{inst.id}",
      not_before:     1.hour.ago,
      not_after:      90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  def headers_for(inst)
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{inst.id}")) }
  end

  before do
    cert_for!(instance)
    cert_for!(other_instance)
  end

  def fetch(inst, label)
    get "/api/v1/system/node_api/config/luks/#{label}", headers: headers_for(inst)
    response
  end

  it "rejects unauthenticated requests" do
    get "/api/v1/system/node_api/config/luks/rootfs"
    expect(response).to have_http_status(:unauthorized)
  end

  it "issues a passphrase scoped to the authenticated instance" do
    fetch(instance, "rootfs")

    expect(response).to have_http_status(:ok)
    data = JSON.parse(response.body)["data"]
    expect(data["partition_label"]).to eq("rootfs")
    expect(data["passphrase"]).to be_present
    expect(data["derivation"]).to eq("local_fallback") # no Vault in test
  end

  it "is deterministic for the same (instance, label) — reboots re-derive the same key" do
    first  = JSON.parse(fetch(instance, "rootfs").body).dig("data", "passphrase")
    second = JSON.parse(fetch(instance, "rootfs").body).dig("data", "passphrase")

    expect(first).to eq(second)
  end

  it "derives DIFFERENT keys for different instances with the same label (no cross-instance reuse)" do
    mine   = JSON.parse(fetch(instance, "rootfs").body).dig("data", "passphrase")
    theirs = JSON.parse(fetch(other_instance, "rootfs").body).dig("data", "passphrase")

    expect(mine).not_to eq(theirs)
  end

  it "derives different keys per partition label on the same instance" do
    root = JSON.parse(fetch(instance, "rootfs").body).dig("data", "passphrase")
    data = JSON.parse(fetch(instance, "datafs").body).dig("data", "passphrase")

    expect(root).not_to eq(data)
  end

  it "rejects an over-long partition label (cryptsetup constraint + traversal guard)" do
    # The route constraint ({1,32} of [a-zA-Z0-9_.-]) rejects this before the
    # controller's own (defense-in-depth) validation can 422 — the observable
    # contract is a routing 404.
    fetch(instance, "a" * 33)

    expect(response).to have_http_status(:not_found)
  end

  # The controller's SECURITY MODEL promises an audit entry per issuance —
  # the original ::System::AuditLog.create! referenced a model that does not
  # exist (NameError swallowed by rescue nil), so no audit was EVER written.
  it "records a durable audit event for each issuance" do
    expect { fetch(instance, "rootfs") }
      .to change { System::FleetEvent.where(kind: "system.luks_passphrase_issued").count }.by(1)

    event = System::FleetEvent.where(kind: "system.luks_passphrase_issued").last
    expect(event.node_instance_id).to eq(instance.id)
    expect(event.payload["partition_label"]).to eq("rootfs")
    # The passphrase itself must NEVER appear in the audit payload.
    expect(event.payload.to_json).not_to include(
      JSON.parse(response.body).dig("data", "passphrase")
    )
    expect(JSON.parse(response.body).dig("data", "audit_id")).to eq(event.id)
  end
end
