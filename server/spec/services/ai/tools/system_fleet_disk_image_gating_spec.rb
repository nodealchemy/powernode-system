# frozen_string_literal: true

require "rails_helper"

# HIER-P2H — the three disk-image MCP verbs are approval-gated.
#
# THE FINDING (P2F, 2026-09-03). System::Governance::PolicyDeclarations::
# DISK_IMAGE_MANAGER_POLICIES seeds system.disk_image_publication_promote
# (require_approval), system.disk_image_publication_rollback (require_approval)
# and system.disk_image_retention_update (auto_approve), and P2F bound the
# Disk Image Manager's three skill executors to them. Each category had exactly
# ONE gate site — the skill executor — because the MCP verbs
# system_set_default_disk_image_publication, system_revert_disk_image and
# system_set_disk_image_retention were declared `mutating: true` alone, so
# BaseTool#gated_action? was false and #execute went straight to #call. The
# rows an operator tunes in the Autonomy modal governed the agent's skill door
# and nothing else; the MCP door bypassed them.
#
# Same shape as system_delete_volume_snapshot (IMP-e025722ef14e) and
# system_gitops_apply_proposal (IMP-0b4f18ae4384): the generic replay executor
# re-invokes the action as the ORIGINAL principal on approval, so the action
# body stays the single author of the write, and a gate context resolves the
# target under the account BEFORE parking so an unknown or foreign id keeps
# its inline error instead of becoming an approval that could only ever fail.
#
# THE ORACLE IS THE ROW, in every example: each gated example reads the
# NodePlatform back; the approval-replay and auto_approve examples prove the
# verb still writes, so "gated" cannot be satisfied by a verb that refuses
# everything.
RSpec.describe "SystemFleetTool disk-image verb gating (HIER-P2H)" do
  let(:account) { create(:account) }
  # system.nodes.read is the tool floor Ai::Executors::DeferredToolCall
  # re-asks for before replaying an approved call; the rest are the three
  # verbs' own ACTION_PERMISSIONS entries.
  let(:user) do
    create(:user, account: account,
                  permissions: %w[system.nodes.read system.modules.update system.platforms.rollback_disk_image])
  end
  let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, user: user) }

  let(:platform) { create(:system_node_platform, account: account, disk_image_retention_count: 3) }

  def latest_deferred
    ::Ai::DeferredOperation.where(account_id: account.id).order(created_at: :desc).first
  end

  def pending_ops
    ::Ai::DeferredOperation.where(account_id: account.id, status: "pending")
  end

  def auto_approve!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  # The seeded Disk Image Manager identity, scored so DEFAULT_TRUST_CONDITIONS
  # (trust_tier_minimum "monitored") match, with its agent-scoped rows minted
  # by the reconciler exactly as a booted install has them.
  def seeded_disk_image_manager!
    identity = ::System::Governance::PolicyDeclarations::AGENT_IDENTITIES.fetch("disk-image-manager")
    agent = create(:ai_agent, account: account, name: identity[:name],
                              agent_type: identity[:agent_type], source_key: "disk-image-manager")
    create(:ai_agent_trust_score, :monitored, account: account, agent: agent)
    ::System::Governance::PolicyReconciler.new(account: account).reconcile!
    agent
  end

  shared_examples "a fully armed disk-image gate" do |action, category, seeded_policy|
    describe "the declaration" do
      it "arms the gate with the full quartet on the generic replay executor" do
        declaration = Ai::Tools::SystemFleetTool.declared_action(action)

        expect(declaration).to be_present
        aggregate_failures do
          expect(declaration[:mutating]).to be(true)
          expect(declaration[:action_category]).to eq(category)
          expect(declaration[:executor_class]).to eq("Ai::Executors::DeferredToolCall")
          expect(declaration[:gate_context]).to be_present
          expect(declaration[:on_proceed]).to be_present
        end
      end

      it "is declared #{seeded_policy} on the disk-image-manager agent set — the row P2F's skill door already reads" do
        declared = ::System::Governance::PolicyDeclarations::DISK_IMAGE_MANAGER_POLICIES
        expect(declared.fetch(category)).to eq(seeded_policy)

        set = ::System::Governance::PolicyDeclarations::POLICY_SETS.find { |s| s[:policies].key?(category) }
        expect(set).to be_present, "no POLICY_SETS entry carries #{category}"
        expect(set[:agent_key]).to eq("disk-image-manager")
        expect(set[:scope]).to eq("agent")
      end

      it "registers the category so the Autonomy modal can save a row for it" do
        expect(Ai::InterventionPolicy.category_registered?(category)).to be(true)
      end

      it "pivots into the disk_image domain of the Autonomy modal" do
        prefixes = ::System::AutonomyActions::DOMAIN_PREFIXES.fetch("disk_image")
        expect(prefixes.any? { |p| category.start_with?(p) }).to be(true),
                                                                  "#{category} matches no disk_image prefix: #{prefixes.inspect}"
      end

      # An agent reads the CATALOG. A gated verb whose description reads as a
      # plain write is one an agent reports as completed on a pending envelope.
      it "announces the gate in the description an agent reads" do
        description = Ai::Tools::SystemFleetTool.action_definitions[action][:description]

        expect(description).to include(category)
        expect(description).to match(/pending/i)
        # CONDITIONED ON THE TIER, not on one policy value: Ai::AutonomyGate
        # proceeds inline for BOTH auto_approve and notify_and_proceed.
        expect(description).to include("when policy requires approval")
        expect(description).not_to match(/unless .*auto_approve/i)
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "system_set_default_disk_image_publication" do
    let(:category) { Ai::Tools::SystemFleetTool::DISK_IMAGE_PROMOTE_CATEGORY }
    let!(:publication) do
      create(:system_disk_image_publication, :published, account: account, node_platform: platform,
                                                         oci_ref: "registry.example.test/img:gated", git_sha: "gated-sha")
    end

    def promote!(id = publication.id, with: tool)
      with.execute(params: { action: "system_set_default_disk_image_publication",
                             publication_id: id }.with_indifferent_access)
    end

    def promoted?
      platform.reload.disk_image_git_sha == "gated-sha"
    end

    include_examples "a fully armed disk-image gate",
                     "system_set_default_disk_image_publication",
                     "system.disk_image_publication_promote", "require_approval"

    it "names the category the Disk Image Manager seed already carries" do
      expect(category).to eq("system.disk_image_publication_promote")
    end

    describe "promoting over MCP with no policy row" do
      it "parks the promote instead of repointing the platform" do
        expect { promote! }.to change(::Ai::DeferredOperation, :count).by(1)

        expect(promoted?).to be(false), "the platform was repointed despite the gate"
        expect(latest_deferred.action_category).to eq(category)
        expect(latest_deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
      end

      it "anchors the parked operation to the publication row and names it from row values" do
        promote!

        expect(latest_deferred.source_type).to eq("System::DiskImagePublication")
        expect(latest_deferred.source_id).to eq(publication.id)
        expect(latest_deferred.description).to include(platform.name)
        expect(latest_deferred.description).to include("gated-sha")
      end

      it "answers the caller with the pending envelope" do
        response = promote!

        expect(response[:success]).to be(true)
        expect(response[:data][:pending]).to be(true)
        expect(response[:data][:action_category]).to eq(category)
        expect(response[:data][:deferred_operation_id]).to eq(latest_deferred.id)
      end

      it "really promotes the publication when the parked operation is approved" do
        promote!

        latest_deferred.execute_now!

        expect(promoted?).to be(true)
        expect(platform.reload.disk_image_file_object_id).to eq(publication.file_object_id)
      end
    end

    describe "the auto_approve tier" do
      before { auto_approve! }

      it "promotes once and answers exactly as the ungated arm did" do
        response = promote!

        expect(promoted?).to be(true)
        expect(response[:success]).to be(true)
        expect(response[:data][:set_default]).to be(true)
        expect(response[:data][:publication_id]).to eq(publication.id)
        expect(response[:data][:node_platform_id]).to eq(platform.id)
        expect(response[:data][:git_sha]).to eq("gated-sha")
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

      it "blocks the promote, leaves the platform alone, and reports the refusal" do
        response = promote!

        expect(response[:success]).to be(false)
        expect(response[:error]).to be_present
        expect(promoted?).to be(false)
        expect(pending_ops).to be_empty
      end
    end

    # THE SEEDED ROW binds the Disk Image Manager and no one else; an
    # operator-tuned verb on it is the discriminating oracle (require_approval
    # equals the unmatched default and could not tell a bound row from none).
    describe "the seeded disk-image-manager row is what governs the agent's own call" do
      let!(:manager) { seeded_disk_image_manager! }
      let!(:seeded_row) do
        row = ::Ai::InterventionPolicy.find_by(account: account, action_category: category,
                                               scope: "agent", ai_agent_id: manager.id)
        expect(row).to be_present, "the reconciler minted no #{category} row for the Disk Image Manager"
        expect(row.policy).to eq("require_approval")
        row.update!(policy: "block")
        row
      end

      it "is evaluated when the agent asks — the operator's verb is what answers" do
        as_manager = Ai::Tools::SystemFleetTool.new(account: account, agent: manager, internal: true)

        response = promote!(with: as_manager)

        expect(response[:success]).to be(false)
        expect(response[:error]).to be_present
        expect(promoted?).to be(false)
      end

      it "does not bind an operator caller, who still meets the unmatched default and parks" do
        response = promote!

        expect(response[:success]).to be(true)
        expect(response[:data][:pending]).to be(true)
        expect(promoted?).to be(false)
      end
    end

    describe "authorization is not lost to the gate" do
      let(:user) { create(:user, account: account, permissions: %w[system.nodes.read]) }

      it "refuses an unauthorized caller and parks nothing" do
        response = promote!

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("permission denied")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end
    end

    describe "a target that cannot be promoted parks nothing" do
      it "refuses an unknown publication with the inline error, minting no approval" do
        response = promote!(SecureRandom.uuid)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("Couldn't find System::DiskImagePublication")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end

      it "refuses another account's publication the same way" do
        other = create(:account)
        foreign = create(:system_disk_image_publication, :published, account: other,
                                                                     node_platform: create(:system_node_platform, account: other))

        response = promote!(foreign.id)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("Couldn't find System::DiskImagePublication")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end

      # The verb's own admission rule (published only) ran inline before the
      # gate existed; it must not regress into an approval that fails on replay.
      it "refuses a publication that is not published with the verb's own inline error" do
        queued = create(:system_disk_image_publication, account: account, node_platform: platform, status: "queued")

        response = promote!(queued.id)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("only 'published'")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "system_revert_disk_image" do
    let(:category) { Ai::Tools::SystemFleetTool::DISK_IMAGE_ROLLBACK_CATEGORY }
    let!(:target) do
      create(:system_disk_image_publication, :published, account: account, node_platform: platform,
                                                         oci_ref: "registry.example.test/img:target", git_sha: "target-sha")
    end
    let!(:current) do
      create(:system_disk_image_publication, :published, account: account, node_platform: platform,
                                                         oci_ref: "registry.example.test/img:current", git_sha: "current-sha")
    end

    before do
      platform.update!(disk_image_file_object_id: current.file_object_id,
                       disk_image_oci_ref: current.oci_ref, disk_image_git_sha: current.git_sha)
    end

    def revert!(with: tool, **extra)
      with.execute(params: { action: "system_revert_disk_image",
                             platform_id: platform.id }.merge(extra).with_indifferent_access)
    end

    def reverted?
      platform.reload.disk_image_git_sha == "target-sha"
    end

    include_examples "a fully armed disk-image gate",
                     "system_revert_disk_image",
                     "system.disk_image_publication_rollback", "require_approval"

    # The literal is the REST twin's category too (DiskImagePublicationsController
    # #rollback), so ONE operator-tuned row governs a rollback whichever door it
    # arrives through.
    it "names the category the REST rollback door already gates on" do
      expect(category).to eq("system.disk_image_publication_rollback")
    end

    describe "reverting over MCP with no policy row" do
      it "parks the rollback instead of repointing the platform" do
        expect { revert!(publication_id: target.id) }.to change(::Ai::DeferredOperation, :count).by(1)

        expect(reverted?).to be(false), "the platform was rolled back despite the gate"
        expect(latest_deferred.action_category).to eq(category)
        expect(latest_deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
      end

      it "anchors the parked operation to the target publication, resolved at park time" do
        revert!

        expect(latest_deferred.source_type).to eq("System::DiskImagePublication")
        expect(latest_deferred.source_id).to eq(target.id)
        expect(latest_deferred.description).to include(platform.name)
        expect(latest_deferred.description).to include("target-sha")
      end

      # Auto-selection happens at PARK time and the replay is pinned to it,
      # so the operator approves the publication the card names — not
      # whichever one the selection would pick later.
      it "pins the auto-selected target into the replayed params" do
        revert!

        expect(latest_deferred.params.dig("tool_params", "publication_id")).to eq(target.id)
      end

      it "answers the caller with the pending envelope" do
        response = revert!(publication_id: target.id)

        expect(response[:success]).to be(true)
        expect(response[:data][:pending]).to be(true)
        expect(response[:data][:action_category]).to eq(category)
        expect(response[:data][:deferred_operation_id]).to eq(latest_deferred.id)
      end

      it "really rolls the platform back when the parked operation is approved" do
        revert!(publication_id: target.id)

        latest_deferred.execute_now!

        expect(reverted?).to be(true)
        expect(platform.reload.disk_image_file_object_id).to eq(target.file_object_id)
        expect(current.reload.status).to eq("retired")
      end
    end

    describe "the auto_approve tier" do
      before { auto_approve! }

      it "rolls back once and answers exactly as the ungated arm did" do
        response = revert!(publication_id: target.id)

        expect(reverted?).to be(true)
        expect(response[:success]).to be(true)
        expect(response[:data][:reverted]).to be(true)
        expect(response[:data][:node_platform_id]).to eq(platform.id)
        expect(response[:data][:activated_publication_id]).to eq(target.id)
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

      it "blocks the rollback, leaves the platform alone, and reports the refusal" do
        response = revert!(publication_id: target.id)

        expect(response[:success]).to be(false)
        expect(response[:error]).to be_present
        expect(reverted?).to be(false)
        expect(pending_ops).to be_empty
      end
    end

    describe "authorization is not lost to the gate" do
      let(:user) { create(:user, account: account, permissions: %w[system.nodes.read system.modules.update]) }

      it "refuses a caller without system.platforms.rollback_disk_image and parks nothing" do
        response = revert!(publication_id: target.id)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("permission denied")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end
    end

    describe "a target that cannot be resolved parks nothing" do
      it "refuses an unknown platform with the inline error, minting no approval" do
        response = tool.execute(params: { action: "system_revert_disk_image",
                                          platform_id: SecureRandom.uuid }.with_indifferent_access)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("Couldn't find System::NodePlatform")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end

      it "refuses another account's platform the same way" do
        foreign = create(:system_node_platform, account: create(:account))

        response = tool.execute(params: { action: "system_revert_disk_image",
                                          platform_id: foreign.id, publication_id: target.id }.with_indifferent_access)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("Couldn't find System::NodePlatform")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end

      it "refuses a publication that is not this platform's with the verb's own inline error" do
        response = revert!(publication_id: SecureRandom.uuid)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("not found for this platform")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end

      it "refuses a purged target inline" do
        target.update_columns(status: "purged", file_object_id: nil)

        response = revert!(publication_id: target.id)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("purged")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end

      it "refuses a target with no stored artifact inline" do
        target.update_columns(file_object_id: nil)

        response = revert!(publication_id: target.id)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("no file_object")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end

      it "refuses a platform with nothing to revert to inline" do
        empty = create(:system_node_platform, account: account)

        response = tool.execute(params: { action: "system_revert_disk_image",
                                          platform_id: empty.id }.with_indifferent_access)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("No prior publication")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe "system_set_disk_image_retention" do
    let(:category) { Ai::Tools::SystemFleetTool::DISK_IMAGE_RETENTION_CATEGORY }

    def set_retention!(count = 10, with: tool, platform_id: platform.id)
      with.execute(params: { action: "system_set_disk_image_retention",
                             node_platform_id: platform_id, retention_count: count }.with_indifferent_access)
    end

    include_examples "a fully armed disk-image gate",
                     "system_set_disk_image_retention",
                     "system.disk_image_retention_update", "auto_approve"

    it "names the category the Disk Image Manager seed already carries" do
      expect(category).to eq("system.disk_image_retention_update")
    end

    describe "setting retention over MCP with no policy row" do
      it "parks the update instead of writing the count" do
        expect { set_retention! }.to change(::Ai::DeferredOperation, :count).by(1)

        expect(platform.reload.disk_image_retention_count).to eq(3)
        expect(latest_deferred.action_category).to eq(category)
        expect(latest_deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
      end

      it "anchors the parked operation to the platform row" do
        set_retention!

        expect(latest_deferred.source_type).to eq("System::NodePlatform")
        expect(latest_deferred.source_id).to eq(platform.id)
        expect(latest_deferred.description).to include(platform.name)
      end

      it "answers the caller with the pending envelope" do
        response = set_retention!

        expect(response[:success]).to be(true)
        expect(response[:data][:pending]).to be(true)
        expect(response[:data][:action_category]).to eq(category)
        expect(response[:data][:deferred_operation_id]).to eq(latest_deferred.id)
      end

      it "really writes the count when the parked operation is approved" do
        set_retention!

        latest_deferred.execute_now!

        expect(platform.reload.disk_image_retention_count).to eq(10)
      end
    end

    describe "the auto_approve tier" do
      before { auto_approve! }

      it "writes once and answers exactly as the ungated arm did" do
        response = set_retention!

        expect(platform.reload.disk_image_retention_count).to eq(10)
        expect(response[:success]).to be(true)
        expect(response[:data][:updated]).to be(true)
        expect(response[:data][:node_platform_id]).to eq(platform.id)
        expect(response[:data][:disk_image_retention_count]).to eq(10)
      end
    end

    # The seeded row is auto_approve on the agent set: the agent's own call
    # runs inline, proving the row — not the descriptor — decides.
    describe "the seeded disk-image-manager row is what governs the agent's own call" do
      # The inline replay re-asks BaseTool.permitted?(agent:), which is true
      # for an account-owned agent only when SOME user in its account holds
      # the tool floor — materialise the operator so the account has one.
      let!(:operator) { user }
      let!(:manager) { seeded_disk_image_manager! }
      let!(:seeded_row) do
        row = ::Ai::InterventionPolicy.find_by(account: account, action_category: category,
                                               scope: "agent", ai_agent_id: manager.id)
        expect(row).to be_present, "the reconciler minted no #{category} row for the Disk Image Manager"
        expect(row.policy).to eq("auto_approve")
        row
      end

      it "runs the agent's call inline under the seeded auto_approve row" do
        as_manager = Ai::Tools::SystemFleetTool.new(account: account, agent: manager, internal: true)

        response = set_retention!(with: as_manager)

        expect(response[:success]).to be(true)
        expect(response[:data][:updated]).to be(true)
        expect(platform.reload.disk_image_retention_count).to eq(10)
        expect(pending_ops).to be_empty
      end

      it "parks the same call once the operator tightens the row" do
        seeded_row.update!(policy: "require_approval")
        as_manager = Ai::Tools::SystemFleetTool.new(account: account, agent: manager, internal: true)

        response = set_retention!(with: as_manager)

        expect(response[:success]).to be(true)
        expect(response[:data][:pending]).to be(true)
        expect(platform.reload.disk_image_retention_count).to eq(3)
      end
    end

    describe "authorization is not lost to the gate" do
      let(:user) { create(:user, account: account, permissions: %w[system.nodes.read]) }

      it "refuses an unauthorized caller and parks nothing" do
        response = set_retention!

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("permission denied")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end
    end

    describe "a call that could only fail parks nothing" do
      it "refuses an unknown platform with the inline error, minting no approval" do
        response = set_retention!(platform_id: SecureRandom.uuid)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("Couldn't find System::NodePlatform")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end

      it "refuses another account's platform the same way" do
        foreign = create(:system_node_platform, account: create(:account))

        response = set_retention!(platform_id: foreign.id)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("Couldn't find System::NodePlatform")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end

      it "refuses retention_count < 1 with the verb's own inline error" do
        response = set_retention!(0)

        expect(response[:success]).to be(false)
        expect(response[:error]).to include("must be ≥1")
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end

      # NodePlatform's own upper bound (1..50) is checked BEFORE the gate for
      # the same reason: it can only ever fail on replay.
      it "refuses retention_count above the model's bound inline" do
        response = set_retention!(51)

        expect(response[:success]).to be(false)
        expect(response[:error]).to match(/less than or equal to 50/)
        expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      end
    end
  end
end
