# frozen_string_literal: true

require "rails_helper"

# IMP-051f3811ac60 — network creation was ungated on BOTH operator surfaces.
#
# The seeded sdwan.network_create policy (system_sdwan_manager_agent.rb), the
# engine registration, and Sdwan::Executors::CreateNetwork all existed — but no
# gate site named the category: NetworksController#create saved inline and
# SdwanTool#create_network called Sdwan::Network.create! directly, so the
# operator's configured policy for standing up a new overlay was decorative
# while UPDATE and DELETE on the same controller have been gated for slices.
#
# THE CALLER SPLIT mirrors peers_create_gating_spec: the two operator surfaces
# are gated; internal composition — ConfigureSdwanForProjectExecutor,
# SdwanFederationComposeExecutor and MultiTenantIsolationExecutor (which
# composes Sdwan::Executors::CreateNetwork directly, not through the gate) —
# stays ungated, because an operator approval in the middle of an automated
# provisioning compose is a deadlock, not a control.
RSpec.describe "Api::V1::System::Sdwan::Networks create gating", type: :request do
  let(:user) { user_with_permissions("system.sdwan.networks.read", "system.sdwan.networks.manage") }
  let(:account) { user.account }

  before do
    Sdwan::Configuration.where(account_id: account.id).delete_all
    Sdwan::Network.where(account_id: account.id).delete_all
  end

  def post_create(attrs = { name: "edge-overlay", description: "perimeter" })
    post "/api/v1/system/sdwan/networks",
         params: { network: attrs }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  # A fresh spec account has no InterventionPolicy rows, so
  # InterventionPolicyService falls through to its require_approval default.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  describe "REST surface" do
    # The finding: this created the row inline behind the permission check, so
    # sdwan.network_create never resolved against anything.
    it "defers the create through the autonomy gate instead of saving inline" do
      post_create

      expect(response).to have_http_status(:accepted)
      expect(json_response_data["pending"]).to eq(true)
      expect(Sdwan::Network.where(account_id: account.id).count).to eq(0),
                                                                    "a network was created without an approval gate"

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "POST did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.network_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreateNetwork")
      expect(deferred.params.dig("attributes", "name")).to eq("edge-overlay")
    end

    it "creates a real network with an auto-allocated /64 on the auto-approve branch" do
      auto_approve_policy!

      post_create

      expect(response).to have_http_status(:created)
      net = json_response_data["network"]
      expect(net["name"]).to eq("edge-overlay")
      # Not merely a row: the gated path must produce the same network the
      # ungated one did — allocator-assigned cidr and default status included.
      expect(net["cidr_64"]).to match(%r{\Afd[0-9a-f:]+::/64\z})
      expect(net["status"]).to eq("registered")
      expect(Sdwan::Network.find_by(account_id: account.id, name: "edge-overlay")).to be_present
    end

    it "creates the network when the parked operation is approved" do
      post_create
      approve_latest_deferred!

      net = Sdwan::Network.find_by(account_id: account.id, name: "edge-overlay")
      expect(net).to be_present, "approving the deferred op did not create the network"
      expect(net.cidr_64).to match(%r{\Afd[0-9a-f:]+::/64\z})
    end

    # Pre-check pinned as a PROPERTY: a doomed payload must fail in front of
    # the caller, not park an approval that can only ever fail.
    it "answers 422 with field errors and opens no gate row for an invalid payload" do
      Sdwan::Network.create!(account_id: account.id, name: "duplicate")

      expect { post_create(name: "duplicate") }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      details = json_response.dig("details", "errors") || []
      expect(details.join(" ") + " " + json_response["message"].to_s)
        .to include("has already been taken")
    end
  end

  describe "MCP surface" do
    let(:tool) { ::Ai::Tools::SdwanTool.new(account: account, user: user) }

    def create_via_mcp(name: "mcp-overlay", options: { "mtu" => 1380 })
      tool.execute(params: { action: "system_sdwan_create_network", name: name,
                             description: "via mcp", options: options })
    end

    it "defers create_network through the autonomy gate" do
      result = create_via_mcp

      expect(Sdwan::Network.where(account_id: account.id).count).to eq(0),
                                                                    "the MCP surface created a network without an approval gate"
      expect(result[:success]).to be(true)
      expect(result.dig(:data, :pending)).to be(true)

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "create_network did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.network_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreateNetwork")
      expect(deferred.params.dig("attributes", "name")).to eq("mcp-overlay")
    end

    it "creates a real network on the auto-approve branch, settings included" do
      auto_approve_policy!

      result = create_via_mcp

      expect(result[:success]).to be(true)
      net = Sdwan::Network.find_by(account_id: account.id, name: "mcp-overlay")
      expect(net).to be_present
      expect(net.settings["mtu"]).to eq(1380)
      expect(result.dig(:data, :network, :name)).to eq("mcp-overlay")
    end

    it "refuses an invalid payload loudly without parking anything" do
      Sdwan::Network.create!(account_id: account.id, name: "duplicate")

      expect { @result = create_via_mcp(name: "duplicate") }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(@result[:success]).to be(false)
      expect(@result[:error]).to include("has already been taken")
    end
  end

  describe "internal composition stays ungated" do
    it "does not gate the direct Sdwan::Network.create! the provisioning composers use" do
      expect {
        Sdwan::Network.create!(account_id: account.id, name: "composed-net")
      }.not_to change(::Ai::DeferredOperation, :count)
    end
  end
end
