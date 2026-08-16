# frozen_string_literal: true

require "rails_helper"

# Sdwan::Executors::RevokeUserDevice is the device-scoped executor behind both
# device verbs on UserDevicesController. Its contract is narrow and safety
# critical: touch exactly ONE device, never the grant, never a sibling.
RSpec.describe Sdwan::Executors::RevokeUserDevice, type: :model do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:grant)   { create(:sdwan_access_grant, account: account, network: network) }

  let!(:target)  { create(:sdwan_user_device, access_grant: grant, label: "lost-phone") }
  let!(:sibling) { create(:sdwan_user_device, access_grant: grant, label: "work-laptop") }

  describe "soft revoke (no destroy_row)" do
    it "revokes only the named device, leaving the sibling and the grant alone" do
      result = described_class.execute(
        { grant_id: grant.id, device_id: target.id, reason: "lost at the airport" },
        deferred_operation: nil
      )

      expect(result[:success]).to be(true)
      expect(result.dig(:data, :revoked)).to be(true)
      expect(result.dig(:data, :destroyed)).to be(false)

      expect(target.reload.revoked?).to be(true)
      expect(target.revocation_reason).to eq("lost at the airport")
      expect(sibling.reload.revoked?).to be(false)
      expect(grant.reload.status).to eq("active")
    end

    it "keeps the row for audit" do
      described_class.execute({ grant_id: grant.id, device_id: target.id }, deferred_operation: nil)

      expect(Sdwan::UserDevice.exists?(target.id)).to be(true)
    end
  end

  describe "hard delete (destroy_row)" do
    it "destroys only the named device row" do
      result = described_class.execute(
        { grant_id: grant.id, device_id: target.id, destroy_row: true },
        deferred_operation: nil
      )

      expect(result[:success]).to be(true)
      expect(result.dig(:data, :destroyed)).to be(true)

      expect(Sdwan::UserDevice.exists?(target.id)).to be(false)
      expect(Sdwan::UserDevice.exists?(sibling.id)).to be(true)
      expect(sibling.reload.revoked?).to be(false)
      expect(grant.reload.status).to eq("active")
    end

    # DELETE means the row goes, even if the device was soft-revoked earlier.
    # The controller answers `deleted: true`, so anything short of destroying
    # the row makes that response a lie. (The old on_proceed lambda skipped
    # already-revoked devices and returned deleted: true anyway.)
    it "destroys a device that was already soft-revoked" do
      target.revoke!(reason: "revoked last week")

      described_class.execute(
        { grant_id: grant.id, device_id: target.id, destroy_row: true },
        deferred_operation: nil
      )

      expect(Sdwan::UserDevice.exists?(target.id)).to be(false)
    end

    # Deferred params round-trip through a jsonb column, so the flag can come
    # back as a string rather than a boolean.
    it "honors a string destroy_row flag" do
      described_class.execute(
        { "grant_id" => grant.id, "device_id" => target.id, "destroy_row" => "true" },
        deferred_operation: nil
      )

      expect(Sdwan::UserDevice.exists?(target.id)).to be(false)
    end
  end

  describe "scoping" do
    it "refuses a device that belongs to a different grant" do
      other_grant  = create(:sdwan_access_grant, account: account, network: create(:sdwan_network, account: account))
      other_device = create(:sdwan_user_device, access_grant: other_grant)

      expect {
        described_class.execute({ grant_id: grant.id, device_id: other_device.id }, deferred_operation: nil)
      }.to raise_error(ActiveRecord::RecordNotFound)

      expect(other_device.reload.revoked?).to be(false)
    end
  end

  describe "preview" do
    # IMP-8e4674f4d62d — the label resolves through Base#scoped_label_record,
    # anchored on the GRANT (system_sdwan_user_devices has no account_id of its
    # own), so the preview needs the operation's account. Cross-account
    # coverage lives in
    # spec/services/system/executors/preview_account_anchor_spec.rb.
    def anchored_preview(params)
      described_class.preview(
        params,
        deferred_operation: ::Ai::DeferredOperation.create!(
          account: account,
          action_category: "system.sdwan_user_device_revoke",
          executor_class: described_class.name,
          params: params
        )
      )
    end

    it "summarizes the verb it will actually perform" do
      expect(anchored_preview({ grant_id: grant.id, device_id: target.id })[:summary])
        .to eq("Revoke SDWAN user device lost-phone")
      expect(anchored_preview({ grant_id: grant.id, device_id: target.id, destroy_row: true })[:summary])
        .to eq("Delete SDWAN user device lost-phone")
    end

    # The pre-gate contract base.rb documents: no anchor, no name — the id is
    # the floor.
    it "declines to name the device when there is no account to anchor on" do
      preview = described_class.preview({ grant_id: grant.id, device_id: target.id })

      expect(preview[:summary]).to eq("Revoke SDWAN user device #{target.id}")
    end
  end
end
