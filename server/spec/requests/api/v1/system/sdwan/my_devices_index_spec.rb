# frozen_string_literal: true

require "rails_helper"

# Coverage for the caller's-own-devices INDEX
# (GET /api/v1/system/sdwan/my_devices) — increment 3a of the agent-issued
# device design. Increment 2 gave a recipient a route to fetch their config
# by device id, but nothing told them the id existed; this is the thing that
# does. See my_devices_controller.rb for why ownership alone authorizes.
#
# This endpoint returns JSON (id/label/status/timestamps), NOT the WireGuard
# config text `#show` serves — an index has no reason to touch key material
# at all, so unlike my_device_config_spec.rb there is no key to legitimately
# assert the PRESENCE of anywhere in this file, only its absence.
RSpec.describe "Api::V1::System::Sdwan::MyDevices index", type: :request do
  let(:account)  { create(:account) }
  let(:owner)    { create(:user, account: account) }
  # Same account, no grant of their own by default — used for the "no
  # grants" empty-list example. Gets its own grant only in the example that
  # needs one.
  let(:intruder) { create(:user, account: account) }

  let(:network) { create(:sdwan_network, account: account) }
  let(:grant)   { create(:sdwan_access_grant, account: account, network: network, user: owner) }

  def index_path
    "/api/v1/system/sdwan/my_devices"
  end

  def json_body
    JSON.parse(response.body)
  end

  def device_ids
    json_body["data"]["devices"].map { |d| d["id"] }
  end

  describe "the owner" do
    # THE DISCRIMINATING EXAMPLE. "The owner sees a device" is satisfied by a
    # scope returning every device in the table; this only passes if the
    # scope also EXCLUDES a device belonging to someone else entirely.
    it "sees both of their own devices, and not a second user's device" do
      laptop = ::Sdwan::UserDeviceIssuer.issue!(
        grant: grant, label: "laptop", mint_bootstrap_token: false
      )[:device]
      desktop = ::Sdwan::UserDeviceIssuer.issue!(
        grant: grant, label: "desktop", mint_bootstrap_token: false
      )[:device]

      other_account = create(:account)
      other_user    = create(:user, account: other_account)
      other_network = create(:sdwan_network, account: other_account)
      other_grant   = create(:sdwan_access_grant, account: other_account, network: other_network, user: other_user)
      other_device  = ::Sdwan::UserDeviceIssuer.issue!(
        grant: other_grant, label: "someone-elses-phone", mint_bootstrap_token: false
      )[:device]

      get index_path, headers: auth_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(device_ids).to contain_exactly(laptop.id, desktop.id)
      expect(device_ids).not_to include(other_device.id)
    end

    # THE VARIANT THAT CATCHES A LOST JOIN BINDING (per my_device_config_spec).
    # A no-grant stranger passes even against a scope that filters on "caller
    # has SOME grant" rather than "the grant joined to THIS device is the
    # caller's". A grant-holding intruder on the SAME network is the only
    # case that tells the two apart.
    it "does not see another user's devices even when the caller holds an active grant of their own" do
      owner_device = create(:sdwan_user_device, access_grant: grant, label: "laptop")

      intruder_grant  = create(:sdwan_access_grant, account: account, network: network, user: intruder)
      intruder_device = create(:sdwan_user_device, access_grant: intruder_grant, label: "intruder-laptop")

      get index_path, headers: auth_headers_for(intruder)

      expect(response).to have_http_status(:ok)
      expect(device_ids).to contain_exactly(intruder_device.id)
      expect(device_ids).not_to include(owner_device.id)
    end

    it "returns an empty list, not an error, for a caller with no grants" do
      get index_path, headers: auth_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(json_body["data"]["devices"]).to eq([])
    end

    # NO KEY MATERIAL RULE. Uses a REAL minted key (per my_device_config_spec)
    # rather than the bare factory, so the absence assertion is not vacuous:
    # if the controller ever started rendering a device's key material, this
    # would fail. `expect(body).to include(key)` is deliberately never
    # written the other way around here — that would print the key on red.
    it "carries no key material in the response body" do
      issued = ::Sdwan::UserDeviceIssuer.issue!(grant: grant, label: "laptop", mint_bootstrap_token: false)
      device = issued[:device]
      private_key = ::Sdwan::UserDevice.find(device.id).private_key_b64
      expect(private_key.to_s.empty?).to be(false),
                                         "setup produced no private key to assert on — the vault/DB " \
                                         "credential round-trip is broken, so this example proves nothing"

      get index_path, headers: auth_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.body.include?(private_key)).to be(false),
                                                      "index body disclosed a device's private key"
      expect(response.body.include?("encrypted_credentials")).to be(false),
                                                                 "index body carried the raw vault credential column"
      expect(response.body.include?(device.public_key)).to be(false),
                                                            "index body carried a raw device key column"
    end
  end

  describe "an unauthenticated caller" do
    it "is refused" do
      get index_path

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # Mirrors my_device_config_spec's WORKER coverage: authenticate_request
  # also succeeds for a worker principal (bearer worker token, or forwarded
  # mTLS client cert), which leaves current_user nil. The same guard #show
  # uses is reused here rather than re-derived.
  describe "a WORKER principal (mTLS, no user)" do
    let(:worker) { create(:worker, account: account) }

    it "is refused" do
      get index_path, headers: worker_mtls_headers(worker)

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
