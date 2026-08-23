# frozen_string_literal: true

require "rails_helper"

# IMP-57e9a90598ee — first-heartbeat network-profile classification.
#
# NodeInstance#suggest_network_profile existed with zero production callers:
# its facts (agent-observed architecture + provider-declared SKU memory) only
# come together at the first heartbeat, and nothing consulted it there. This
# wiring classifies an instance EXACTLY ONCE — on the heartbeat that
# transitions it into running — from those facts:
#
#   - observed architecture (the agent just reported it in this heartbeat)
#   - declared memory (provider_instance_type.memory_mb, the SKU the operator
#     chose) or the agent's config["memory_mb"] hint
#
# "First heartbeat" means FIRST CONTACT EVER (last_heartbeat_at was nil before
# the request), not merely "first stamp-less non-running heartbeat" — a legacy
# instance provisioned before this feature has no network_profile_source stamp
# either, and without the first-contact guard the whole legacy fleet would
# auto-classify (and eligible hosts silently promote to heavyweight) on its
# next pass through a reboot or self-heal. Legacy hosts never auto-classify.
#
# Already-running instances NEVER auto-flip (a fleet-wide profile wave on
# deploy would churn host networking); operators promote those explicitly via
# system_update_instance. An operator-declared profile always wins. Nothing is
# ever auto-DEMOTED. When the facts cannot prove heavyweight headroom the
# instance stays lightweight — and says so via network_profile_source.
RSpec.describe "Api::V1::System::NodeApi::Status#heartbeat — network profile classification", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance_type) do
    create(:system_provider_instance_type, account: account, memory_mb: 16_384)
  end
  let(:instance) do
    create(:system_node_instance, node: node, status: "pending",
                                  provider_instance_type: instance_type)
  end

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

  def post_heartbeat(arch: "amd64")
    post "/api/v1/system/node_api/status/heartbeat",
         params: { boot_id: "boot-np-1", agent_version: "1.0.0-test",
                   mount_state: "mounted", architecture: arch },
         headers: headers, as: :json
  end

  it "promotes a first-heartbeat amd64/16GB instance to heavyweight, with provenance" do
    post_heartbeat

    expect(response).to have_http_status(:ok)
    instance.reload
    expect(instance.status).to eq("running")
    expect(instance.network_profile).to eq("heavyweight")
    expect(instance.config["network_profile_source"]).to eq("suggested_first_heartbeat")
  end

  it "stays lightweight when the facts cannot prove headroom" do
    instance_type.update_columns(memory_mb: 2048)

    post_heartbeat

    instance.reload
    expect(instance.network_profile).to eq("lightweight")
    # Classification RAN and measured; it did not silently skip.
    expect(instance.config["network_profile_source"]).to eq("suggested_first_heartbeat")
  end

  it "never auto-classifies a legacy host passing through a reboot — first contact only" do
    # A pre-existing instance: it has heartbeated before (in a prior life),
    # carries no stamp, and is mid-reboot — exactly the state in which the
    # stamp guard alone would let the legacy fleet auto-promote.
    instance.update_columns(status: "rebooting", last_heartbeat_at: 2.days.ago)

    post_heartbeat

    instance.reload
    expect(instance.status).to eq("running")
    expect(instance.network_profile).to eq("lightweight")
    expect(instance.config["network_profile_source"]).to be_nil
  end

  it "never reclassifies an already-running instance" do
    instance.update!(status: "running")

    post_heartbeat

    expect(instance.reload.network_profile).to eq("lightweight")
    expect(instance.config["network_profile_source"]).to be_nil
  end

  it "never overrides an operator-declared profile" do
    instance.update!(config: instance.config.merge("network_profile_source" => "operator"))
    instance.update_columns(network_profile: "lightweight")

    post_heartbeat

    instance.reload
    expect(instance.network_profile).to eq("lightweight")
    expect(instance.config["network_profile_source"]).to eq("operator")
  end

  it "emits a fleet event when a promotion happens" do
    expect {
      post_heartbeat
    }.to change {
      System::FleetEvent.where(account: account, kind: "system.instance.network_profile_promoted").count
    }.by(1)
  end

  # There is deliberately NO "architecture never arrived" case: the column is
  # NOT NULL with a CHECK (amd64|arm64), so an instance without an observed or
  # declared architecture is unrepresentable — the unknown-fact path lives
  # entirely in available_memory_mb, covered above.
end
