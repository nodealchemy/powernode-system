# frozen_string_literal: true

require "rails_helper"

# IMP-6c482005db87 — gated-CRUD wiring, firewall-rule create.
#
# `Sdwan::Executors::CreateFirewallRule` was written, tenancy-hardened
# (IMP-134062908364), and card-labeled (IMP-3a563becb7d7) — but had no gate!
# call site: FirewallRulesController#create wrote through
# `@network.firewall_rules.new(...).save` behind the permission check alone,
# so the seeded `sdwan.firewall_rule_create` intervention policy matched
# nothing an operator did. DELETE on this same controller has been gated since
# slice 2 — the asymmetry was: removing a rule needed approval, publishing a
# new drop/accept rule into the tenant's nftables did not.
#
# Response contract mirrors port_mappings_spec.rb (IMP-bf996c7abcb4): a bare
# account resolves through InterventionPolicyService's require_approval
# default and answers 202 with the deferred-operation id (the row appears at
# approval time — the executor is the only writer, since gate! never calls
# on_proceed on :pending); a seeded account carries the agent-less operator
# row (IMP-187124ca2984) resolving sdwan.firewall_rule_create to
# notify_and_proceed and gets 201 with the serialized row. Field-level
# validation stays 422 either way and never opens a gate row.
RSpec.describe "Api::V1::System::Sdwan::FirewallRules", type: :request do
  let(:account) { create(:account) }
  let(:manager) { user_with_permissions("system.sdwan.firewall.manage", account: account) }
  let(:reader)  { user_with_permissions("system.sdwan.firewall.read", account: account) }
  let(:network) { create(:sdwan_network, account: account) }

  def collection_path = "/api/v1/system/sdwan/networks/#{network.id}/firewall_rules"

  # Tail of the approval path — Ai::ApprovalRequest ultimately calls
  # execute_now!. The presence assertion keeps a missing gate failing by name
  # instead of as `undefined method for nil`.
  def approve_latest_deferred!
    deferred = Ai::DeferredOperation.order(created_at: :desc).first
    expect(deferred).to be_present, "no deferred operation was parked — the create was applied inline"
    deferred.execute_now!
  end

  # Reproduces the agent-less operator row the SDWAN seed writes
  # (IMP-187124ca2984) so resolution runs for real on the :proceed examples.
  def seed_operator_policy!(action_category)
    ::Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: nil, scope: "action_type",
      action_category: action_category, policy: "notify_and_proceed",
      priority: 5, is_active: true
    )
  end

  describe "POST /api/v1/system/sdwan/networks/:network_id/firewall_rules" do
    let(:payload) do
      {
        firewall_rule: {
          name: "allow-db",
          priority: 100,
          action: "accept",
          direction: "ingress",
          protocol: "tcp",
          port_range: { from: 5432, to: 5433 }
        }
      }
    end

    def post_create(user: manager)
      post collection_path, params: payload, headers: auth_headers_for(user), as: :json
    end

    it "requires system.sdwan.firewall.manage" do
      post_create(user: reader)

      expect(response).to have_http_status(:forbidden)
    end

    # The finding: this wrote the nftables rule inline behind the permission
    # check, so `sdwan.firewall_rule_create` never resolved against anything.
    it "defers the create through the autonomy gate instead of writing inline" do
      expect { post_create }.not_to change(::Sdwan::FirewallRule, :count)

      expect(response).to have_http_status(:accepted)

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "POST did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.firewall_rule_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreateFirewallRule")
      expect(deferred.params["network_id"]).to eq(network.id)
      expect(deferred.params.dig("attributes", "name")).to eq("allow-db")
      # The {from:, to:} JSON param must be re-keyed to port_range_hash for
      # the executor's create! — the raw column is an int4range a Hash cannot
      # mass-assign.
      expect(deferred.params.dig("attributes", "port_range_hash", "from")).to eq(5432)
      # IMP-4a5094b22df0 — INVERTED. This asserted account_id was PRESENT,
      # because the approval card scoped its network label by whatever account
      # the attributes carried, Base.preview having hardcoded
      # deferred_operation: nil. The card now anchors on the operation's own
      # account, so the key buys nothing and no longer rides in the params the
      # gate stores and replays. Sdwan::FirewallRule derives account_id from
      # its network in a before_validation.
      expect(deferred.params.dig("attributes", "account_id")).to be_nil
    end

    # gate! never calls on_proceed on its :pending branch, so the row has to
    # be written by the deferred executor itself.
    it "creates the rule with its port range when the deferred operation is approved" do
      post_create

      expect { approve_latest_deferred! }.to change(::Sdwan::FirewallRule, :count).by(1)

      rule = ::Sdwan::FirewallRule.order(created_at: :desc).first
      expect(rule.sdwan_network_id).to eq(network.id)
      expect(rule.name).to eq("allow-db")
      expect(rule.port_range_hash).to eq({ from: 5432, to: 5433 })
      # The executor takes the account from the resolved network, never from
      # the request (Base::TENANCY_ATTRIBUTE_KEYS).
      expect(rule.account_id).to eq(account.id)
    end

    it "creates inline and renders the row under the seeded operator policy" do
      seed_operator_policy!("sdwan.firewall_rule_create")

      post_create

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "firewall_rule", "name")).to eq("allow-db")
      expect(::Sdwan::FirewallRule.count).to eq(1), "answered created over a row that does not exist"
      # 201-with-the-row is also what the UNGATED controller answered, so
      # without this the example cannot tell fixed from unfixed.
      expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::CreateFirewallRule"),
                                                              "notify_and_proceed create bypassed the gate entirely"
    end

    # Gating must not cost the caller its field-level errors: an invalid
    # payload is rejected before the gate, so no audit row is opened for an
    # operation that could never have run.
    it "still answers 422 with field errors and opens no gate row for an invalid payload" do
      payload[:firewall_rule][:action] = "explode"

      post_create

      expect(response).to have_http_status(422)
      expect(::Sdwan::FirewallRule.count).to eq(0)
      expect(::Ai::DeferredOperation.count).to eq(0),
                                               "an unsaveable create still opened an autonomy-gate audit row"
    end
  end
end
