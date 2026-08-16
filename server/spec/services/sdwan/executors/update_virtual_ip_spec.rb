# frozen_string_literal: true

require "rails_helper"

# IMP-0e44cf2fc80b — executor-side-effect migration, VIP update.
#
# VirtualIpsController#update ran sync_assignments_after_holder_change!
# (the holder audit trail: close assignments for departed holders, open them
# for arrivals) INLINE after its write. gate! never calls on_proceed on the
# :pending branch — the executor is the sole writer there — so gating this
# verb with a bare update!(attrs) executor would apply an operator-APPROVED
# holder change to the row while silently dropping the assignment sync:
# phantom current state with no history row. The sync therefore lives HERE,
# so it fires on both the immediate (:proceed) and the approved
# (execute_now!) path.
#
# The load-bearing example is the APPROVED path: a naive wiring passes the
# :proceed test and fails only that one.
RSpec.describe Sdwan::Executors::UpdateVirtualIp do
  let(:account)    { create(:account) }
  let(:user)       { create(:user, account: account) }
  let(:network)    { create(:sdwan_network, account: account) }
  let(:old_holder) { create(:sdwan_peer, account: account, network: network) }
  let(:new_holder) { create(:sdwan_peer, account: account, network: network) }

  let!(:vip) do
    create(:sdwan_virtual_ip, account: account, network: network,
                              state: "active", holder_peer_ids: [ old_holder.id ])
  end
  let!(:current_assignment) do
    vip.assignments.create!(peer: old_holder, assumed_at: 1.hour.ago, reason: "initial")
  end

  def deferred_for(params)
    ::Ai::DeferredOperation.create!(
      account: account,
      requested_by: user,
      action_category: "sdwan.virtual_ip_update",
      executor_class: "Sdwan::Executors::UpdateVirtualIp",
      params: params,
      source_type: "Sdwan::VirtualIp",
      source_id: vip.id
    )
  end

  # Captures rather than asserting `raise_error` first: an example whose first
  # assertion is raise_error aborts on "nothing was raised" and never reports
  # the effect it exists to prevent (IMP-2d26f7289c38).
  def run(params)
    described_class.execute(params, deferred_operation: deferred_for(params))
    nil
  rescue StandardError => e
    e
  end

  it "applies an in-account update" do
    error = run({ vip_id: vip.id, attributes: { description: "edge vip" } })

    expect(error).to be_nil
    expect(vip.reload.description).to eq("edge vip")
  end

  # The finding: the controller's inline sync only ever ran on the :proceed
  # branch. Driving the deferred operation the way the approval tail does
  # (Ai::ApprovalRequest ultimately calls execute_now!) proves the audit
  # trail survives the approval window.
  it "syncs holder assignments when an APPROVED holder change executes" do
    deferred = deferred_for({ vip_id: vip.id,
                              attributes: { holder_peer_ids: [ new_holder.id ] } })

    deferred.execute_now!

    expect(vip.reload.holder_peer_ids).to eq([ new_holder.id ])
    expect(current_assignment.reload.released_at).to be_present,
                                                     "approved holder change never released the departed holder's assignment row"

    arrived = vip.assignments.where(sdwan_peer_id: new_holder.id, released_at: nil).first
    expect(arrived).to be_present,
                       "approved holder change left phantom holder state with no assignment history row"
    expect(arrived.reason).to eq("holder_changed")
    expect(arrived.triggered_by_user_id).to eq(user.id),
                                            "the assignment must attribute the REQUESTING operator across the approval window"
  end

  # Positive twin: a non-holder update must not churn the assignment history.
  it "leaves assignment rows untouched when holders are unchanged" do
    error = run({ vip_id: vip.id, attributes: { description: "no holder change" } })

    expect(error).to be_nil
    expect(vip.reload.assignments.count).to eq(1)
    expect(current_assignment.reload.released_at).to be_nil
  end

  # IMP-bf996c7abcb4 ruling, VIP resource: `attrs` drops account/account_id
  # (the tenancy MOVE) but sdwan_network_id is equally tenancy-bearing, and
  # Sdwan::VirtualIp's own guard is RELATIVE — holder_peers_belong_to_network
  # compares holders against the VIP's network, never against this
  # operation's account. A payload naming a foreign network AND that
  # network's peers satisfies every validation while account_id stays the
  # caller's — and Sdwan::TopologyCompiler#vips_held_by walks
  # @network.virtual_ips, so the row lands in the victim network's agent
  # payloads.
  it "refuses to re-parent the VIP into another account's network" do
    foreign_network = create(:sdwan_network)
    foreign_holder  = create(:sdwan_peer, account: foreign_network.account,
                                          network: foreign_network)

    error = run({
                  vip_id: vip.id,
                  attributes: {
                    sdwan_network_id: foreign_network.id,
                    holder_peer_ids: [ foreign_holder.id ]
                  }
                })

    expect(vip.reload.sdwan_network_id).to eq(network.id),
                                           "the VIP was re-parented into another account's overlay"
    expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
    # The refusal must not echo the victim's identifiers back to the caller.
    expect(error.message).not_to include(foreign_network.account_id)
  end

  it "allows an in-account re-parent to a sibling network" do
    sibling        = create(:sdwan_network, account: account)
    sibling_holder = create(:sdwan_peer, account: account, network: sibling)

    error = run({
                  vip_id: vip.id,
                  attributes: {
                    sdwan_network_id: sibling.id,
                    holder_peer_ids: [ sibling_holder.id ]
                  }
                })

    expect(error).to be_nil
    expect(vip.reload.sdwan_network_id).to eq(sibling.id)
  end

  # #summarize is the approval/notification body
  # (Ai::DeferredOperationApprovalContent renders preview[:summary]). The
  # sentence matches VirtualIpsController#update's gate description verbatim
  # so the two surfaces naming this one operation cannot disagree
  # (IMP-3a563becb7d7 / IMP-ee57d0fbe859, UpdatePortMapping precedent); the
  # bare id is only the floor for a row already gone.
  describe ".preview" do
    # IMP-8e4674f4d62d — the label resolves through Base#scoped_label_record,
    # so it needs the operation's account to anchor on; `deferred_for` is this
    # file's existing builder. Cross-account coverage lives in
    # spec/services/system/executors/preview_account_anchor_spec.rb.
    def anchored_preview(params)
      described_class.preview(params, deferred_operation: deferred_for(params))
    end

    it "names the VIP and network an operator recognises, not a bare UUID" do
      vip.update!(name: "svc-vip")
      network.update!(name: "wan-core")

      preview = anchored_preview({ vip_id: vip.id })

      expect(preview[:summary]).to eq("Update SDWAN VIP 'svc-vip' on network wan-core")
    end

    # The pre-gate contract base.rb documents: no anchor, no name.
    it "declines to name the VIP when there is no account to anchor on" do
      vip.update!(name: "svc-vip")

      preview = described_class.preview({ vip_id: vip.id })

      expect(preview[:summary]).to eq("Update VIP #{vip.id}")
    end

    # Anchored on purpose: unanchored it would pass because there is no
    # account, not because the row is gone, leaving the missing-row arm
    # untested and duplicating the example above.
    it "falls back to the bare id when the VIP is gone" do
      preview = anchored_preview({ vip_id: "gone" })

      expect(preview[:summary]).to eq("Update VIP gone")
    end
  end
end
