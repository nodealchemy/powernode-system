# frozen_string_literal: true

require "rails_helper"

# IMP-03134d9452d2 — the Autonomy modal's write door, same rule as core's
# InterventionPoliciesController (secreview §21 G4, option 1).
#
# PATCH /api/v1/system/autonomy upserts intervention-policy rows, and those rows
# decide which parked requests only a person may decide in their own session
# (Ai::Approvals::HumanSessionPolicy#account_mark). A write that could lift that
# mark (touching a row that carries requires_human_session, or writing it false)
# needs a person's own session; an impersonation or account-switch session is
# refused for that entry and nothing is written for it.
RSpec.describe "Api::V1::System::Autonomy writes of the person-session mark", type: :request do
  let(:account) { create(:account) }
  let!(:operator) do
    user_with_permissions("system.infra_tasks.read", "system.infra_tasks.control", account: account)
  end
  let(:mark) { Ai::Approvals::HumanSessionPolicy::CONDITION_KEY }
  # Under a DOMAIN_PREFIXES prefix: register_category! is process-global, and
  # autonomy_domain_pivot_spec fails on any registered category no prefix claims.
  let(:category) { "system.task.spec_person_session_mark" }

  before { Ai::InterventionPolicy.register_category!(category) }

  def own_headers
    auth_headers_for(operator).merge("Content-Type" => "application/json")
  end

  def impersonation_headers
    admin = create(:user, :admin, account: account)
    session = ImpersonationSession.create_session!(impersonator: admin, impersonated_user: operator)
    payload = { type: "impersonation", session_id: session.id, sub: operator.id, account_id: operator.account_id,
                version: Security::JwtService::CURRENT_TOKEN_VERSION }
    { "Authorization" => "Bearer #{Security::JwtService.encode(payload)}", "Content-Type" => "application/json" }
  end

  def marked_row!
    Ai::InterventionPolicy.create!(account: account, scope: "global", action_category: category, ai_agent_id: nil,
                                   policy: "require_approval", priority: 5, conditions: { mark => true })
  end

  def patch_updates(entries, headers)
    patch "/api/v1/system/autonomy", params: { updates: entries }.to_json, headers: headers
  end

  describe "from an impersonation session" do
    it "refuses an entry that writes the mark false, and writes no row for it" do
      patch_updates([ { action_category: category, scope: "global", policy: "require_approval",
                        conditions: { mark => false } } ], impersonation_headers)

      expect(response).not_to have_http_status(:ok)
      expect(response.body).to include("own session")
      expect(Ai::InterventionPolicy.where(account: account, action_category: category)).to be_empty
    end

    it "refuses changing a marked row's verb, leaving the row as it was" do
      row = marked_row!

      patch_updates([ { action_category: category, scope: "global", policy: "auto_approve", is_active: false } ],
                    impersonation_headers)

      expect(response).not_to have_http_status(:ok)
      row.reload
      expect(row.policy).to eq("require_approval")
      expect(row.is_active).to be(true)
      expect(row.conditions).to eq(mark => true)
    end

    it "still writes an entry whose row carries no mark" do
      patch_updates([ { action_category: category, scope: "global", policy: "notify_and_proceed" } ],
                    impersonation_headers)

      expect(response).to have_http_status(:ok)
      expect(Ai::InterventionPolicy.find_by(account: account, action_category: category).policy)
        .to eq("notify_and_proceed")
    end
  end

  it "lets the person's own session change a marked row and write the mark false" do
    row = marked_row!

    patch_updates([ { action_category: category, scope: "global", policy: "require_approval",
                      conditions: { mark => false } } ], own_headers)

    expect(response).to have_http_status(:ok)
    expect(row.reload.conditions).to eq(mark => false)
  end
end
