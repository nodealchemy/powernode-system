# frozen_string_literal: true

require "rails_helper"

# Trust-boundary coverage for the user-device controller (previously zero
# request-spec coverage).
#
# A Sdwan::UserDevice is one VPN client config; an Sdwan::AccessGrant holds
# MANY of them (UserDeviceIssuer.issue! mints a new device per issuance on a
# shared grant). Both device-level verbs — POST :revoke (soft) and DELETE
# (hard) — are approval-gated, and both must scope their effect to the ONE
# device named in the URL. Revoking a lost phone must not cut the user's
# other devices, and must not revoke the grant itself (grant revocation is
# one-way: access has to be re-granted and every device re-issued).
#
# `system.sdwan_user_device_revoke` resolves to require_approval, so these
# requests return 202 + a deferred operation rather than executing inline.
# The device-scoping contract therefore has to hold on the DEFERRED executor,
# which is what runs when an operator later approves.
RSpec.describe "Api::V1::System::Sdwan::UserDevices", type: :request do
  let(:account)  { create(:account) }
  let(:manager)  { user_with_permissions("system.sdwan.user_devices.manage", account: account) }
  let(:stranger) { user_with_permissions("system.sdwan.networks.read", account: account) }
  let(:network)  { create(:sdwan_network, account: account) }
  let(:grant)    { create(:sdwan_access_grant, account: account, network: network) }

  # The device under operation, plus a sibling on the SAME grant that must
  # survive untouched — the sibling is the whole point of these specs.
  let!(:target)  { create(:sdwan_user_device, access_grant: grant, label: "lost-phone") }
  let!(:sibling) { create(:sdwan_user_device, access_grant: grant, label: "work-laptop") }

  def device_path(device)
    "/api/v1/system/sdwan/networks/#{network.id}/access_grants/#{grant.id}/user_devices/#{device.id}"
  end

  # Executes the deferred operation the gate parked. This is the tail of the
  # approval path (Ai::ApprovalRequest ultimately calls execute_now!), not the
  # whole of it — the approval-chain hop itself is core-owned and untouched here.
  def approve_latest_deferred!
    Ai::DeferredOperation.order(created_at: :desc).first.tap(&:execute_now!)
  end

  # Forces the gate's :proceed branch, where the executor runs inline and the
  # controller's on_proceed lambda renders. The default policy is
  # require_approval, so nothing else in this file covers that branch.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  describe "POST .../user_devices/:id/revoke" do
    it "requires system.sdwan.user_devices.manage" do
      post "#{device_path(target)}/revoke", headers: auth_headers_for(stranger)

      expect(response).to have_http_status(:forbidden)
    end

    it "defers a DEVICE-scoped revoke carrying the device_id" do
      post "#{device_path(target)}/revoke", headers: auth_headers_for(manager)

      expect(response).to have_http_status(:accepted)
      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred.executor_class).to eq("Sdwan::Executors::RevokeUserDevice")
      expect(deferred.params["device_id"]).to eq(target.id)
    end

    it "revokes ONLY the named device when the deferred op is approved" do
      post "#{device_path(target)}/revoke", headers: auth_headers_for(manager)
      approve_latest_deferred!

      expect(target.reload.revoked?).to be(true)
      expect(sibling.reload.revoked?).to be(false), "sibling device was revoked — device revoke leaked to the whole grant"
      expect(grant.reload.status).to eq("active"), "access grant was revoked by a DEVICE-level revoke"
    end
  end

  describe "DELETE .../user_devices/:id" do
    it "requires system.sdwan.user_devices.manage" do
      delete device_path(target), headers: auth_headers_for(stranger)

      expect(response).to have_http_status(:forbidden)
    end

    it "defers a DEVICE-scoped delete carrying the device_id" do
      delete device_path(target), headers: auth_headers_for(manager)

      expect(response).to have_http_status(:accepted)
      deferred = Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred.executor_class).to eq("Sdwan::Executors::RevokeUserDevice")
      expect(deferred.params["device_id"]).to eq(target.id)
    end

    # gate! never calls on_proceed on the :pending branch, so the controller's
    # destroy lambda does NOT run for an approved DELETE. The row therefore has
    # to be destroyed by the deferred executor itself.
    it "destroys ONLY the named device row when the deferred op is approved" do
      delete device_path(target), headers: auth_headers_for(manager)
      approve_latest_deferred!

      expect(Sdwan::UserDevice.exists?(target.id)).to be(false), "deferred DELETE left the device row undestroyed"
      expect(Sdwan::UserDevice.exists?(sibling.id)).to be(true), "deferred DELETE destroyed a sibling device"
      expect(sibling.reload.revoked?).to be(false), "sibling device was revoked by a single-device DELETE"
      expect(grant.reload.status).to eq("active"), "access grant was revoked by a DEVICE-level delete"
    end

    # The executor now owns the destroy, so the inline branch has to be checked
    # separately: `deleted: true` must not be returned over a surviving row.
    it "destroys the row inline when the policy auto-approves" do
      auto_approve_policy!

      delete device_path(target), headers: auth_headers_for(manager)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "deleted")).to be(true)
      expect(Sdwan::UserDevice.exists?(target.id)).to be(false), "answered deleted: true over a surviving row"
      expect(Sdwan::UserDevice.exists?(sibling.id)).to be(true)
      expect(grant.reload.status).to eq("active")
    end
  end
end
