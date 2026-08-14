# frozen_string_literal: true

require "rails_helper"

# IMP-0e44cf2fc80b — executor-side-effect migration, firewall-rule update.
#
# FirewallRulesController#update ran the port_range → port_range_hash
# transform INLINE (normalize_port_range: the API's {from:, to:} JSON shape
# re-keyed to the model's mass-assignable accessor — the raw column is an
# int4range a Hash cannot set). gate! never calls on_proceed on the :pending
# branch — the executor is the sole writer there — so gating this verb with
# a bare update!(attrs) executor would make every operator-APPROVED update
# carrying a port_range blow up (UnknownAttributeError) or, wired "cleverly",
# silently skip the transform. The transform therefore lives HERE, so it
# fires on both the immediate (:proceed) and the approved (execute_now!)
# path.
#
# The load-bearing example is the APPROVED path: a naive wiring passes the
# :proceed test and fails only that one.
RSpec.describe Sdwan::Executors::UpdateFirewallRule do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }

  let!(:rule) do
    create(:sdwan_firewall_rule, account: account, network: network, protocol: "tcp")
  end

  def deferred_for(params)
    ::Ai::DeferredOperation.create!(
      account: account,
      action_category: "sdwan.firewall_rule_update",
      executor_class: "Sdwan::Executors::UpdateFirewallRule",
      params: params,
      source_type: "Sdwan::FirewallRule",
      source_id: rule.id
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
    error = run({ rule_id: rule.id, attributes: { priority: 42 } })

    expect(error).to be_nil
    expect(rule.reload.priority).to eq(42)
  end

  # The finding: the controller's inline normalize_port_range only ever ran
  # on the :proceed branch. Driving the deferred operation the way the
  # approval tail does (Ai::ApprovalRequest ultimately calls execute_now!)
  # proves the transform survives the approval window.
  it "applies the port_range transform when an APPROVED update executes" do
    deferred = deferred_for({ rule_id: rule.id,
                              attributes: { port_range: { from: 8000, to: 8080 } } })

    deferred.execute_now!

    expect(rule.reload.port_range_hash).to eq({ from: 8000, to: 8080 }),
                                            "approved update dropped the port_range → port_range_hash transform"
  end

  # The {}/nil clearing nuance (IMP-32978416b9d3): the model's
  # port_range_hash= treats {} as "clear the range", while the controller's
  # normalize_port_range treats a nil port_range as "leave the column
  # untouched". Both semantics must survive the migration.
  it "clears an existing range when port_range is an empty hash" do
    rule.update!(port_range_hash: { from: 1000, to: 2000 })

    error = run({ rule_id: rule.id, attributes: { port_range: {} } })

    expect(error).to be_nil
    expect(rule.reload.port_range_hash).to be_nil, "port_range: {} must clear the range"
  end

  it "leaves an existing range untouched when port_range is nil or absent" do
    rule.update!(port_range_hash: { from: 1000, to: 2000 })

    error = run({ rule_id: rule.id, attributes: { port_range: nil, priority: 7 } })

    expect(error).to be_nil
    expect(rule.reload.priority).to eq(7)
    expect(rule.port_range_hash).to eq({ from: 1000, to: 2000 }),
                                    "a nil/absent port_range must not clear the stored range"
  end

  # IMP-bf996c7abcb4 ruling, firewall-rule resource: `attrs` drops
  # account/account_id (the tenancy MOVE) but sdwan_network_id is equally
  # tenancy-bearing, and Sdwan::FirewallRule's own validations are RELATIVE —
  # name uniqueness is scoped to the rule's network and
  # inherit_account_from_network only fires when account_id is blank, so a
  # re-parented row keeps the caller's account while
  # Sdwan::FirewallCompiler.new(victim_network) compiles it into the victim
  # network's nft chain.
  it "refuses to re-parent the rule into another account's network" do
    foreign_network = create(:sdwan_network)

    error = run({
                  rule_id: rule.id,
                  attributes: { sdwan_network_id: foreign_network.id }
                })

    expect(rule.reload.sdwan_network_id).to eq(network.id),
                                            "the rule was re-parented into another account's nft chain"
    expect(error).to be_a(::Ai::DeferredOperation::CrossAccountError)
    # The refusal must not echo the victim's identifiers back to the caller.
    expect(error.message).not_to include(foreign_network.account_id)
  end

  it "allows an in-account re-parent to a sibling network" do
    sibling = create(:sdwan_network, account: account)

    error = run({
                  rule_id: rule.id,
                  attributes: { sdwan_network_id: sibling.id }
                })

    expect(error).to be_nil
    expect(rule.reload.sdwan_network_id).to eq(sibling.id)
  end

  # #summarize is the approval/notification body
  # (Ai::DeferredOperationApprovalContent renders preview[:summary]). The
  # sentence matches FirewallRulesController#update's gate description
  # verbatim so the two surfaces naming this one operation cannot disagree
  # (IMP-3a563becb7d7 / IMP-ee57d0fbe859, UpdatePortMapping precedent); the
  # bare id is only the floor for a row already gone.
  describe ".preview" do
    it "names the rule and network an operator recognises, not a bare UUID" do
      rule.update!(name: "web-allow")
      network.update!(name: "wan-core")

      preview = described_class.preview({ rule_id: rule.id })

      expect(preview[:summary]).to eq("Update firewall rule 'web-allow' on SDWAN network wan-core")
    end

    it "falls back to the bare id when the rule is gone" do
      preview = described_class.preview({ rule_id: "gone" })

      expect(preview[:summary]).to eq("Update firewall rule gone")
    end
  end
end
