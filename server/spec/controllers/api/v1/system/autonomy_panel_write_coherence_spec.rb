# frozen_string_literal: true

require "rails_helper"

# IMP-bef43160636f — the Autonomy modal's WRITE half.
#
# The finding was that SystemSettingsPanel.tsx listed the 7 autonomous
# `system.sdwan_*` categories under a hand-maintained `agentName: 'SDWAN
# Manager'` while the seeds bind them to Fleet Autonomy, so an operator toggle
# upserted a row the sensor path never resolves. IMP-0874acd5b50c already
# deleted that literal — the panel now groups by the server's own
# `agent_bucket` — which fixes the READ. This file guards the other end: that
# the row an operator edits is the row that then decides.
#
# Two things make a write decorative, and only the first is about grouping:
#
#   1. writing an identity OTHER than the row's — a second row appears and the
#      seeded one keeps winning;
#   2. writing NO identity — the body names the category alone, the server
#      defaults it to scope "global" with a nil ai_agent_id, and
#      `Ai::InterventionPolicy#specificity_key` ranks `ai_agent_id.present?`
#      lexicographically ABOVE `priority`. So an agent-scoped seed row outranks
#      it at every priority the operator can set. Not a tie they can win — a
#      tier they cannot reach.
#
# The examples therefore derive the request body FROM the GET payload, exactly
# as the panel does, rather than hand-writing an identity.
#
# What that catches, precisely: a serializer that stopped shipping `agent_id`
# reds on every agent-scoped row, because the upsert then keys on a nil agent
# and inserts. Dropping `scope` is caught far more narrowly — `#update`
# reconstructs it as `agent_id.present? ? "agent" : "global"`, which happens to
# be right for every agent-scoped row, so only a scope-"action_type" row flips
# and reds. One fixture row carries that scope for exactly this reason; do not
# remove it thinking it duplicates the agent rows.
#
# CONTRACT NOTE / boundary. The request body is a cross-language contract with
# `useAutonomyConfig.save()`; nothing in this suite can execute the TypeScript
# side, and nothing in the jest suite can execute this one. The emitted half is
# pinned literally in frontend/src/shared/hooks/useAutonomyConfig.test.ts. A
# rename applied to BOTH literals in one change is invisible to both suites —
# by design, since agreeing is the property. What neither can miss is a rename
# on one side only, which is the way it actually broke.
RSpec.describe "Api::V1::System::Autonomy panel write coherence", type: :request do
  let(:account) { create(:account) }
  let(:operator) { user_with_permissions("system.infra_tasks.read", "system.infra_tasks.control", account: account) }

  let!(:fleet_agent) { create(:ai_agent, account: account, name: "Fleet Autonomy") }
  let!(:sdwan_agent) { create(:ai_agent, account: account, name: "SDWAN Manager") }

  # Pinned literally, not derived from db/seeds/fleet_autonomy_agent.rb. WHICH
  # agent these seven bind is the entire finding, so an oracle that read it back
  # out of the seed file would move with the thing under test and certify any
  # relocation as correct.
  #
  # A `let` rather than a constant: a constant declared inside a describe block
  # lands on Object, and this suite has been bitten by two files clobbering one
  # name in a defined-order run.
  #
  # IMP-17bc5546009a (2026-08-21): was 7 — system.sdwan_route_policy_audit is
  # gone. It had no sensor, no DecisionEngine binding, and no executor, so it
  # was a permanently no-op auto_approve row; deleted rather than built out.
  let(:autonomous_sdwan_categories) do
    %w[
      system.sdwan_peer_remediate
      system.sdwan_key_rotate
      system.sdwan_failover
      system.sdwan_user_device_revoke
      system.sdwan_bgp_session_remediate
      system.sdwan_vip_failover
    ].freeze
  end

  # Mirrors the two shapes System::Seeds::AgentSetupHelpers writes:
  # `upsert_policies!` → scope "agent" + ai_agent_id, priority 10;
  # `upsert_operator_policies!` → scope "action_type" + nil agent, priority 5.
  def seed_agent_policy!(category, agent, policy: "notify_and_proceed")
    Ai::InterventionPolicy.create!(
      account: account, action_category: category, scope: "agent",
      ai_agent_id: agent.id, policy: policy, priority: 10, is_active: true
    )
  end

  def seed_operator_policy!(category, policy: "require_approval")
    Ai::InterventionPolicy.create!(
      account: account, action_category: category, scope: "action_type",
      ai_agent_id: nil, policy: policy, priority: 5, is_active: true
    )
  end

  before do
    autonomous_sdwan_categories.each { |c| seed_agent_policy!(c, fleet_agent) }
    seed_agent_policy!("sdwan.peer_delete", sdwan_agent, policy: "require_approval")
    seed_operator_policy!("sdwan.network_create")
  end

  # The 7 + one agent-scoped operator verb + one operator-path row.
  let(:seeded_row_count) { autonomous_sdwan_categories.size + 2 }

  # The rows the panel renders: every by_domain bucket except the "other"
  # catch-all, which SystemSettingsPanel drops on its own side.
  def panel_rows
    get "/api/v1/system/autonomy", headers: auth_headers_for(operator)
    expect(response).to have_http_status(:ok)

    json_response_data.dig("policies", "by_domain")
      .reject { |domain, _| domain == "other" }
      .values.flatten
  end

  # What `useAutonomyConfig.save()` puts on the wire for one edited control:
  # the row's own identity, plus the operator's new verb.
  def update_body_for(row, policy)
    {
      updates: [
        {
          action_category: row["action_category"],
          policy: policy,
          scope: row["scope"],
          agent_id: row["agent_id"]
        }
      ]
    }
  end

  def patch_autonomy(body)
    patch "/api/v1/system/autonomy",
          params: body.to_json,
          headers: auth_headers_for(operator).merge("Content-Type" => "application/json")
  end

  # The audience the panel wrote the row FOR. A bucket naming a real agent means
  # that agent resolves it; "Manual Operations" is the agent-less operator path.
  def resolved_policy(row)
    agent = row["agent_bucket"] == "Manual Operations" ? nil : Ai::Agent.find_by(account: account, name: row["agent_bucket"])
    Ai::InterventionPolicyService.new(account: account)
      .resolve(action_category: row["action_category"], agent: agent)[:policy]
  end

  describe "every panel-editable row" do
    # The defect's signature, and the cheapest oracle for it: writing an
    # identity other than the one the row was rendered from INSERTS rather than
    # updates, and the original keeps deciding.
    it "is updated in place — no second row is inserted for any of them" do
      rows = panel_rows
      # Cardinality, not just non-emptiness: `not_to be_empty` keeps a sweep
      # green against a by_domain regression that ships one row. This is the
      # exact population the `before` block seeds.
      expect(rows.size).to eq(seeded_row_count)

      inserted = rows.filter_map do |row|
        before_count = Ai::InterventionPolicy.where(account: account, action_category: row["action_category"]).count
        patch_autonomy(update_body_for(row, "block"))

        # Without this the example is green whenever the endpoint rejects the
        # body WHOLESALE — nothing is written, so nothing is duplicated, and the
        # count comparison reports success for a save that 400'd. That is the
        # exact failure this file exists to catch.
        expect(response).to have_http_status(:ok)

        after_count = Ai::InterventionPolicy.where(account: account, action_category: row["action_category"]).count

        next if after_count == before_count

        "#{row['action_category']} (#{row['agent_bucket']}): #{before_count} -> #{after_count} rows"
      end

      expect(inserted).to be_empty,
                          "#{inserted.size} panel row(s) were duplicated rather than edited. The panel wrote an " \
                          "identity the row does not have, so the row it rendered is still the one that " \
                          "decides: #{inserted.join('; ')}"
    end

    it "resolves to the operator's verb for the agent the panel wrote it for" do
      rows = panel_rows
      # Cardinality, not just non-emptiness: `not_to be_empty` keeps a sweep
      # green against a by_domain regression that ships one row. This is the
      # exact population the `before` block seeds.
      expect(rows.size).to eq(seeded_row_count)

      # `block` is not a verb any row above is seeded with, so agreement here
      # cannot be the seeded value coincidentally matching.
      undecided = rows.filter_map do |row|
        patch_autonomy(update_body_for(row, "block"))
        expect(response).to have_http_status(:ok)

        effective = resolved_policy(row)
        next if effective == "block"

        "#{row['action_category']} (#{row['agent_bucket']}): resolves #{effective}"
      end

      expect(undecided).to be_empty,
                           "#{undecided.size} panel row(s) still resolve to something other than the verb the " \
                           "operator just saved — the edit is decorative for that audience: " \
                           "#{undecided.join('; ')}"
    end
  end

  # The seven the finding named. Kept separate from the derived sweep above
  # because the sweep proves coherence for whatever the pivot happens to ship,
  # and this proves the pivot ships THESE under Fleet Autonomy.
  describe "the 6 autonomous system.sdwan_* categories" do
    # The finding's actual subject, and the one thing the two examples below
    # CANNOT see: they assert against rows this file's own `before` block
    # created, so they would stay green if the seeds relocated these categories
    # tomorrow. This reads the seed sources instead.
    #
    # Same derivation as autonomy_domain_pivot_spec.rb: a seed entry is a
    # `"category" => "policy"` pair anchored on the real POLICIES constant, so
    # it matches definitions and NOT the prose in either file's NOTE comment —
    # both of which name all seven.
    it "are seeded on Fleet Autonomy and absent from the SDWAN Manager seed" do
      seed_dir = File.expand_path("../../../../../db/seeds", __dir__)
      entry_pattern = /"([a-z][a-z0-9_.]*)"\s*=>\s*"(?:#{Ai::InterventionPolicy::POLICIES.join('|')})"/

      categories_in = lambda do |file|
        File.read(File.join(seed_dir, file)).scan(entry_pattern).flatten
      end

      fleet = categories_in.call("fleet_autonomy_agent.rb")
      manager = categories_in.call("system_sdwan_manager_agent.rb")

      # Positive control: the same scan finds the operator CRUD verbs the SDWAN
      # Manager seed really does own. Without it, a pattern that matched nothing
      # anywhere would satisfy the exclusion below for the wrong reason.
      expect(manager).to include("sdwan.peer_delete", "sdwan.network_create")

      expect(fleet).to include(*autonomous_sdwan_categories)
      expect(manager & autonomous_sdwan_categories).to be_empty,
                                                       "the autonomous system.sdwan_* remediations are back on the SDWAN Manager seed. " \
                                                       "FleetAutonomyService::SENSORS gates them as Fleet Autonomy, so rows scoped to " \
                                                       "SDWAN Manager are never resolved by the sensor path."
    end

    it "are rendered under Fleet Autonomy, not SDWAN Manager" do
      buckets = panel_rows
        .select { |r| autonomous_sdwan_categories.include?(r["action_category"]) }
        .to_h { |r| [ r["action_category"], r["agent_bucket"] ] }

      expect(buckets.keys).to match_array(autonomous_sdwan_categories)
      expect(buckets.values.uniq).to eq([ "Fleet Autonomy" ])
    end

    it "binds the Fleet Autonomy sensor path after an operator edit" do
      row = panel_rows.find { |r| r["action_category"] == "system.sdwan_peer_remediate" }
      patch_autonomy(update_body_for(row, "auto_approve"))
      expect(response).to have_http_status(:ok)

      expect(resolved_policy(row)).to eq("auto_approve")
    end
  end

  # NEGATIVE CONTROL for the identity half. This is the body a panel that knew
  # only the category would send, and it is the reason `scope` + `agent_id` have
  # to ride along: the write SUCCEEDS (200, a row is persisted) and changes
  # nothing the agent sees.
  describe "a body naming only the category" do
    let(:category) { "system.sdwan_failover" }

    it "cannot outrank the agent-scoped row it was rendered from, at any priority" do
      patch_autonomy(updates: [ { action_category: category, policy: "auto_approve", priority: 9_999 } ])
      expect(response).to have_http_status(:ok)

      global_row = Ai::InterventionPolicy.find_by(account: account, action_category: category, scope: "global")
      expect(global_row).to be_present, "expected the identity-less write to have landed a scope-global row"

      effective = Ai::InterventionPolicyService.new(account: account)
        .resolve(action_category: category, agent: fleet_agent)[:policy]

      expect(effective).to eq("notify_and_proceed"),
                           "a scope-global row outranked the agent-scoped seed row; specificity_key is " \
                           "supposed to rank ai_agent_id presence above priority"
    end
  end

  # POSITIVE CONTROL for the endpoint's own parsing, and the pin for the half of
  # the wire contract that was wrong. `{policies:, agent_role:}` is what
  # useAutonomyConfig.save() emitted until this task: no `updates` key, so the
  # endpoint rejected the whole save and NOTHING an operator toggled was ever
  # persisted. Nothing server-side has ever read `agent_role`.
  describe "the request body the endpoint accepts" do
    it "persists an edit sent as an updates array" do
      expect {
        patch_autonomy(updates: [ { action_category: "sdwan.peer_delete", policy: "block",
                                    scope: "agent", agent_id: sdwan_agent.id } ])
      }.to change {
        Ai::InterventionPolicy.find_by(account: account, action_category: "sdwan.peer_delete",
                                       scope: "agent", ai_agent_id: sdwan_agent.id).policy
      }.from("require_approval").to("block")

      expect(response).to have_http_status(:ok)
    end

    it "rejects a per-agent {policies, agent_role} body instead of silently dropping it" do
      expect {
        patch_autonomy(policies: { "sdwan.peer_delete" => "block" }, agent_role: "sdwan")
      }.not_to change {
        Ai::InterventionPolicy.find_by(account: account, action_category: "sdwan.peer_delete",
                                       scope: "agent", ai_agent_id: sdwan_agent.id).policy
      }

      expect(response).to have_http_status(:bad_request)
    end
  end
end
