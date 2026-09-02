# frozen_string_literal: true

require "rails_helper"

# IMP-24daa05e7a22 — the instance-pool SPEND CEILING was raisable with no
# approval.
#
# PATCH /instance_pools/:id ran a bare `@pool.update!(update_params)`, and
# `update_params` permit :target_size, :max_size AND :status. So anyone holding
# system.instances.control could raise the ceiling the (deliberately ungated,
# IMP-714ab7da6b9c) 60 s replenish tick spends up to, and could reach
# status "archived" — the state the GATED destroy's on_proceed writes — through
# an ungated verb.
#
# The property pinned here is about the ROW, not the status code: a ceiling
# raise must not reach the record until the gate says so. Asserting the parked
# 202 alone would pass against a controller that renders 202 and writes anyway
# (`render_error ... and return` did exactly that shape of thing at this very
# call site — IMP-ce5d320d3e4e), so every gated example reads the row back.
#
# The negative half matters as much: DECREASES and every non-ceiling field stay
# ungated by operator direction, and an example that only proved "PATCH is
# gated" would pass for a controller that parked the description edits too.
RSpec.describe "Api::V1::System::InstancePools update gating", type: :request do
  # No policy rows for this account: Ai::InterventionPolicyService's default is
  # require_approval, so the gate PARKS. That is the branch that proves the
  # write did not land.
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }

  # The finding's actor: system.instances.control, not .create.
  let(:user) do
    user_with_permissions("system.node_instances.read", "system.instances.control",
                          account: account)
  end

  let!(:pool) do
    ::System::InstancePool.create!(
      account: account, name: "ceiling-pool", node_template: template,
      target_size: 2, min_size: 0, max_size: 5,
      lifecycle_class: "ephemeral", status: "active", description: "before"
    )
  end

  def patch_pool(attrs)
    patch "/api/v1/system/instance_pools/#{pool.id}",
          params: { pool: attrs }.to_json,
          headers: auth_headers_for(user).merge("Content-Type" => "application/json")
  end

  def latest_deferred
    ::Ai::DeferredOperation.order(created_at: :desc).first
  end

  describe "raising the ceiling" do
    it "parks a target_size increase instead of writing it" do
      expect { patch_pool(target_size: 4) }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(response).to have_http_status(:accepted)
      expect(pool.reload.target_size).to eq(2),
                                         "the ceiling was raised without an approval"

      expect(latest_deferred.action_category).to eq("system.instance_pool_ceiling_raise")
      expect(latest_deferred.executor_class).to eq("System::Executors::InstancePool::UpdatePool")
      expect(latest_deferred.params["pool_id"]).to eq(pool.id)
    end

    it "parks a max_size increase instead of writing it" do
      patch_pool(max_size: 40)

      expect(response).to have_http_status(:accepted)
      expect(pool.reload.max_size).to eq(5)
      expect(latest_deferred.action_category).to eq("system.instance_pool_ceiling_raise")
    end

    # The whole PATCH is one write, so a raise carries its travelling
    # companions into the gate rather than half-applying them.
    it "withholds the rest of the payload that arrived with the raise" do
      patch_pool(target_size: 4, description: "smuggled")

      expect(pool.reload.description).to eq("before")
    end

    it "applies the raise once the parked operation is approved" do
      patch_pool(target_size: 4)
      approve_latest_deferred!

      expect(pool.reload.target_size).to eq(4)
    end
  end

  describe "archiving through the ungated verb" do
    it "parks status:archived instead of writing it" do
      expect { patch_pool(status: "archived") }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(response).to have_http_status(:accepted)
      expect(pool.reload.status).to eq("active"),
                                    "PATCH reproduced the GATED destroy's archive with no approval"
      expect(latest_deferred.action_category).to eq("system.instance_pool_archive")
    end

    it "archives once the parked operation is approved" do
      patch_pool(status: "archived")
      approve_latest_deferred!

      expect(pool.reload.status).to eq("archived")
    end
  end

  # Operator direction: decreases stay ungated. Without these the fix could
  # gate the whole verb and still look correct.
  describe "what stays ungated" do
    it "applies a target_size DECREASE inline" do
      expect { patch_pool(target_size: 1) }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:ok)
      expect(pool.reload.target_size).to eq(1)
    end

    it "applies a max_size DECREASE inline" do
      expect { patch_pool(max_size: 3) }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:ok)
      expect(pool.reload.max_size).to eq(3)
    end

    it "applies a non-ceiling field inline" do
      expect { patch_pool(description: "retuned") }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:ok)
      expect(pool.reload.description).to eq("retuned")
    end

    # `paused` is the one status replenish! refuses, so pausing REMOVES spend.
    # Draining is left ungated too — #drain itself is ungated, and the operator
    # direction gates the archive transition only.
    it "applies status:paused inline" do
      expect { patch_pool(status: "paused") }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:ok)
      expect(pool.reload.status).to eq("paused")
    end

    # Re-sending the standing value is not a raise.
    it "treats an unchanged target_size as no raise" do
      expect { patch_pool(target_size: 2) }.not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "an invalid payload" do
    # gate_update!'s ordering invariant, read from this call site: a payload
    # that could never be written opens no audit row for an approver to
    # discover it cannot run.
    it "opens no deferred operation for an unsaveable ceiling raise" do
      expect { patch_pool(target_size: 99) } # > max_size 5
        .not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(pool.reload.target_size).to eq(2)
    end

    it "still 422s an unsaveable ungated payload" do
      patch_pool(target_size: -1)

      expect(response).to have_http_status(:unprocessable_content)
      expect(pool.reload.target_size).to eq(2)
    end
  end

  # A PATCH that both raises the ceiling and archives cannot be gated under one
  # category without letting the operator's relaxation of that category carry
  # the other through. It is refused instead of silently gated under one.
  describe "a PATCH that trips both gates" do
    it "is refused rather than gated under a single category" do
      expect { patch_pool(target_size: 4, status: "archived") }
        .not_to change(::Ai::DeferredOperation, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(pool.reload.target_size).to eq(2)
      expect(pool.reload.status).to eq("active")
    end
  end

  # A ceiling raise is approved LATER, and the decrease that could undo it is
  # applied inline with no approval at all — so the two can interleave with no
  # second decision. Without a replay baseline the approval writes the old high
  # number back over a reduction nobody re-approved, and the approval card,
  # composed at request time, still reads "target_size 2 -> 4".
  describe "replay baseline across the approval window" do
    it "stamps the request-time ceiling into the parked operation" do
      patch_pool(target_size: 4)

      expect(latest_deferred.params.dig("replay_baseline", "target_size")).to eq(2),
                                                                             "parked a ceiling raise with no request-time baseline — the replay guard cannot fire"
    end

    it "fingerprints only the columns the request actually names" do
      patch_pool(target_size: 4)

      expect(latest_deferred.params["replay_baseline"].keys).to contain_exactly("target_size")
    end

    it "refuses the approved replay when the ceiling moved in between" do
      patch_pool(target_size: 4)
      patch_pool(target_size: 1) # a DECREASE — ungated, applied inline

      error = begin
        approve_latest_deferred!
        nil
      rescue StandardError => e
        e
      end

      expect(pool.reload.target_size).to eq(1),
                                         "the approved replay wrote the old ceiling back over an inline decrease"
      expect(error).to be_a(::System::Executors::Base::ReplayBaselineError)
    end

    # Control: the guard must not refuse an undisturbed replay.
    it "applies the approved raise when nothing moved in between" do
      patch_pool(target_size: 4)
      approve_latest_deferred!

      expect(pool.reload.target_size).to eq(4)
    end
  end

  # The gate an operator can actually retune has to exist as a policy row, or
  # it is a control the autonomy panel refuses to save (engine.rb derives the
  # registry from these declarations).
  describe "the declared policies" do
    it "declares both new categories require_approval" do
      declared = ::System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES

      expect(declared["system.instance_pool_ceiling_raise"]).to eq("require_approval")
      expect(declared["system.instance_pool_archive"]).to eq("require_approval")
    end
  end
end
