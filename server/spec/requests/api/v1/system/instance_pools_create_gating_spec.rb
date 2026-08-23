# frozen_string_literal: true

require "rails_helper"

# IMP-785d60f5ec3e — POST /instance_pools called the gate with raw params and
# no candidate, so an unsaveable payload was PARKED as an approval instead of
# being refused in front of the caller who could fix it.
#
# The guard here is a PROPERTY, not a response body: an invalid payload must
# open no Ai::DeferredOperation and must answer with the SAME status whatever
# the account's intervention policy says. Ai::AutonomyGate#evaluate creates the
# DeferredOperation row BEFORE it branches on policy, so `not_to change` on
# that count genuinely proves the gate was never reached — it is not an oracle
# that passes because nothing happened. (Before the fix it changed on BOTH
# branches; the red run is in the IMP notes.)
RSpec.describe "Api::V1::System::InstancePools create gating", type: :request do
  # Two accounts on DIFFERENT policies. One policy cannot see the asymmetry
  # that IS the defect: the same bytes answered 202 under the account with no
  # policy rows (InterventionPolicyService's require_approval default -> the
  # gate parks it) and 422 under an account whose policy proceeds (the
  # executor's create! raised, the gate rescued it to :blocked). Same request,
  # different verdict, decided by something the caller cannot see.
  let(:parked_account)     { create(:account) }
  let(:proceeding_account) { create(:account) }

  let(:parked_user) do
    user_with_permissions("system.node_instances.read", "system.instances.create",
                          account: parked_account)
  end
  let(:proceeding_user) do
    user_with_permissions("system.node_instances.read", "system.instances.create",
                          account: proceeding_account)
  end

  let(:parked_template)     { create(:system_node_template, account: parked_account) }
  let(:proceeding_template) { create(:system_node_template, account: proceeding_account) }

  before do
    # Only this account gets a policy row; `parked_account` is left bare so it
    # falls through to the require_approval default.
    ::Ai::InterventionPolicy.create!(
      account: proceeding_account, ai_agent_id: nil, scope: "action_type",
      action_category: "system.instance_pool_create", policy: "notify_and_proceed",
      priority: 5, is_active: true
    )
  end

  # target_size is the SOLE invalid field — the template is real and the sizes
  # are otherwise coherent — so an assertion on the message names the field the
  # caller actually has to fix.
  def invalid_attrs(template)
    { name: "doomed-pool", node_template_id: template.id,
      target_size: -1, min_size: 0, max_size: 5, lifecycle_class: "ephemeral" }
  end

  def valid_attrs(template)
    { name: "warm-pool", node_template_id: template.id,
      target_size: 1, min_size: 0, max_size: 5, lifecycle_class: "ephemeral" }
  end

  def post_create(user, attrs)
    post "/api/v1/system/instance_pools",
         params: { pool: attrs }.to_json,
         headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  describe "an invalid payload" do
    it "opens no deferred operation on the account whose policy would PARK it" do
      expect { post_create(parked_user, invalid_attrs(parked_template)) }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(::System::InstancePool.where(account_id: parked_account.id).count).to eq(0)
    end

    it "opens no deferred operation on the account whose policy would PROCEED" do
      expect { post_create(proceeding_user, invalid_attrs(proceeding_template)) }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(::System::InstancePool.where(account_id: proceeding_account.id).count).to eq(0)
    end

    it "mints no approval request for an operation that could never run" do
      expect { post_create(parked_user, invalid_attrs(parked_template)) }
        .not_to change(::Ai::ApprovalRequest, :count)
    end

    # THE defect, stated as the property a caller can rely on.
    it "answers the SAME status under both policies for the same payload" do
      post_create(parked_user, invalid_attrs(parked_template))
      parked_status = response.status

      post_create(proceeding_user, invalid_attrs(proceeding_template))
      proceeding_status = response.status

      expect(parked_status).to eq(proceeding_status),
                               "the same payload answered #{parked_status} under a parking policy and " \
                               "#{proceeding_status} under a proceeding one — the verdict tracked the " \
                               "account's policy, not the request"
      expect(parked_status).to eq(422)
    end

    # A null size is still an invalid payload, and the property above has to
    # hold for it too. It nearly did not: System::InstancePool's
    # max_gte_target_gte_min compared with `<` and was not nil-guarded, so
    # `candidate.valid?` RAISED ArgumentError inside the action and answered
    # 500 — under both policies, so the asymmetry was gone but so was the 422.
    # Validating before the gate is what put that comparison on the request
    # path at all; the pre-gate ordering is only worth having if the
    # validation itself cannot blow up.
    it "answers 422, not 500, when a size arrives as an explicit null" do
      attrs = invalid_attrs(parked_template).merge(target_size: nil)

      expect { post_create(parked_user, attrs) }
        .not_to change(::Ai::DeferredOperation, :count)
      expect(response).to have_http_status(:unprocessable_content)

      post_create(proceeding_user, invalid_attrs(proceeding_template).merge(target_size: nil))
      expect(response).to have_http_status(:unprocessable_content)
    end

    # Run against BOTH accounts deliberately. The negative half is the one
    # that names the defect, and it only bites on the PROCEEDING account:
    # pre-fix the parked account answered 202 with no error body at all (so
    # this assertion could not fail there), while the proceeding account
    # answered 422 carrying the gate's bare "Gate evaluation failed: ..."
    # from Ai::AutonomyGate's StandardError rescue — no details.errors, and
    # nothing telling the caller which field to correct.
    it "names the field the caller has to fix, rather than the gate" do
      [ [ parked_user, parked_template ], [ proceeding_user, proceeding_template ] ].each do |user, template|
        post_create(user, invalid_attrs(template))

        # render_error puts the message under "error" — NOT "message", which
        # it never sets. Reading only "message" made the negative assertion
        # unfailable, since the gate's refusal lands in "error" too.
        body = (json_response.dig("details", "errors") || []).join(" ") + " " +
               json_response["error"].to_s + " " + json_response["message"].to_s

        expect(body).to match(/target size/i)
        expect(body).not_to include("Gate evaluation failed")
      end
    end
  end

  describe "a valid payload still routes through the gate" do
    it "parks the create on the account with no policy rows" do
      post_create(parked_user, valid_attrs(parked_template))

      expect(response).to have_http_status(:accepted)
      expect(json_response_data["pending"]).to eq(true)
      expect(::System::InstancePool.where(account_id: parked_account.id).count).to eq(0),
                                                                                   "a pool was created without an approval gate"

      deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
      expect(deferred).to be_present, "POST did not route through the autonomy gate"
      expect(deferred.action_category).to eq("system.instance_pool_create")
      expect(deferred.executor_class).to eq("System::Executors::InstancePool::CreatePool")
      expect(deferred.params.dig("attributes", "name")).to eq("warm-pool")
    end

    it "creates the pool at 201 on the account whose policy proceeds" do
      post_create(proceeding_user, valid_attrs(proceeding_template))

      expect(response).to have_http_status(:created)
      expect(json_response_data["pool"]["name"]).to eq("warm-pool")
      expect(::System::InstancePool.find_by(account_id: proceeding_account.id, name: "warm-pool")).to be_present
    end

    it "creates the pool when the parked operation is approved" do
      post_create(parked_user, valid_attrs(parked_template))
      approve_latest_deferred!

      expect(::System::InstancePool.find_by(account_id: parked_account.id, name: "warm-pool")).to be_present
    end
  end
end
