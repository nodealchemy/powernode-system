# frozen_string_literal: true

require "rails_helper"

# IMP-3173b0441be2 — gated-CRUD wiring, route-policy resource (slice 2 of the
# remaining eight executors).
#
# `Sdwan::Executors::CreateRoutePolicy` and `UpdateRoutePolicy` were written and
# never called: RoutePoliciesController wrote through
# `::Sdwan::RoutePolicy.new(...).save` / `@policy.update` behind the permission
# check alone, so the seeded `sdwan.route_policy_create` /
# `sdwan.route_policy_update` intervention policies matched no gate call.
#
# DELETE on this same controller has been gated since slice 9e, so the
# asymmetry was: removing a route policy needed approval, publishing one that
# rewrites a peer's iBGP advertisements did not.
#
# Response-contract note (202 semantics): an operator request carries no agent,
# and the seeded sdwan.route_policy_* policies are ai_agent_id-scoped to the
# SDWAN Manager, so InterventionPolicyService falls through to its
# require_approval default — 202 with the deferred-operation id, and the row
# appears only at approval time. That is why the :proceed examples stub the
# policy service. Field-level validation errors are still 422 and still never
# open a gate row.
RSpec.describe "Api::V1::System::Sdwan::RoutePolicies", type: :request do
  let(:account) { create(:account) }
  let(:manager) { user_with_permissions("system.sdwan.route_policies.manage", account: account) }
  let(:reader)  { user_with_permissions("system.sdwan.route_policies.read", account: account) }

  let(:collection_path) { "/api/v1/system/sdwan/route_policies" }

  # Forces the gate's :proceed branch, where the executor runs inline and the
  # controller's on_proceed lambda renders. No InterventionPolicy rows exist in
  # a spec account, so InterventionPolicyService falls through to its
  # require_approval default and nothing else here covers :proceed.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  describe "POST /api/v1/system/sdwan/route_policies" do
    let(:payload) do
      {
        route_policy: {
          name: "prefer-primary",
          scope: "account",
          direction: "import",
          enabled: true,
          statements: [ { match: { prefix_in: [ "10.0.0.0/24" ] }, action: { type: "accept", set_local_pref: 200 } } ]
        }
      }
    end

    def post_create(user: manager)
      post collection_path, params: payload, headers: auth_headers_for(user), as: :json
    end

    it "requires system.sdwan.route_policies.manage" do
      post_create(user: reader)

      expect(response).to have_http_status(:forbidden)
    end

    # The finding: this wrote the policy inline behind the permission check, so
    # `sdwan.route_policy_create` never resolved against anything.
    it "defers the create through the autonomy gate instead of writing inline" do
      expect { post_create }.not_to change(::Sdwan::RoutePolicy, :count)

      expect(response).to have_http_status(:accepted)

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "POST did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.route_policy_create")
      expect(deferred.executor_class).to eq("Sdwan::Executors::CreateRoutePolicy")
      expect(deferred.params.dig("attributes", "name")).to eq("prefer-primary")
    end

    # gate! never calls on_proceed on its :pending branch, so the row has to be
    # written by the deferred executor itself.
    it "creates the policy when the deferred operation is approved" do
      post_create

      expect { approve_latest_deferred! }.to change(::Sdwan::RoutePolicy, :count).by(1)

      policy = ::Sdwan::RoutePolicy.order(created_at: :desc).first
      expect(policy.name).to eq("prefer-primary")
      # The executor takes the account from the operation, never from the
      # request (account_id is stripped from attrs by Executors::Base).
      expect(policy.account_id).to eq(account.id)
    end

    it "creates inline and renders the row when the policy auto-approves" do
      auto_approve_policy!

      post_create

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "route_policy", "name")).to eq("prefer-primary")
      expect(::Sdwan::RoutePolicy.count).to eq(1), "answered created over a row that does not exist"
      # 201-with-the-row is also what the UNGATED controller answered, so
      # without this the example cannot tell fixed from unfixed.
      expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::CreateRoutePolicy"),
                                                              "auto-approved create bypassed the gate entirely"
    end

    # IMP-7ff14e99e885 — the re-find scope handed to gate_create! must be
    # account-constrained.
    #
    # Reachability, stated honestly: on the real :proceed path the id comes from
    # CreateRoutePolicy#perform, which is a bare `create!` — always a fresh
    # UUIDv7 row under the operation's account — so no caller input steers it
    # and the old unscoped `scope:` was never a reachable cross-tenant read.
    # These examples pin the property rather than an exploit: whatever id the
    # gate hands back, the controller re-finds it inside this account or refuses.
    # Without them the scope silently reverts to "everything".
    context "when the gate's :proceed result names a policy in another account" do
      let(:other_account) { create(:account) }
      let!(:foreign_policy) do
        create(:sdwan_route_policy, account: other_account, name: "foreign-policy",
                                    scope: "account", direction: "import")
      end

      def proceed_returning(policy_id)
        allow(::Ai::AutonomyGate).to receive(:evaluate).and_return(
          ::Ai::AutonomyGate::Result.new(
            decision: :proceed, deferred_operation: nil,
            result: { data: { policy_id: policy_id } }
          )
        )
      end

      it "does not re-find and serialize the foreign row" do
        proceed_returning(foreign_policy.id)

        post_create

        expect(response.body).not_to include("foreign-policy")
        expect(response).to have_http_status(:not_found)
      end

      # Control: the refusal above must not be over-tightening. @account is
      # `current_account`, the same account Executors::Base writes under, so a
      # legitimate result still resolves.
      it "still re-finds and renders a row in the caller's own account" do
        own_policy = create(:sdwan_route_policy, account: account, name: "own-policy",
                                                 scope: "account", direction: "import")
        proceed_returning(own_policy.id)

        post_create

        expect(response).to have_http_status(:created)
        expect(response.parsed_body.dig("data", "route_policy", "name")).to eq("own-policy")
      end
    end

    # Gating must not cost the caller its field-level errors: an invalid payload
    # is rejected before the gate, so no audit row is opened for an operation
    # that could never have run.
    it "still answers 422 with field errors and opens no gate row for an invalid payload" do
      payload[:route_policy][:direction] = "sideways"

      post_create

      expect(response).to have_http_status(422)
      expect(response.parsed_body["errors"] || response.parsed_body.dig("error")).to be_present
      expect(::Ai::DeferredOperation.count).to eq(0),
                                               "an unsaveable create still opened an autonomy-gate audit row"
    end
  end

  describe "PATCH /api/v1/system/sdwan/route_policies/:id" do
    let!(:policy) do
      create(:sdwan_route_policy, account: account, name: "orig", scope: "account", direction: "import")
    end

    let(:payload) { { route_policy: { direction: "export" } } }

    def member_path = "#{collection_path}/#{policy.id}"

    def patch_update(user: manager)
      patch member_path, params: payload, headers: auth_headers_for(user), as: :json
    end

    it "requires system.sdwan.route_policies.manage" do
      patch_update(user: reader)

      expect(response).to have_http_status(:forbidden)
    end

    it "defers the update through the autonomy gate instead of writing inline" do
      patch_update

      expect(response).to have_http_status(:accepted)
      expect(policy.reload.direction).to eq("import"),
                                         "the route policy was changed without an approval gate"

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "PATCH did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.route_policy_update")
      expect(deferred.executor_class).to eq("Sdwan::Executors::UpdateRoutePolicy")
      expect(deferred.params["policy_id"]).to eq(policy.id)
    end

    it "applies the update when the deferred operation is approved" do
      patch_update
      approve_latest_deferred!

      expect(policy.reload.direction).to eq("export"), "approved update left the policy unchanged"
    end

    it "updates inline and renders the row when the policy auto-approves" do
      auto_approve_policy!

      patch_update

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "route_policy", "direction")).to eq("export")
      expect(policy.reload.direction).to eq("export"), "answered ok over an unchanged policy"
      # 200-with-the-row is also what the UNGATED controller answered.
      expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::UpdateRoutePolicy"),
                                                              "auto-approved update bypassed the gate entirely"
    end

    it "still answers 422 with field errors and opens no gate row for an invalid payload" do
      payload[:route_policy][:direction] = "sideways"

      patch_update

      expect(response).to have_http_status(422)
      expect(policy.reload.direction).to eq("import")
      expect(::Ai::DeferredOperation.count).to eq(0),
                                               "an unsaveable update still opened an autonomy-gate audit row"
    end
  end

  # IMP-800b25c1cc45 — DELETE was gated from the start and had NO spec on
  # either branch, while create and update above carried four each. Dropping a
  # policy is the direction that widens what a BGP neighbor accepts, so it is
  # the arm on this controller least able to afford an unexercised gate.
  describe "DELETE /api/v1/system/sdwan/route_policies/:id" do
    let!(:policy) do
      create(:sdwan_route_policy, account: account, name: "drop-me",
                                  scope: "account", direction: "import")
    end

    def member_path = "#{collection_path}/#{policy.id}"

    def delete_policy(user: manager)
      delete member_path, headers: auth_headers_for(user), as: :json
    end

    it "requires system.sdwan.route_policies.manage" do
      delete_policy(user: reader)

      expect(response).to have_http_status(:forbidden)
      expect(::Sdwan::RoutePolicy.exists?(policy.id)).to be(true)
    end

    it "defers the destroy through the autonomy gate instead of deleting inline" do
      delete_policy

      expect(response).to have_http_status(:accepted)
      expect(::Sdwan::RoutePolicy.exists?(policy.id)).to be(true),
                                                        "the route policy was destroyed without an approval gate"

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "DELETE did not route through the autonomy gate"
      expect(deferred.action_category).to eq("sdwan.route_policy_delete")
      expect(deferred.executor_class).to eq("Sdwan::Executors::DeleteRoutePolicy")
      expect(deferred.params["policy_id"]).to eq(policy.id)
    end

    # gate! never calls on_proceed on :pending, so the executor is the only
    # thing that can perform this write — a params-key mismatch between the
    # controller and DeleteRoutePolicy surfaces here and nowhere else.
    it "destroys the policy when the deferred operation is approved" do
      delete_policy
      expect(response).to have_http_status(:accepted)

      approve_latest_deferred!

      expect(::Sdwan::RoutePolicy.exists?(policy.id)).to be(false),
                                                        "approved destroy left the policy in place"
    end

    it "destroys inline and answers deleted when the policy auto-approves" do
      auto_approve_policy!

      delete_policy

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "deleted")).to be(true)
      expect(response.parsed_body.dig("data", "id")).to eq(policy.id)
      expect(::Sdwan::RoutePolicy.exists?(policy.id)).to be(false),
                                                        "answered deleted over a policy that is still there"
      # deleted-with-the-id is also what an UNGATED destroy would answer, so
      # without this the example cannot tell gated from ungated.
      expect(::Ai::DeferredOperation.last&.executor_class).to eq("Sdwan::Executors::DeleteRoutePolicy"),
                                                              "auto-approved destroy bypassed the gate entirely"
    end

    # AutonomyGate opens the DeferredOperation BEFORE it branches on policy, so
    # "no row was opened" proves the gate was never reached — the request was
    # refused on scope rather than parking an operation that could not run.
    it "404s for a policy in another account and opens no gate row" do
      foreign = create(:sdwan_route_policy, account: create(:account))

      expect {
        delete "#{collection_path}/#{foreign.id}", headers: auth_headers_for(manager), as: :json
        expect(response).to have_http_status(:not_found)
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(::Sdwan::RoutePolicy.exists?(foreign.id)).to be(true)
    end
  end
end
