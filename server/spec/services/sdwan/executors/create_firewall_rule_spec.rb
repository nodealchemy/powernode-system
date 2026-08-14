# frozen_string_literal: true

require "rails_helper"

# IMP-134062908364 (Part A) — the account anchor for a record CreateFirewallRule
# resolves ITSELF. #perform did an unscoped `Sdwan::Network.find`, so a
# dispatched create naming a foreign network_id wrote a firewall rule straight
# into another account's overlay — the worst case, because the caller chooses
# direction/action/ports on someone else's fabric. `attrs` strips account_id, so
# Sdwan::FirewallRule's `before_validation :inherit_account_from_network` stamps
# the FOREIGN network's account and Sdwan::TopologyCompiler compiles the rule
# into the victim's nftables. A create has no source pair for the central
# assertion to catch. The live caller MultiTenantIsolationExecutor:408 passes a
# CompositionContext carrying its account — the anchor the bare .find discarded.
RSpec.describe Sdwan::Executors::CreateFirewallRule do
  let(:account) { create(:account) }

  # Minimal VALID firewall-rule attributes (blank selectors match everything;
  # protocol "any" keeps the port-range validation out of scope). Valid so the
  # UN-fixed code persists the row — otherwise the red test would pass on a
  # validation error rather than on the planted rule.
  let(:rule_attributes) do
    { name: "deny-default", priority: 1000, action: "drop",
      direction: "ingress", protocol: "any" }
  end

  describe "account anchoring" do
    let(:operation) do
      ::Ai::DeferredOperation.create!(
        account: account, action_category: "sdwan.firewall_rule_create",
        executor_class: described_class.name, params: {}
      )
    end

    it "refuses to add a firewall rule to a network belonging to another account" do
      foreign = create(:sdwan_network)

      # Effect first, error identity second: a leading raise_error matcher would
      # abort on the un-fixed code and never report the planted rule.
      raised = begin
        described_class.execute(
          { network_id: foreign.id, attributes: rule_attributes },
          deferred_operation: operation
        )
        nil
      rescue StandardError => e
        e
      end

      expect(foreign.firewall_rules.count).to eq(0),
                                              "a dispatched create wrote a firewall rule into another account's network"
      expect(raised).to be_a(::Ai::DeferredOperation::CrossAccountError)
      expect(raised.message).to include(account.id),
                                "the refusal must name the caller's OWN account"
      expect(raised.message).not_to include(foreign.account_id),
                                    "the refusal must not name the victim's account"
    end

    it "adds the rule when the network belongs to the operation's account" do
      network = create(:sdwan_network, account: account)

      result = described_class.execute(
        { network_id: network.id, attributes: rule_attributes },
        deferred_operation: operation
      )

      expect(result[:success]).to be true
      rule = ::Sdwan::FirewallRule.find(result[:data][:rule_id])
      expect(rule.sdwan_network_id).to eq(network.id)
      expect(rule.account_id).to eq(account.id)
    end
  end

  # IMP-6c482005db87 — the operator surfaces (REST + MCP) now park this
  # executor's params through the gate, so the attribute shapes it must accept
  # are the REPLAYED ones: jsonb round-trips every nested key to a String.
  # The gate lives at those call sites, NOT here — internal composition
  # (MultiTenantIsolationExecutor:408) keeps calling .execute synchronously.
  describe "gated-surface replay + composer path" do
    let(:operation) do
      ::Ai::DeferredOperation.create!(
        account: account, action_category: "sdwan.firewall_rule_create",
        executor_class: described_class.name, params: {}
      )
    end

    it "applies a string-keyed port_range_hash exactly as jsonb replay delivers it" do
      network = create(:sdwan_network, account: account)

      result = described_class.execute(
        { network_id: network.id,
          attributes: rule_attributes.merge(
            protocol: "tcp", "port_range_hash" => { "from" => 5432, "to" => 5433 }
          ) },
        deferred_operation: operation
      )

      expect(result[:success]).to be true
      rule = ::Sdwan::FirewallRule.find(result[:data][:rule_id])
      expect(rule.port_range_hash).to eq({ from: 5432, to: 5433 })
    end

    it "performs immediately for the composer and opens no approval-gate rows" do
      network = create(:sdwan_network)

      result = described_class.execute(
        { network_id: network.id, attributes: rule_attributes },
        deferred_operation: nil
      )

      expect(result[:success]).to be true
      expect(::Sdwan::FirewallRule.find(result[:data][:rule_id])).to be_present
      expect(::Ai::DeferredOperation.count).to eq(0),
                                               "the executor itself opened a deferred-operation row — gating belongs to the surfaces"
      expect(::Ai::ApprovalRequest.count).to eq(0)
    end
  end

  # IMP-3a563becb7d7 — #summarize is the approval/notification body
  # (Ai::DeferredOperationApprovalContent.title and .message both render
  # preview[:summary]). It read "Add firewall rule to SDWAN network <uuid>" —
  # a bare network UUID, naming neither the rule nor a network the operator
  # recognises. The rule does not exist yet, so the card is composed from what
  # the request already names, mirroring CreatePeer (IMP-1eba7d50d24c); the
  # network lookup is scoped by the account carried in the create attributes,
  # because Base.preview supplies deferred_operation: nil and an approval card
  # must not name another account's rows.
  describe ".preview" do
    let(:network) { create(:sdwan_network, account: account, name: "wan-core") }

    it "names the rule and the network an operator recognises, not a bare UUID" do
      preview = described_class.preview(
        { network_id: network.id, attributes: rule_attributes.merge(account_id: account.id) }
      )

      expect(preview[:summary]).to eq("Add firewall rule 'deny-default' to SDWAN network wan-core")
    end

    it "does not name a network belonging to another account" do
      foreign = create(:sdwan_network, name: "someone-elses")

      preview = described_class.preview(
        { network_id: foreign.id, attributes: rule_attributes.merge(account_id: account.id) }
      )

      expect(preview[:summary]).to eq("Add firewall rule 'deny-default' to SDWAN network #{foreign.id}")
      expect(preview[:summary]).not_to include("someone-elses")
    end

    it "degrades stepwise on a malformed request rather than raising" do
      expect(described_class.preview({})[:summary]).to eq("Add firewall rule")
      expect(described_class.preview({ network_id: network.id })[:summary])
        .to eq("Add firewall rule to SDWAN network #{network.id}")
    end
  end
end
