# frozen_string_literal: true

require "rails_helper"

# IMP-9f4e162d9ed1 — data.confirmed_unassigned on the assigned-modules response,
# the platform's positive, per-module statement that it unassigned a module. The
# agent fails closed on an empty list; this is what lets it honour a REAL
# unassignment. The two directions both matter: the field must appear for a
# recorded removal, and must never be manufactured from the list being empty.
RSpec.describe "node_api modules confirmed_unassigned", type: :request do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }
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

  def node_module(name)
    create(:system_node_module, account: account, node_platform: platform, category: category,
           variety: "subscription", name: "#{name}-#{SecureRandom.hex(3)}")
  end

  def fetch
    get "/api/v1/system/node_api/modules", headers: headers
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).fetch("data")
  end

  it "omits the field's entries for a node with nothing to confirm — an empty answer is not a confirmation" do
    data = fetch

    expect(data["modules"]).to eq([])
    expect(Array(data["confirmed_unassigned"])).to eq([])
  end

  it "names a module the platform unassigned, alongside the empty list" do
    mod = node_module("removed")
    assignment = create(:system_node_module_assignment, node: node, node_module: mod, enabled: true)
    assignment.update!(enabled: false)

    data = fetch

    expect(data["modules"]).to eq([])
    expect(data["confirmed_unassigned"].map { |e| e["module_id"] }).to eq([ mod.id ])
    expect(data["confirmed_unassigned"].first).to include("reason" => "assignment_disabled")
    expect(data["confirmed_unassigned"].first["expires_at"]).to be_present
  end

  it "names the removed module next to the modules that remain (a partial removal)" do
    kept = node_module("kept")
    gone = node_module("gone")
    create(:system_node_module_assignment, node: node, node_module: kept, enabled: true)
    create(:system_node_module_assignment, node: node, node_module: gone, enabled: true).update!(enabled: false)

    data = fetch

    expect(data["modules"].map { |m| m["id"] }).to eq([ kept.id ])
    expect(data["confirmed_unassigned"].map { |e| e["module_id"] }).to eq([ gone.id ])
  end

  it "does not serve another node's clearance" do
    other_node = create(:system_node, account: account, node_template: template, name: "o-#{SecureRandom.hex(3)}")
    mod = node_module("elsewhere")
    create(:system_node_module_assignment, node: other_node, node_module: mod, enabled: true).destroy!

    expect(Array(fetch["confirmed_unassigned"])).to eq([])
  end

  it "stops serving a clearance once it has expired" do
    mod = node_module("old")
    create(:system_node_module_assignment, node: node, node_module: mod, enabled: true).destroy!
    System::NodeAssignmentClearance.where(node_id: node.id).update_all(expires_at: 1.minute.ago)

    expect(Array(fetch["confirmed_unassigned"])).to eq([])
  end

  it "never lists a module the same response serves, even if its clearance row is stale" do
    mod = node_module("back")
    System::AssignmentClearanceService.issue!(node: node, node_module_ids: [ mod.id ], reason: "assignment_destroyed")
    # A write path that missed its revoke: the module is live again.
    System::NodeModuleAssignment.insert_all!([ { node_id: node.id, node_module_id: mod.id, enabled: true, priority: 0,
                                                 config: {}, created_at: Time.current, updated_at: Time.current } ])

    data = fetch

    expect(data["modules"].map { |m| m["id"] }).to eq([ mod.id ])
    expect(Array(data["confirmed_unassigned"])).to eq([])
  end

  it "fails CLOSED when the clearance lookup itself breaks: the list is still served, the confirmation is not" do
    allow(System::AssignmentClearanceService).to receive(:served_for).and_raise(ActiveRecord::StatementInvalid, "boom")

    data = fetch

    expect(data["modules"]).to eq([])
    expect(Array(data["confirmed_unassigned"])).to eq([])
  end
end
