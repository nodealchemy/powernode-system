# frozen_string_literal: true

require "rails_helper"

# IMP-0b4f18ae4384 — system_gitops_apply_proposal is approval-gated.
#
# THE FINDING. System::Governance::PolicyDeclarations::GITOPS_RECONCILER_POLICIES
# seeds "system.gitops_apply_proposal" => "require_approval", commented
# "applies a diff to live fleet state". Nothing evaluated it: the verb's
# declare_action carried `mutating: true` and nothing else, so
# BaseTool#gated_action? was false and #execute went straight to #call, which
# ran System::Gitops::ApplyService on the live fleet. The policy row was the
# artifact an operator would check to confirm the gate exists, and its
# presence is what made the absence invisible.
#
# THE ORACLE IS THE ROW, in every example (the IMP-ce5d320d3e4e lesson: a
# refusal rendered from an action body while the write lands). Each gated
# example reads the target template back and the proposal's status; the
# approval-replay and auto_approve examples prove the verb still applies, so
# "gated" cannot be satisfied by a verb that refuses everything.
RSpec.describe "SystemFleetTool GitOps apply gating (IMP-0b4f18ae4384)" do
  let(:category) { Ai::Tools::SystemFleetTool::GITOPS_APPLY_PROPOSAL_CATEGORY }

  let(:account) { create(:account) }
  # system.nodes.read is the tool floor Ai::Executors::DeferredToolCall
  # re-asks for before replaying an approved call (see the volume-snapshot
  # gating spec for why it rides alongside the per-action permission).
  let(:user) do
    create(:user, account: account, permissions: %w[system.nodes.read system.modules.update])
  end
  let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, user: user) }

  let(:platform) { create(:system_node_platform, account: account) }
  let(:author) { create(:ai_agent, account: account) }
  let!(:gitops_repo) do
    ::System::GitopsRepository.create!(
      account: account, name: "gated-apply",
      repo_url: "https://git.example.test/fleet.git", branch: "main"
    )
  end

  def make_proposal(status: "approved", name: "edge-gated", account_record: account)
    ::Ai::AgentProposal.create!(
      account: account_record,
      ai_agent_id: author.id,
      title: "GitOps: create template #{name}",
      description: "gating spec",
      proposal_type: "configuration",
      status: status,
      priority: "medium",
      proposed_changes: {
        diff: { kind: "template", change: "create", name: name,
                resource_id: nil, current: nil,
                desired: { name: name, node_platform: platform.name } },
        source: "gitops", repository_id: gitops_repo.id, commit_sha: "abc123"
      }
    )
  end

  let!(:proposal) { make_proposal }

  def apply!(id = proposal.id, with: tool)
    with.execute(params: { action: "system_gitops_apply_proposal", proposal_id: id }.with_indifferent_access)
  end

  def latest_deferred
    ::Ai::DeferredOperation.where(account_id: account.id).order(created_at: :desc).first
  end

  def template_applied?(name = "edge-gated")
    ::System::NodeTemplate.where(account_id: account.id, name: name).exists?
  end

  describe "the declaration" do
    it "arms the gate with the full quartet on the generic replay executor" do
      declaration = Ai::Tools::SystemFleetTool.declared_action("system_gitops_apply_proposal")

      expect(declaration).to be_present
      aggregate_failures do
        expect(declaration[:mutating]).to be(true)
        expect(declaration[:action_category]).to eq(category)
        expect(declaration[:executor_class]).to eq("Ai::Executors::DeferredToolCall")
        expect(declaration[:gate_context]).to be_present
        expect(declaration[:on_proceed]).to be_present
      end
    end

    # Pinned as a literal, not only through the constant: the category is the
    # seed's key and the operator's handle in the Autonomy modal, and a
    # constant-only comparison would stay green through a rename that
    # orphaned the seeded row this task exists to make real.
    it "names the category the GitOps Reconciler seed already carries" do
      expect(category).to eq("system.gitops_apply_proposal")
    end

    it "is declared require_approval on the gitops-reconciler agent set" do
      declared = ::System::Governance::PolicyDeclarations::GITOPS_RECONCILER_POLICIES
      expect(declared.fetch(category)).to eq("require_approval")

      set = ::System::Governance::PolicyDeclarations::POLICY_SETS.find { |s| s[:policies].key?(category) }
      expect(set).to be_present, "no POLICY_SETS entry carries #{category}"
      expect(set[:agent_key]).to eq("gitops-reconciler")
      expect(set[:scope]).to eq("agent")
    end

    it "registers the category so the Autonomy modal can save a row for it" do
      expect(Ai::InterventionPolicy.category_registered?(category)).to be(true)
    end

    it "pivots into the gitops domain of the Autonomy modal" do
      prefixes = ::System::AutonomyActions::DOMAIN_PREFIXES.fetch("gitops")
      expect(prefixes.any? { |p| category.start_with?(p) }).to be(true),
                                                                "#{category} matches no gitops prefix: #{prefixes.inspect}"
    end

    # An agent reads the CATALOG. A gated verb whose description reads as a
    # plain write is one an agent reports as completed on a pending envelope.
    it "announces the gate in the description an agent reads" do
      description = Ai::Tools::SystemFleetTool.action_definitions["system_gitops_apply_proposal"][:description]

      expect(description).to include(category)
      expect(description).to match(/pending/i)

      # CONDITIONED ON THE TIER, not on one policy value. Ai::AutonomyGate
      # proceeds inline for BOTH "auto_approve" and "notify_and_proceed"
      # (autonomy_gate.rb:87-89), so wording like "unless a policy row
      # resolves to auto_approve the call returns pending" is false for an
      # operator who picks notify_and_proceed — it promises a park in front
      # of a live fleet write that will not happen.
      expect(description).to include("when policy requires approval")
      expect(description).not_to match(/unless .*auto_approve/i)
    end
  end

  describe "applying over MCP with no policy row" do
    it "parks the apply instead of writing the diff to the fleet" do
      expect { apply! }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(template_applied?).to be(false), "the template was created despite the gate"
      expect(proposal.reload.status).to eq("approved")
      expect(latest_deferred.action_category).to eq(category)
      expect(latest_deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
    end

    it "anchors the parked operation to the proposal row" do
      apply!

      expect(latest_deferred.source_type).to eq("Ai::AgentProposal")
      expect(latest_deferred.source_id).to eq(proposal.id)
    end

    it "answers the caller with the pending envelope" do
      response = apply!

      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(response[:data][:action_category]).to eq(category)
      expect(response[:data][:deferred_operation_id]).to eq(latest_deferred.id)
    end

    # "It parks" and "the parked operation still performs the work" are two
    # different claims; only the second says the verb still functions.
    it "really applies the diff and implements the proposal when the parked operation is approved" do
      apply!

      latest_deferred.execute_now!

      expect(template_applied?).to be(true)
      expect(proposal.reload.status).to eq("implemented")
    end
  end

  describe "the auto_approve tier" do
    before do
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
    end

    # On :proceed the EXECUTOR is the actor, so the response SERIALIZES what
    # the replay returned — byte-identical to the old ungated envelope.
    it "applies once and answers exactly as the ungated arm did" do
      response = apply!

      expect(::System::NodeTemplate.where(account_id: account.id, name: "edge-gated").count).to eq(1)
      expect(response[:success]).to be(true)
      expect(response[:data][:applied]).to be(true)
      expect(response[:data][:applied_action]).to eq("created template")
      expect(response[:data][:proposal_id]).to eq(proposal.id)
      expect(response[:data][:proposal_status]).to eq("implemented")
    end

    # IMP-4a3a45df69bc's refusal contract survives the gate: the replay's
    # failure envelope is handed back verbatim, not re-shaped as a proceed.
    it "keeps the refusal shape for a proposal ApplyService will not apply" do
      pending_proposal = make_proposal(status: "pending_review", name: "never-applied")

      response = apply!(pending_proposal.id)

      expect(response[:success]).to be(false)
      expect(response[:error]).to include("only 'approved'")
      expect(response.dig(:data, :applied)).to be(false)
      expect(template_applied?("never-applied")).to be(false)
    end
  end

  describe "a policy row for the declared category actually binds this verb" do
    before do
      ::Ai::InterventionPolicy.create!(
        account: account, action_category: category,
        scope: "global", ai_agent_id: nil, user_id: nil,
        policy: "block", priority: 5, is_active: true,
        conditions: {}, preferred_channels: %w[notification]
      )
    end

    it "blocks the apply, leaves the proposal approved, and reports the refusal" do
      response = apply!

      expect(response[:success]).to be(false)
      expect(response[:error]).to be_present
      expect(template_applied?).to be(false)
      expect(proposal.reload.status).to eq("approved")
      expect(::Ai::DeferredOperation.where(account_id: account.id, status: "pending")).to be_empty
    end
  end

  # THE SEEDED ROW. It is written at scope "agent" against the GitOps
  # Reconciler, so it binds that agent and no one else; the discriminating
  # oracle is therefore an operator-tuned VERB on that row (require_approval
  # equals the unmatched default and could not tell a bound row from none).
  describe "the seeded gitops-reconciler row is what governs the reconciler's own call" do
    let(:reconciler) do
      identity = ::System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch("gitops-reconciler")
      create(:ai_agent, account: account, name: identity[:name],
                        agent_type: identity[:agent_type], source_key: "gitops-reconciler")
    end
    # The seeded set carries DEFAULT_TRUST_CONDITIONS (trust_tier_minimum
    # "monitored"); an unscored agent is "supervised" and would not match.
    let!(:trust) { create(:ai_agent_trust_score, :monitored, account: account, agent: reconciler) }

    let!(:seeded_row) do
      ::System::Governance::PolicyReconciler.new(account: account).reconcile!

      row = ::Ai::InterventionPolicy.find_by(account: account, action_category: category,
                                             scope: "agent", ai_agent_id: reconciler.id)
      expect(row).to be_present, "the reconciler minted no #{category} row for the GitOps Reconciler"
      expect(row.policy).to eq("require_approval")
      row.update!(policy: "block")
      row
    end

    it "is evaluated when the reconciler agent asks — the operator's verb is what answers" do
      as_reconciler = Ai::Tools::SystemFleetTool.new(account: account, agent: reconciler, internal: true)

      response = apply!(with: as_reconciler)

      expect(response[:success]).to be(false)
      expect(response[:error]).to be_present
      expect(template_applied?).to be(false)
      expect(proposal.reload.status).to eq("approved")
    end

    it "does not bind an operator caller, who still meets the unmatched default and parks" do
      response = apply!

      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(template_applied?).to be(false)
    end
  end

  describe "authorization is not lost to the gate" do
    let(:user) { create(:user, account: account, permissions: []) }

    it "refuses an unauthorized caller and parks nothing" do
      response = apply!

      expect(response[:success]).to be(false)
      expect(response[:error]).to include("permission denied")
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end
  end

  describe "a target that cannot be resolved parks nothing" do
    it "refuses an unknown proposal with the inline error, minting no approval" do
      response = apply!(SecureRandom.uuid)

      expect(response[:success]).to be(false)
      expect(response[:error]).to include("Couldn't find Ai::AgentProposal")
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end

    it "refuses another account's proposal the same way" do
      foreign = make_proposal(name: "foreign-edge", account_record: create(:account))

      response = apply!(foreign.id)

      expect(response[:success]).to be(false)
      expect(response[:error]).to include("Couldn't find Ai::AgentProposal")
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      expect(foreign.reload.status).to eq("approved")
    end
  end
end
