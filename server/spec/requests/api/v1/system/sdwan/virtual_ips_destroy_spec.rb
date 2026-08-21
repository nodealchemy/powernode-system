# frozen_string_literal: true

require "rails_helper"

# IMP-800b25c1cc45 — VirtualIpsController#destroy was gated
# (sdwan.virtual_ip_delete) but had no request spec at all: neither branch.
#
# Its :proceed branch raised. The on_proceed lambda swept lingering holder rows
# through `::Sdwan::VipAssignment` — a constant that does not exist; the model
# is `Sdwan::VirtualIpAssignment` (table system_sdwan_virtual_ip_assignments)
# and its FK is sdwan_virtual_ip_id, not virtual_ip_id. So an operator holding
# a notify_and_proceed row for this category got a 500 for a destroy that had
# already succeeded — the executor runs inside the gate, before on_proceed.
#
# It survived because :pending is the default tier and therefore the branch any
# casual check exercises; gate! never calls on_proceed there, so the dead
# constant is unreachable from the normal path. That is the whole reason both
# branches are asserted below rather than the one that a fresh account gets.
#
# The sweep itself is belt-and-braces: VirtualIp declares
# `has_many :assignments, dependent: :destroy`, so the executor's destroy!
# already takes the holder rows with it. Keeping it (correctly spelled) costs
# one no-op query and keeps the verb idempotent if that association ever loses
# its dependent: option.
RSpec.describe "Api::V1::System::Sdwan::VirtualIps destroy", type: :request do
  let(:account) { create(:account) }
  let(:manager) { user_with_permissions("system.sdwan.vips.manage", account: account) }
  let(:reader)  { user_with_permissions("system.sdwan.vips.read", account: account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:holder)  { create(:sdwan_peer, account: account, network: network) }
  let!(:vip)    { create(:sdwan_virtual_ip, network: network) }

  def member_path = "/api/v1/system/sdwan/networks/#{network.id}/virtual_ips/#{vip.id}"

  def delete_vip(user: manager)
    delete member_path, headers: auth_headers_for(user), as: :json
  end

  # A live holder row — the shape the on_proceed sweep exists for.
  def assign_holder!
    ::Sdwan::VirtualIpAssignment.create!(
      virtual_ip: vip, peer: holder, assumed_at: Time.current,
      reason: "initial", released_at: nil
    )
  end

  it "requires system.sdwan.vips.manage" do
    delete_vip(user: reader)

    expect(response).to have_http_status(:forbidden)
    expect(::Sdwan::VirtualIp.exists?(vip.id)).to be(true)
  end

  describe "the :pending branch (the default tier)" do
    it "parks the destroy instead of freeing the address" do
      assign_holder!

      delete_vip

      expect(response).to have_http_status(:accepted)
      expect(::Sdwan::VirtualIp.exists?(vip.id)).to be(true),
                                                   "the VIP was destroyed before any approval"
      op = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(op).to be_present, "no deferred operation was parked — the destroy ran inline"
      expect(op.action_category).to eq("sdwan.virtual_ip_delete")
      expect(op.executor_class).to eq("Sdwan::Executors::DeleteVirtualIp")
      expect(op.params["vip_id"]).to eq(vip.id)
    end

    it "leaves the live holder row unreleased while the destroy is parked" do
      assignment = assign_holder!

      delete_vip

      expect(response).to have_http_status(:accepted)
      expect(assignment.reload.released_at).to be_nil
    end

    it "destroys the VIP and its holder history once the operation is approved" do
      assignment = assign_holder!

      delete_vip
      expect(response).to have_http_status(:accepted)

      approve_latest_deferred!

      expect(::Sdwan::VirtualIp.exists?(vip.id)).to be(false)
      expect(::Sdwan::VirtualIpAssignment.exists?(assignment.id)).to be(false)
    end
  end

  # The branch the dead constant lived on. The status assertion is what
  # separates "the row is gone because the destroy worked" from "the row is
  # gone and then the response blew up" — the executor writes inside the gate,
  # so a raise in on_proceed leaves the destroy applied and answers 500.
  describe "the :proceed branch (seeded notify_and_proceed row)" do
    before { seed_operator_policy!("sdwan.virtual_ip_delete") }

    it "destroys inline and answers 200, not a 500 from the post-destroy sweep" do
      delete_vip

      expect(response).to have_http_status(:ok),
                          "destroy answered #{response.status}: #{response.body}"
      expect(response.parsed_body.dig("data", "deleted")).to be(true)
      expect(response.parsed_body.dig("data", "id")).to eq(vip.id)
      expect(::Sdwan::VirtualIp.exists?(vip.id)).to be(false)
    end

    it "answers 200 with a live holder row present, which is what the sweep is for" do
      assignment = assign_holder!

      delete_vip

      expect(response).to have_http_status(:ok),
                          "destroy answered #{response.status}: #{response.body}"
      expect(::Sdwan::VirtualIp.exists?(vip.id)).to be(false)
      expect(::Sdwan::VirtualIpAssignment.exists?(assignment.id)).to be(false)
    end

    it "still goes through the gate rather than round the side of it" do
      delete_vip

      expect(response).to have_http_status(:ok)
      expect(::Ai::DeferredOperation.order(created_at: :desc).first&.executor_class)
        .to eq("Sdwan::Executors::DeleteVirtualIp"),
            "notify_and_proceed destroy bypassed the gate entirely"
    end
  end

  it "404s for a VIP on a network in another account (IDOR guard)" do
    other = create(:account)
    foreign = create(:sdwan_virtual_ip, network: create(:sdwan_network, account: other))

    expect {
      delete "/api/v1/system/sdwan/networks/#{network.id}/virtual_ips/#{foreign.id}",
             headers: auth_headers_for(manager), as: :json
      expect(response).to have_http_status(:not_found)
    }.not_to change(::Ai::DeferredOperation, :count)

    expect(::Sdwan::VirtualIp.exists?(foreign.id)).to be(true)
  end
end
