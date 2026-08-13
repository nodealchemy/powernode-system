# frozen_string_literal: true

require "rails_helper"

# IMP-c159cc6777b1 — gated-CRUD wiring, network resource. The operator's
# contract for this slice is a PER-EXECUTOR re-parent analysis: a re-pointable
# FK is a tenancy hole only if a consumer dereferences it WITHOUT an account
# filter.
#
# Verdict for UpdateNetwork: NO re-parent anchor is needed (unlike
# UpdatePortMapping / UpdateVirtualIp, whose sdwan_network_id is re-pointable and
# is read back by TopologyCompiler through `network.<children>` with no account
# filter). Sdwan::Network is the TOP of the SDWAN tenancy tree — it
# belongs_to :account and nothing else; every SDWAN child (peer, virtual_ip,
# firewall_rule, port_mapping, subnet_advertisement) points AT it via
# sdwan_network_id, so the network row itself carries no re-pointable
# tenancy-bearing FK. account_id is its only tenancy key, which
# System::Executors::Base#attrs strips (TENANCY_ATTRIBUTE_KEYS) and resolve_scoped
# re-anchors. So resolve_scoped on the target network is the whole guard. This
# spec pins that verdict so a future reader knows the missing anchor was verified,
# not overlooked.
RSpec.describe Sdwan::Executors::UpdateNetwork do
  let(:account) { create(:account) }
  let!(:network) { create(:sdwan_network, account: account, name: "orig", status: "registered") }

  def deferred_for(params)
    ::Ai::DeferredOperation.create!(
      account: account,
      action_category: "sdwan.network_update",
      executor_class: "Sdwan::Executors::UpdateNetwork",
      params: params,
      source_type: "Sdwan::Network",
      source_id: network.id
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
    error = run({ network_id: network.id, attributes: { status: "suspended" } })

    expect(error).to be_nil
    expect(network.reload.status).to eq("suspended")
  end

  it "refuses to update a network in another account (resolve_scoped is the guard)" do
    foreign = create(:sdwan_network, name: "victim", status: "registered")

    error = run({ network_id: foreign.id, attributes: { status: "suspended" } })

    expect(foreign.reload.status).to eq("registered"),
                                     "the executor mutated a network outside the operation's account"
    expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
    # The refusal must not echo the victim's account id back to the caller.
    expect(error.message).not_to include(foreign.account_id)
  end

  # Why no re-parent anchor is required: the only tenancy key on a network is
  # account_id, and attrs strips it — so a mass-assigned account_id cannot move
  # the row, and there is no other re-pointable FK to anchor.
  it "cannot move the network to another account via a mass-assigned account_id" do
    other = create(:account)

    error = run({ network_id: network.id, attributes: { status: "suspended", account_id: other.id } })

    expect(error).to be_nil
    expect(network.reload.account_id).to eq(account.id),
                                         "attrs failed to strip account_id — the network was moved"
    expect(network.status).to eq("suspended")
  end
end
