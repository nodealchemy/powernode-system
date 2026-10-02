# frozen_string_literal: true

require "rails_helper"

# IMP-87ce46b9a1aa — data.timezone on the assigned-modules response, the
# per-node timezone the agent renders into /etc/localtime. The value is a
# deployment-local fact, so it comes from configuration (the node's own config,
# then a site setting), never a literal in a tracked manifest; and it is
# validated by shape here, because the agent re-validates it against its image
# but the platform must not hand out junk.
RSpec.describe "node_api modules timezone", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform, name: "t-#{SecureRandom.hex(3)}") }
  let(:node)     { create(:system_node, account: account, node_template: template, name: "n-#{SecureRandom.hex(3)}") }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  let!(:active_cert) do
    System::NodeCertificate.create!(
      node_instance: instance, serial: SecureRandom.hex(16), subject: "CN=#{instance.id}",
      not_before: 1.hour.ago, not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
  end
  let(:headers) { { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) } }

  def fetch
    get "/api/v1/system/node_api/modules", headers: headers
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).fetch("data")
  end

  def set_site_timezone(value)
    allow(SiteSetting).to receive(:get).and_call_original
    allow(SiteSetting).to receive(:get).with("system.timezone").and_return(value)
  end

  it "omits timezone for a node with none declared — the platform never invents one" do
    expect(fetch["timezone"]).to be_nil
  end

  it "serves the node's own configured timezone" do
    node.update!(config: (node.config || {}).merge("timezone" => "America/Anchorage"))

    expect(fetch["timezone"]).to eq("America/Anchorage")
  end

  it "falls back to the site-wide setting when the node declares none" do
    set_site_timezone("Europe/Berlin")

    expect(fetch["timezone"]).to eq("Europe/Berlin")
  end

  it "prefers the node's own value over the site setting" do
    set_site_timezone("Europe/Berlin")
    node.update!(config: (node.config || {}).merge("timezone" => "America/Anchorage"))

    expect(fetch["timezone"]).to eq("America/Anchorage")
  end

  it "drops a value that is not shaped like a zoneinfo name instead of passing it on" do
    [ "../../etc/passwd", "/etc/passwd", "UTC\nx", "a b", "x;y", "A" * 100, 5, [ "UTC" ], { "a" => 1 }, "" ].each do |bad|
      node.update!(config: (node.config || {}).merge("timezone" => bad))

      expect(fetch["timezone"]).to be_nil, "expected #{bad.inspect} to be dropped"
    end
  end

  it "falls through to the site setting when the node's own value is malformed" do
    set_site_timezone("Europe/Berlin")
    node.update!(config: (node.config || {}).merge("timezone" => "../../x"))

    expect(fetch["timezone"]).to eq("Europe/Berlin")
  end

  it "ignores a node config that is not a hash and falls back to the site setting" do
    set_site_timezone("Europe/Berlin")
    [ [], 5, "timezone" ].each do |bad|
      allow_any_instance_of(System::Node).to receive(:config).and_return(bad)

      expect(fetch["timezone"]).to eq("Europe/Berlin"), "config #{bad.inspect}"
    end
  end

  it "serves the trimmed name for a whitespace-padded value" do
    node.update!(config: (node.config || {}).merge("timezone" => " Europe/Berlin\n"))

    expect(fetch["timezone"]).to eq("Europe/Berlin")
  end

  it "does not leak one node's timezone to another" do
    other = create(:system_node, account: account, node_template: template, name: "o-#{SecureRandom.hex(3)}")
    other.update!(config: (other.config || {}).merge("timezone" => "Asia/Tokyo"))

    expect(fetch["timezone"]).to be_nil
  end
end
