# frozen_string_literal: true

require "rails_helper"

# IMP-9b9653e6514e — operator-path rows for the runtime categories that are
# ACTUALLY gated, and for no others.
#
# Two independent facts had to hold before an operator's Runtime Manager
# setting could do anything, and neither did:
#
#   1. a gate site must pass the category (only
#      system.runtime_k8s_cluster_decommission had one), and
#   2. the resolved row must match the CALLER. `Ai::GatedActions#gate!` and the
#      MCP tools' operator path pass `agent: nil`, and
#      `Ai::InterventionPolicy#agent_matches?` is
#      `return true if ai_agent_id.nil?; agent_record && ...` — so the seed's
#      agent-SCOPED rows can never match an agent-less caller.
#
# (2) is why even the ONE wired gate never consulted the operator's setting: it
# fell through Ai::InterventionPolicyService to its require_approval default,
# which happens to equal the seeded verb, so the control looked correct while
# being inert. Same ruling as the SDWAN Manager's (IMP-187124ca2984); see
# system_sdwan_operator_policies_spec.rb.
#
# The set is deliberately the GATED subset, not all seven. Seeding an
# operator row for an ungated category would manufacture exactly the defect
# this task exists to remove — a policy row an operator can edit that no code
# path reads — one layer further out.
RSpec.describe "Runtime Manager operator-path intervention policies" do
  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  def load_runtime_seed!
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds",
                           "system_runtime_manager_agent.rb")
    end
  end

  before { load_runtime_seed! }

  let(:runtime_agent) { Ai::Agent.global.find_by!(name: "Runtime Manager") }
  let(:service)       { Ai::InterventionPolicyService.new(account: account) }

  # Restated independently of the seed so a silent edit to either table shows up
  # as a failing expectation rather than as a change in what an operator gets.
  let(:gated_verbs) do
    {
      "system.runtime_docker_provision"         => "notify_and_proceed",
      "system.runtime_docker_decommission"      => "require_approval",
      "system.runtime_k8s_cluster_decommission" => "require_approval"
    }
  end

  # The other four seeded categories. Each has a policy row an operator can see,
  # and no gate site — tracked as separate offers rather than swept into this
  # change, because wiring them needs a surface (or an executor) that does not
  # exist yet, not a call.
  let(:ungated_categories) do
    %w[
      system.runtime_k8s_cluster_bootstrap
      system.runtime_k8s_node_join
      system.runtime_k8s_node_drain
      system.runtime_k8s_runtime_upgrade
    ]
  end

  it "seeds an active agent-less policy for every gated runtime verb" do
    missing = gated_verbs.keys.reject do |category|
      Ai::InterventionPolicy.exists?(
        account: account, ai_agent_id: nil, action_category: category, is_active: true
      )
    end

    expect(missing).to be_empty,
                       "no operator-path (agent-less) policy seeded for: #{missing.inspect}"
  end

  # The behavioural oracle. Row existence is not the claim — what an agent-less
  # caller RESOLVES to is, because that is what Ai::AutonomyGate branches on.
  it "resolves every gated verb to its recorded policy for an agent-less caller" do
    resolved = gated_verbs.keys.index_with do |category|
      service.resolve(action_category: category, agent: nil)[:policy]
    end

    expect(resolved).to eq(gated_verbs)
  end

  # The inverse enumeration, and the guard against the tempting over-fix. An
  # ungated category must NOT gain an operator row: the row would render as a
  # working control and still be read by nothing.
  it "seeds no operator row for a runtime category that has no gate site" do
    leaked = ungated_categories.select do |category|
      Ai::InterventionPolicy.exists?(account: account, ai_agent_id: nil, action_category: category)
    end

    expect(leaked).to be_empty,
                      "operator rows seeded for ungated categories: #{leaked.inspect}"
  end

  # ...and those categories still resolve to the default on the operator path,
  # which is the honest answer for an action no gate consults.
  it "leaves the ungated runtime categories on the require_approval default" do
    ungated_categories.each do |category|
      result = service.resolve(action_category: category, agent: nil)

      expect(result[:policy]).to eq("require_approval"), "#{category} resolved to #{result[:policy]}"
      expect(result[:record]).to be_nil, "an operator policy leaked onto ungated #{category}"
    end
  end

  # The two audiences must stay separate: adding operator rows must not displace
  # the Runtime Manager's own policy on the agent-dispatch path. Checked across
  # ALL seven seeded categories, not just the gated three.
  it "still resolves the agent-dispatch path against the Runtime Manager's own rows" do
    categories = gated_verbs.keys + ungated_categories

    displaced = categories.reject do |category|
      service.resolve(action_category: category, agent: runtime_agent)[:record]&.ai_agent_id == runtime_agent.id
    end

    expect(displaced).to be_empty,
                         "operator rows displaced the agent-scoped policy for: #{displaced.inspect}"
  end

  # IMP-bfbf8052e179 — the operator rows bind the operator audience ONLY. An
  # agent carrying no runtime rows of its own must not catch them.
  it "keeps an unrelated monitored-tier agent on the require_approval default" do
    other_agent = create(:ai_agent, account: account, provider: provider,
                         name: "Unrelated Fleet Agent")
    create(:ai_agent_trust_score, :monitored, account: account, agent: other_agent)

    gated_verbs.each_key do |category|
      result = service.resolve(action_category: category, agent: other_agent)

      expect(result[:policy]).to eq("require_approval"),
                                 "#{category} resolved to #{result[:policy]} for an unrelated agent"
      expect(result[:record]).to be_nil,
                                 "an operator row bound an unrelated agent on #{category}"
    end
  end

  # Defense in depth, mirroring the SDWAN ruling: the agent row must out-rank
  # the operator row on specificity_score too, which is what decides
  # `matching.max_by(&:specificity_score)` if the audience split ever regresses.
  it "ranks the agent-scoped row above the operator row on specificity alone" do
    category     = "system.runtime_docker_provision"
    agent_row    = Ai::InterventionPolicy.find_by!(account: account, action_category: category,
                                                   ai_agent_id: runtime_agent.id)
    operator_row = Ai::InterventionPolicy.find_by!(account: account, action_category: category,
                                                   ai_agent_id: nil)

    expect(agent_row.specificity_score).to be > operator_row.specificity_score
  end

  # Seeds are re-run on every deploy. The operator set and the agent set each
  # carry their own stale cleanup, and neither may eat the other's rows.
  it "is idempotent across a re-run" do
    expect { load_runtime_seed! }
      .not_to change {
        Ai::InterventionPolicy.where(account: account)
                              .order(:action_category, :ai_agent_id)
                              .pluck(:action_category, :ai_agent_id, :policy)
      }
  end
end
