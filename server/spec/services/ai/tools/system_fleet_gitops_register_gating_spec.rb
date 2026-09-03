# frozen_string_literal: true

require "rails_helper"

# SWEEP-2026-09-03 — system_gitops_register_repository is approval-gated.
#
# THE FINDING (carried out of IMP-0b4f18ae4384, which gated the apply verb
# only). System::Governance::PolicyDeclarations::GITOPS_RECONCILER_POLICIES
# seeds "system.gitops_register_repository" => "require_approval", commented
# "adds a new declarative source of truth". Nothing evaluated it: the verb's
# declare_action carried `mutating: true` alone, so BaseTool#gated_action? was
# false and #execute went straight to #call, which INSERTed the repository.
# A registered repository is the input to every later sync and apply, so a
# caller who could not apply a diff unattended could still add the source
# those diffs come from.
#
# THE ORACLE IS THE ROW: each gated example counts System::GitopsRepository,
# and the replay example proves the verb still registers when the parked
# operation is approved — "gated" cannot be satisfied by a verb that refuses
# everything.
RSpec.describe "SystemFleetTool GitOps register gating (SWEEP-2026-09-03)" do
  let(:category) { Ai::Tools::SystemFleetTool::GITOPS_REGISTER_REPOSITORY_CATEGORY }

  let(:account) { create(:account) }
  let(:user) do
    create(:user, account: account, permissions: %w[system.nodes.read system.modules.update])
  end
  let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, user: user) }

  def register!(with: tool, **extra)
    with.execute(params: {
      action: "system_gitops_register_repository",
      name: "gated-register",
      repo_url: "https://git.example.test/fleet.git",
      branch: "main"
    }.merge(extra).with_indifferent_access)
  end

  def latest_deferred
    ::Ai::DeferredOperation.where(account_id: account.id).order(created_at: :desc).first
  end

  def registered?
    ::System::GitopsRepository.where(account_id: account.id, name: "gated-register").exists?
  end

  describe "the declaration" do
    it "arms the gate with the full quartet on the generic replay executor" do
      declaration = Ai::Tools::SystemFleetTool.declared_action("system_gitops_register_repository")

      expect(declaration).to be_present
      aggregate_failures do
        expect(declaration[:mutating]).to be(true)
        expect(declaration[:action_category]).to eq(category)
        expect(declaration[:executor_class]).to eq("Ai::Executors::DeferredToolCall")
        expect(declaration[:gate_context]).to be_present
        expect(declaration[:on_proceed]).to be_present
      end
    end

    it "names the category the GitOps Reconciler seed already carries" do
      expect(category).to eq("system.gitops_register_repository")
      expect(::System::Governance::PolicyDeclarations::GITOPS_RECONCILER_POLICIES.fetch(category))
        .to eq("require_approval")
    end

    it "registers the category so the Autonomy modal can save a row for it" do
      expect(Ai::InterventionPolicy.category_registered?(category)).to be(true)
    end

    it "announces the gate in the description an agent reads" do
      description = Ai::Tools::SystemFleetTool.action_definitions["system_gitops_register_repository"][:description]

      expect(description).to include(category)
      expect(description).to match(/pending/i)
      expect(description).to include("when policy requires approval")
      expect(description).not_to match(/unless .*auto_approve/i)
    end
  end

  describe "registering over MCP with no policy row" do
    it "parks the registration instead of inserting the repository" do
      expect { register! }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(registered?).to be(false), "the repository was inserted despite the gate"
      expect(latest_deferred.action_category).to eq(category)
      expect(latest_deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
    end

    it "answers the caller with the pending envelope" do
      response = register!

      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(response[:data][:action_category]).to eq(category)
      expect(response[:data][:deferred_operation_id]).to eq(latest_deferred.id)
    end

    it "really registers the repository when the parked operation is approved" do
      register!

      latest_deferred.execute_now!

      expect(registered?).to be(true)
    end
  end

  describe "a registration the model would refuse parks nothing" do
    it "refuses inline credentials in the URL with the model's own error, minting no approval" do
      expect {
        response = register!(repo_url: "https://user:secret@git.example.test/fleet.git")
        expect(response[:success]).to be(false)
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(registered?).to be(false)
    end
  end

  describe "authorization is not lost to the gate" do
    let(:reader) { create(:user, account: account, permissions: %w[system.nodes.read]) }

    it "refuses an unauthorized caller and parks nothing" do
      expect {
        response = register!(with: Ai::Tools::SystemFleetTool.new(account: account, user: reader))
        expect(response[:success]).to be(false)
      }.not_to change(::Ai::DeferredOperation, :count)
    end
  end
end
