# frozen_string_literal: true

require "rails_helper"

# Trust-boundary coverage for the access-grant controller (previously zero
# request-spec coverage). An access grant is a VPN-access credential: every
# action requires sdwan.user_devices.manage, grants are scoped to the
# account-scoped network (cross-account / cross-network IDOR -> 404), and the
# revoke action (which cuts VPN access immediately) is approval-gated behind
# that permission.
#
# DELETE is strictly more destructive than :revoke — AccessGrant declares
# `has_many :user_devices, dependent: :destroy`, so it hard-deletes the grant,
# every VPN device row beneath it, and (via the VaultCredential after_destroy
# hook) each device's WireGuard private key in Vault. It is therefore gated the
# same way, and the destroy has to live in the executor: gate! never calls
# on_proceed on its :pending branch, and :pending is the normal branch for a
# require_approval category.
RSpec.describe "Api::V1::System::Sdwan::AccessGrants", type: :request do
  let(:account)  { create(:account) }
  let(:manager)  { user_with_permissions("system.sdwan.user_devices.manage", account: account) }
  let(:stranger) { user_with_permissions("system.sdwan.networks.read", account: account) }
  let(:network)  { create(:sdwan_network, account: account) }

  # Forces the gate's :proceed branch, where the executor runs inline and the
  # controller's on_proceed lambda renders. The seeded policy is
  # require_approval, so nothing else in this file covers that branch.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  describe "GET /api/v1/system/sdwan/networks/:network_id/access_grants" do
    it "forbids callers without sdwan.user_devices.manage" do
      get "/api/v1/system/sdwan/networks/#{network.id}/access_grants", headers: auth_headers_for(stranger)
      expect(response).to have_http_status(:forbidden)
    end

    it "404s for a network in another account (IDOR guard)" do
      foreign_net = create(:sdwan_network) # different account

      get "/api/v1/system/sdwan/networks/#{foreign_net.id}/access_grants", headers: auth_headers_for(manager)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/system/sdwan/networks/:network_id/access_grants/:id" do
    it "404s for a grant that belongs to a different network (cross-network IDOR)" do
      other_net = create(:sdwan_network, account: account)
      grant     = create(:sdwan_access_grant, account: account, network: other_net)

      # Fetched under `network`, not its own `other_net` -> not found.
      get "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}",
          headers: auth_headers_for(manager)

      expect(response).to have_http_status(:not_found)
    end
  end

  # The update surface is the third route to the `status` column. :revoke and
  # DELETE are both approval-gated; a bare PUT reached the same state with no
  # gate, in both directions — resurrecting a revoked grant (restoring VPN
  # access) and half-revoking an active one (flipping status while
  # AccessGrant#revoke!'s device cascade and revoked_at stamp never ran).
  # Status now moves only through the gated verbs; update carries tags alone.
  describe "PUT /api/v1/system/sdwan/networks/:network_id/access_grants/:id" do
    it "cannot resurrect a revoked grant" do
      grant = create(:sdwan_access_grant, account: account, network: network)
      device = create(:sdwan_user_device, access_grant: grant)
      grant.revoke!(reason: "operator revoked")

      put "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}",
          params: { access_grant: { status: "active" } },
          headers: auth_headers_for(manager), as: :json

      expect(grant.reload.status).to eq("revoked")
      expect(grant.revoked_at).to be_present
      expect(device.reload.revoked_at).to be_present
    end

    it "cannot half-revoke an active grant, leaving its devices live" do
      grant  = create(:sdwan_access_grant, account: account, network: network)
      device = create(:sdwan_user_device, access_grant: grant)

      put "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}",
          params: { access_grant: { status: "revoked" } },
          headers: auth_headers_for(manager), as: :json

      expect(grant.reload.status).to eq("active")
      expect(grant.revoked_at).to be_nil
      expect(device.reload.revoked_at).to be_nil
    end

    it "cannot suspend a grant, which would block device issuance ungated" do
      grant = create(:sdwan_access_grant, account: account, network: network)

      put "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}",
          params: { access_grant: { status: "suspended" } },
          headers: auth_headers_for(manager), as: :json

      expect(grant.reload.status).to eq("active")
    end

    it "still updates the tags it is meant to carry" do
      grant = create(:sdwan_access_grant, account: account, network: network, tags: [])

      put "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}",
          params: { access_grant: { tags: %w[contractor] } },
          headers: auth_headers_for(manager), as: :json

      expect(response).to have_http_status(:ok)
      expect(grant.reload.tags).to eq(%w[contractor])
    end

    it "forbids callers without sdwan.user_devices.manage" do
      grant = create(:sdwan_access_grant, account: account, network: network)

      put "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}",
          params: { access_grant: { tags: %w[contractor] } },
          headers: auth_headers_for(stranger), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/system/sdwan/networks/:network_id/access_grants/:id/revoke" do
    it "requires sdwan.user_devices.manage (the approval-gated revoke is behind the permission)" do
      grant = create(:sdwan_access_grant, account: account, network: network)

      post "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}/revoke",
           headers: auth_headers_for(stranger), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/system/sdwan/networks/:network_id/access_grants/:id" do
    let(:grant)   { create(:sdwan_access_grant, account: account, network: network) }
    let!(:device) { create(:sdwan_user_device, access_grant: grant, label: "work-laptop") }

    def grant_path = "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}"

    it "requires sdwan.user_devices.manage" do
      delete grant_path, headers: auth_headers_for(stranger)

      expect(response).to have_http_status(:forbidden)
    end

    # The finding: this ran `@grant.destroy!` behind the permission check alone
    # — no gate!, no approval — cascading through dependent: :destroy to every
    # device and its Vault key, while the softer :revoke on the same controller
    # was approval-gated.
    it "defers the destroy for approval instead of hard-deleting inline" do
      delete grant_path, headers: auth_headers_for(manager)

      expect(response).to have_http_status(:accepted)
      expect(Sdwan::AccessGrant.exists?(grant.id)).to be(true),
                                                      "grant was hard-deleted without an approval gate"
      expect(Sdwan::UserDevice.exists?(device.id)).to be(true),
                                                      "device row (and its Vault key) was destroyed without an approval gate"

      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "DELETE did not route through the autonomy gate"
      expect(deferred.executor_class).to eq("Sdwan::Executors::DeleteAccessGrant")
      expect(deferred.params["grant_id"]).to eq(grant.id)
    end

    # gate! never calls on_proceed on the :pending branch, so an approved DELETE
    # must be carried out by the deferred executor itself.
    it "destroys the grant and its devices when the deferred op is approved" do
      delete grant_path, headers: auth_headers_for(manager)
      approve_latest_deferred!

      expect(Sdwan::AccessGrant.exists?(grant.id)).to be(false), "approved DELETE left the grant undestroyed"
      expect(Sdwan::UserDevice.exists?(device.id)).to be(false)
    end

    it "destroys inline when the policy auto-approves" do
      auto_approve_policy!

      delete grant_path, headers: auth_headers_for(manager)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "deleted")).to be(true)
      expect(Sdwan::AccessGrant.exists?(grant.id)).to be(false), "answered deleted: true over a surviving grant"
    end
  end
end
