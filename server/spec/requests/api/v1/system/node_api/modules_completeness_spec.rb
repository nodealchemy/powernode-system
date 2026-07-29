# frozen_string_literal: true

require "rails_helper"

# The node_api modules list is the agent's ONLY statement of desired state.
# On 2026-07-28 ops-hub's agent acted on a list that was missing its own
# platform modules and detached rails/traefik/sidekiq — the services answering
# this very endpoint — which on a self-hosted node is unrecoverable.
#
# The agent already treats a non-2xx as "could not determine desired state"
# and skips the tick (observed: a 502 during that incident caused no detach).
# So the fix is to make an incomplete list a non-2xx instead of a 200. A short
# list and a genuine unassignment are indistinguishable to the agent; only the
# server can tell them apart, and only at the moment it builds the list.
RSpec.describe "node_api modules completeness", type: :request do
  let(:account)  { create(:account) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

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

  def assign(mod)
    create(:system_node_module_assignment, node: node, node_module: mod, enabled: true)
  end

  def headers_for(inst)
    { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{inst.id}")) }
  end

  let(:headers) { headers_for(instance) }

  before do
    3.times do |i|
      assign(create(:system_node_module, account: account, name: "mod-#{i}", enabled: true))
    end
  end

  it "returns every assigned module under normal conditions" do
    get "/api/v1/system/node_api/modules", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.dig("data", "count")).to eq(3)
    expect(body.dig("data", "modules").size).to eq(3)
  end

  # The load-bearing case. Dependency resolution is a REORDERING; it must
  # never change the population. If it ever returns fewer modules than it was
  # given, the response is a lie about desired state and must not be served
  # with a 200.
  it "fails closed with 503 when resolution drops a module" do
    allow_any_instance_of(Api::V1::System::NodeApi::ModulesController)
      .to receive(:resolve_module_dependencies) { |_, mods| mods.to_a.first(2) }

    get "/api/v1/system/node_api/modules", headers: headers

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to match(/incomplete|resolution/i)
  end

  it "does not fail when resolution merely reorders" do
    allow_any_instance_of(Api::V1::System::NodeApi::ModulesController)
      .to receive(:resolve_module_dependencies) { |_, mods| mods.to_a.reverse }

    get "/api/v1/system/node_api/modules", headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "count")).to eq(3)
  end

  # A node with genuinely nothing assigned must still get an empty 200 — that
  # is a real state, not a fault, and 503-ing it would break first boot.
  it "serves an empty list for a node with no assignments" do
    other = create(:system_node, account: account)
    other_instance = create(:system_node_instance, :running, node: other)
    System::NodeCertificate.create!(
      node_instance: other_instance, serial: SecureRandom.hex(16),
      subject: "CN=#{other_instance.id}", not_before: 1.hour.ago,
      not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )

    get "/api/v1/system/node_api/modules", headers: headers_for(other_instance)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("data", "count")).to eq(0)
  end

  # A duplicated entry is also a corrupt list — it would make the agent's
  # digest diff nonsense — and is just as cheap to catch here.
  it "fails closed when resolution duplicates a module" do
    allow_any_instance_of(Api::V1::System::NodeApi::ModulesController)
      .to receive(:resolve_module_dependencies) { |_, mods| mods.to_a + [ mods.to_a.first ] }

    get "/api/v1/system/node_api/modules", headers: headers

    expect(response).to have_http_status(:service_unavailable)
  end

  # Same COUNT, different population. A size-only check passes this happily,
  # which is why the invariant compares identities: serving a list where one
  # module has been substituted for another would have the agent detach the
  # real one and attach a stranger.
  it "fails closed when resolution substitutes a different module" do
    stranger = create(:system_node_module, account: account, name: "stranger", enabled: true)
    allow_any_instance_of(Api::V1::System::NodeApi::ModulesController)
      .to receive(:resolve_module_dependencies) { |_, mods| mods.to_a.first(2) + [ stranger ] }

    get "/api/v1/system/node_api/modules", headers: headers

    expect(response).to have_http_status(:service_unavailable)
  end
end
