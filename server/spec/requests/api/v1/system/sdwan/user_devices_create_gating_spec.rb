# frozen_string_literal: true

require "rails_helper"

# IMP-051f3811ac60 — device issuance was ungated on BOTH operator surfaces.
#
# Issuing a Sdwan::UserDevice is the SDWAN family's most material create: it
# mints a WireGuard keypair (private half stored in Vault) and a one-shot
# bootstrap token that serves the full client config, private key included.
# The seeded sdwan.user_device_create policy and the registered category
# existed, and Sdwan::Executors::CreateUserDevice existed — with zero callers,
# and a body that bypassed Sdwan::UserDeviceIssuer entirely (a bare
# `user_devices.create!` mints no keypair, no Vault write, no token — a device
# row that can never connect). Both surfaces called the issuer inline, so the
# operator's configured policy for VPN-device minting was decorative.
#
# TOKEN HANDLING is the delicate part and is pinned below:
#
#   * on the inline (:proceed) branch the caller gets the bootstrap token
#     exactly as before — Ai::AutonomyGate hands the executor's raw return to
#     the surface, preserving the "shown ONCE in the response" contract;
#   * the PERSISTED Ai::DeferredOperation#result must NOT be a durable second
#     copy — Ai::SensitiveParams' "token" pattern masks bootstrap_token at
#     write (execute_now! filters before complete!);
#   * on the approval path the reveal-once slot (take_revealed_result!)
#     carries the token to the approval decision response — the operator-
#     decided shape for one-shot material.
RSpec.describe "Api::V1::System::Sdwan::UserDevices create gating", type: :request do
  let(:account) { create(:account) }
  let(:manager) { user_with_permissions("system.sdwan.user_devices.manage", account: account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:grant)   { create(:sdwan_access_grant, account: account, network: network) }

  def create_path
    "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}/user_devices"
  end

  def post_issue(label: "work-laptop")
    post create_path,
         params: { user_device: { label: label } }.to_json,
         headers: auth_headers_for(manager).merge("Content-Type" => "application/json")
  end

  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  describe "REST surface" do
    it "defers the issue through the autonomy gate instead of minting inline" do
      post_issue

      expect(response).to have_http_status(:accepted)
      expect(json_response_data["pending"]).to eq(true)
      expect(grant.user_devices.reload.count).to eq(0),
                                                 "a VPN device (keypair + bootstrap token) was minted without an approval gate"

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "POST did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.user_device_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreateUserDevice")
      expect(deferred.params["grant_id"]).to eq(grant.id)
      expect(deferred.params["label"]).to eq("work-laptop")
    end

    it "mints a working device + one-shot bootstrap token on the auto-approve branch" do
      auto_approve_policy!

      post_issue

      expect(response).to have_http_status(:created)
      device = grant.user_devices.reload.first
      expect(device).to be_present
      # Not merely a row: the gated path must go through UserDeviceIssuer —
      # keypair minted, address allocated — or the device can never connect.
      expect(device.public_key).to match(%r{\A[A-Za-z0-9+/]{43}=\z})
      expect(device.assigned_address).to be_present

      body = json_response_data
      expect(body.dig("user_device", "id")).to eq(device.id)
      token = body.dig("bootstrap", "token")
      expect(token).to be_present, "the one-shot bootstrap token was not returned on the inline branch"
      expect(body.dig("bootstrap", "url")).to eq("/api/v1/system/sdwan/bootstrap/#{token}")
      expect(body.dig("bootstrap", "expires_at")).to be_present
      expect(::Sdwan::UserDeviceIssuer.verify_bootstrap_token!(token)[:device_id]).to eq(device.id)
    end

    it "mints the device when the parked operation is approved, and persists no plaintext token" do
      post_issue
      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      approve_latest_deferred!

      device = grant.user_devices.reload.first
      expect(device).to be_present, "approving the deferred op did not mint the device"
      expect(device.public_key).to match(%r{\A[A-Za-z0-9+/]{43}=\z})

      # Redaction-at-rest: the persisted result must not be a durable second
      # copy of the bootstrap token outside Vault.
      persisted = deferred.reload.result
      expect(persisted.dig("data", "bootstrap_token")).to eq(::Ai::SensitiveParams::MASK),
                                                          "the deferred operation row persisted the plaintext bootstrap token"
    end

    # Pre-checks pinned as PROPERTIES: a doomed request refuses fast AND parks
    # nothing an operator would have to dispose of.
    it "refuses an inactive grant up front without parking an approval" do
      grant.update!(status: "suspended")

      expect { post_issue }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["error"].to_s).to include("not active")
    end

    it "refuses a blank label up front without parking an approval" do
      expect { post_issue(label: "") }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a duplicate label on the same grant up front without parking an approval" do
      create(:sdwan_user_device, access_grant: grant, label: "work-laptop")

      expect { post_issue(label: "work-laptop") }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["error"].to_s).to include("already been taken")
    end
  end

  describe "MCP surface" do
    let(:tool) { ::Ai::Tools::SdwanTool.new(account: account, user: manager) }

    def issue_via_mcp(label: "phone")
      tool.execute(params: { action: "system_sdwan_issue_user_device",
                             access_grant_id: grant.id, label: label })
    end

    it "defers issue_user_device through the autonomy gate" do
      result = issue_via_mcp

      expect(grant.user_devices.reload.count).to eq(0),
                                                 "the MCP surface minted a VPN device without an approval gate"
      expect(result[:success]).to be(true)
      expect(result.dig(:data, :pending)).to be(true)

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "issue_user_device did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.user_device_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreateUserDevice")
    end

    it "keeps the exact pre-gate response shape on the auto-approve branch" do
      auto_approve_policy!

      result = issue_via_mcp

      expect(result[:success]).to be(true)
      device = grant.user_devices.reload.first
      expect(device).to be_present
      expect(device.public_key).to match(%r{\A[A-Za-z0-9+/]{43}=\z})
      expect(result.dig(:data, :device, :id)).to eq(device.id)
      expect(result.dig(:data, :bootstrap_url)).to match(%r{\A/api/v1/system/sdwan/bootstrap/.+})
      expect(result.dig(:data, :expires_at)).to be_present
    end

    it "refuses an inactive grant loudly without parking anything" do
      grant.update!(status: "suspended")

      expect { @result = issue_via_mcp }.not_to change(::Ai::DeferredOperation, :count)

      expect(@result[:success]).to be(false)
      expect(@result[:error]).to include("not active")
    end

    it "refuses an invalid label loudly without parking anything" do
      create(:sdwan_user_device, access_grant: grant, label: "phone")

      expect { @result = issue_via_mcp(label: "phone") }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(@result[:success]).to be(false)
      expect(@result[:error]).to include("already been taken")
    end
  end
end
