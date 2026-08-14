# frozen_string_literal: true

require "rails_helper"

# IMP-c159cc6777b1 — gated-CRUD wiring, peer resource. Per-executor re-parent
# analysis (the operator's contract for this slice): a re-pointable FK is a
# tenancy hole only if a consumer dereferences it WITHOUT an account filter.
#
# Verdict for UpdatePeer: it DOES need a re-parent anchor (unlike UpdateNetwork,
# whose row is the root of the tenancy tree). Sdwan::Peer belongs_to :network via
# sdwan_network_id; the column is mutable and survives `attrs` (only
# account/account_id are stripped, TENANCY_ATTRIBUTE_KEYS), and
# Sdwan::TopologyCompiler reads the peers back through
# `network.peers.includes(:keys)` with NO account filter (topology_compiler.rb).
# So an operation naming a foreign sdwan_network_id re-parents the peer into the
# victim's network while account_id stays the caller's, and the victim's overlay
# then compiles a peer it does not own. resolve_scoped on the new parent is the
# whole guard.
RSpec.describe Sdwan::Executors::UpdatePeer do
  let(:account) { create(:account) }
  let!(:network) { create(:sdwan_network, account: account) }
  let!(:peer) { create(:sdwan_peer, account: account, network: network, tags: []) }

  def deferred_for(params)
    ::Ai::DeferredOperation.create!(
      account: account,
      action_category: "sdwan.peer_update",
      executor_class: "Sdwan::Executors::UpdatePeer",
      params: params,
      source_type: "Sdwan::Peer",
      source_id: peer.id
    )
  end

  # Captures rather than leading with raise_error, so a failing example reports
  # the effect it exists to prevent, not just "nothing was raised".
  def run(params)
    described_class.execute(params, deferred_operation: deferred_for(params))
    nil
  rescue StandardError => e
    e
  end

  it "applies an in-account update" do
    error = run({ peer_id: peer.id, attributes: { tags: ["edge"] } })

    expect(error).to be_nil
    expect(peer.reload.tags).to eq(["edge"])
  end

  # The anchor must not block a legitimate re-parent WITHIN the account.
  it "allows re-parenting to another network in the same account" do
    sibling = create(:sdwan_network, account: account)

    error = run({ peer_id: peer.id, attributes: { sdwan_network_id: sibling.id } })

    expect(error).to be_nil
    expect(peer.reload.sdwan_network_id).to eq(sibling.id),
                                            "the anchor over-blocked a legitimate in-account re-parent"
  end

  # The behavioral vulnerability: pre-fix the peer lands in the victim's network
  # (which TopologyCompiler then compiles into the victim's overlay); post-fix the
  # anchor refuses and the peer keeps its own network.
  it "refuses to re-parent the peer into another account's network (anchor_reparent! is the guard)" do
    victim = create(:sdwan_network, name: "victim") # belongs to its own fresh account

    error = run({ peer_id: peer.id, attributes: { sdwan_network_id: victim.id } })

    expect(peer.reload.sdwan_network_id).to eq(network.id),
                                            "the peer was re-parented into a network outside the operation's account"
    expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
    # The refusal names the caller's OWN account, never the victim's id.
    expect(error.message).not_to include(victim.account_id)
  end

  # attrs strips account/account_id (TENANCY_ATTRIBUTE_KEYS), so a mass-assigned
  # account_id cannot move the row even without the network anchor.
  it "cannot move the peer to another account via a mass-assigned account_id" do
    other = create(:account)

    error = run({ peer_id: peer.id, attributes: { tags: ["edge"], account_id: other.id } })

    expect(error).to be_nil
    expect(peer.reload.account_id).to eq(account.id),
                                      "attrs failed to strip account_id — the peer was moved"
    expect(peer.tags).to eq(["edge"])
  end

  # IMP-3a563becb7d7 — #summarize is the approval/notification body
  # (Ai::DeferredOperationApprovalContent.title and .message both render
  # preview[:summary]). It read "Update SDWAN peer <uuid>" — a bare UUID —
  # while the delete card for the same peer reads
  # "Delete SDWAN peer edge-lon-01 on wan-core". The label is
  # Sdwan::Peer#operator_label, the same ladder both delete surfaces render
  # (IMP-ee57d0fbe859).
  describe ".preview" do
    it "names the peer an operator recognises, not a bare UUID" do
      peer.node_instance.update!(name: "edge-lon-01")
      network.update!(name: "wan-core")

      preview = described_class.preview({ peer_id: peer.id })

      expect(preview[:summary]).to eq("Update SDWAN peer edge-lon-01 on wan-core")
    end

    # A shared ladder only constrains the fragment both surfaces share, so the
    # oracle asserts the equality itself: one peer, two cards, one identity.
    it "renders the same identity fragment the delete card renders for the same peer" do
      peer.node_instance.update!(name: "edge-lon-01")

      update_summary = described_class.preview({ peer_id: peer.id })[:summary]
      delete_summary = ::Sdwan::Executors::DeletePeer.preview({ peer_id: peer.id })[:summary]

      expect(update_summary.delete_prefix("Update SDWAN peer "))
        .to eq(delete_summary.delete_prefix("Delete SDWAN peer ")),
            "update/delete cards must name the same peer identically"
    end

    it "falls back to the bare id when the peer is gone" do
      preview = described_class.preview({ peer_id: "gone" })

      expect(preview[:summary]).to eq("Update SDWAN peer gone")
    end
  end
end
