# frozen_string_literal: true

require "rails_helper"

# node_api/base_controller — mTLS-only authentication.
# The reverse proxy (Traefik v3) verifies the client cert against the
# internal CA and forwards the subject CN via
# `X-Forwarded-Tls-Client-Cert-Info` (URL-encoded `Subject="CN=<value>"`).
# This is the only header the controller honors — no JWT fallback,
# no nginx-style env, no Traefik v2 legacy header.
RSpec.describe "Api::V1::System::NodeApi mTLS authentication", type: :request do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  # Issue an active cert so the mTLS path can verify.
  let!(:cert) do
    System::NodeCertificate.create!(
      node_instance: instance,
      serial: SecureRandom.hex(16),
      subject: "CN=#{instance.id}",
      not_before: 1.hour.ago,
      not_after:  90.days.from_now,
      issuer_subject: "CN=Powernode Internal CA"
    )
  end

  let(:probe_path) { "/api/v1/system/node_api/config/authorized_keys" }

  def traefik_header(cn)
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{cn}")) }
  end

  describe "happy path" do
    it "authenticates when Traefik forwards an instance-id CN with an active cert" do
      get probe_path, headers: traefik_header(instance.id)
      expect(response).to have_http_status(:ok)
    end

    it "looks up by mtls_subject when the CN is not a NodeInstance.id" do
      instance.update!(mtls_subject: "node-instance-#{instance.id}")
      get probe_path, headers: traefik_header("node-instance-#{instance.id}")
      expect(response).to have_http_status(:ok)
    end

    it "authenticates the live instance, not a terminated sibling sharing the mtls_subject" do
      # The agent's cert CN is the Node hostname, which every spawn from that
      # Node shares — so many NodeInstances carry the same mtls_subject. A plain
      # find_by(mtls_subject:) returned the oldest match (often a TERMINATED row)
      # and 401'd the live agent. The resolver must skip terminated/error rows.
      shared = "child.example.test"
      instance.update!(mtls_subject: shared) # running, has active cert (let!)
      terminated = create(:system_node_instance, node: node, status: "terminated",
                                                  mtls_subject: shared)
      terminated.update_column(:created_at, 5.days.ago) # older → would shadow

      get probe_path, headers: traefik_header(shared)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "auth failures" do
    it "returns 401 when the CN matches no instance" do
      get probe_path, headers: traefik_header(SecureRandom.uuid)
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to include("Instance not found for mTLS")
    end

    it "returns 401 when the instance has no active certificate" do
      cert.revoke!(reason: "rotated")
      get probe_path, headers: traefik_header(instance.id)
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to include("No active certificate")
    end

    it "returns 401 when no mTLS subject header is forwarded" do
      get probe_path
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to include("mTLS client certificate required")
    end

    it "returns 401 when a stale X-Instance-Token header is the only auth" do
      # The JWT path was removed; an X-Instance-Token alone is now meaningless.
      get probe_path, headers: { "X-Instance-Token" => "anything.at.all" }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
