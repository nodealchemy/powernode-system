# frozen_string_literal: true

require "rails_helper"

# IMP-bf996c7abcb4 — the "in-account re-parenting on updates" ruling, for the
# port-mapping resource.
#
# `attrs` drops account/account_id (System::Executors::Base::TENANCY_ATTRIBUTE_KEYS),
# which stops the tenancy MOVE. It does not stop the tenancy RE-PARENT:
# sdwan_network_id is equally tenancy-bearing, and Sdwan::PortMapping's own
# validations are RELATIVE — hub_belongs_to_network and target_within_network
# compare the hub/target against the mapping's network, never against the
# operation's account. So a payload naming a foreign network AND that same
# foreign network's peers satisfies every model validation, leaves account_id
# as the caller's, and lands the row in Sdwan::TopologyCompiler's output for
# the victim's overlay.
#
# The controller's strong params do not permit sdwan_network_id, so this is not
# reachable over HTTP — it is the agent/MCP dispatch path, which hands the
# executor an attributes hash the gate stores verbatim and replays with no
# re-validation. Per the pinned rule: the executor owns resolving its own
# inputs; it does not get to assume the caller was trustworthy.
RSpec.describe Sdwan::Executors::UpdatePortMapping do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:hub)     { create(:sdwan_peer, account: account, network: network) }
  let(:target)  { create(:sdwan_peer, account: account, network: network) }

  let!(:mapping) do
    create(:sdwan_port_mapping, account: account, network: network,
                                hub_peer: hub, target_peer: target, listen_port: 30_100)
  end

  def deferred_for(params)
    ::Ai::DeferredOperation.create!(
      account: account,
      action_category: "sdwan.port_mapping_update",
      executor_class: "Sdwan::Executors::UpdatePortMapping",
      params: params,
      source_type: "Sdwan::PortMapping",
      source_id: mapping.id
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
    error = run({ mapping_id: mapping.id, attributes: { listen_port: 30_200 } })

    expect(error).to be_nil
    expect(mapping.reload.listen_port).to eq(30_200)
  end

  it "refuses to re-parent the mapping into another account's network" do
    foreign_network = create(:sdwan_network)
    foreign_account = foreign_network.account
    foreign_hub     = create(:sdwan_peer, account: foreign_account, network: foreign_network)
    foreign_target  = create(:sdwan_peer, account: foreign_account, network: foreign_network)

    error = run({
      mapping_id: mapping.id,
      attributes: {
        sdwan_network_id: foreign_network.id,
        sdwan_peer_id: foreign_hub.id,
        target_peer_id: foreign_target.id
      }
    })

    expect(mapping.reload.sdwan_network_id).to eq(network.id),
                                               "the mapping was re-parented into another account's overlay"
    expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
    # The refusal must not echo the victim's identifiers back to the caller.
    expect(error.message).not_to include(foreign_account.id)
  end

  it "allows an in-account re-parent to a sibling network" do
    sibling     = create(:sdwan_network, account: account)
    sibling_hub = create(:sdwan_peer, account: account, network: sibling)
    sibling_tgt = create(:sdwan_peer, account: account, network: sibling)

    error = run({
      mapping_id: mapping.id,
      attributes: {
        sdwan_network_id: sibling.id,
        sdwan_peer_id: sibling_hub.id,
        target_peer_id: sibling_tgt.id
      }
    })

    expect(error).to be_nil
    expect(mapping.reload.sdwan_network_id).to eq(sibling.id)
  end

  # IMP-3a563becb7d7 — #summarize is the approval/notification body
  # (Ai::DeferredOperationApprovalContent.title and .message both render
  # preview[:summary]). It read "Update port mapping <uuid>" — a bare UUID —
  # while PortMappingsController#update's gate description for the SAME
  # operation reads "Update SDWAN port mapping ssh-ingress on wan-core". The
  # card renders the controller's sentence verbatim so the two surfaces
  # cannot disagree; the bare id is only the floor for a row already gone.
  #
  # IMP-4a5094b22df0 threads the operation through `preview` and resolves the
  # label through it, so these pass one. With no operation there is no account
  # to anchor on and the card correctly declines to name the mapping — asserted
  # separately in preview_account_anchor_spec.rb.
  describe ".preview" do
    it "names the mapping and network an operator recognises, not a bare UUID" do
      mapping.update!(name: "ssh-ingress")
      network.update!(name: "wan-core")
      params = { mapping_id: mapping.id }

      preview = described_class.preview(params, deferred_operation: deferred_for(params))

      expect(preview[:summary]).to eq("Update SDWAN port mapping ssh-ingress on wan-core")
    end

    it "falls back to the bare id when the mapping is gone" do
      params = { mapping_id: "gone" }

      preview = described_class.preview(params, deferred_operation: deferred_for(params))

      expect(preview[:summary]).to eq("Update SDWAN port mapping gone")
    end
  end
end
