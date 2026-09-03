# frozen_string_literal: true

require "rails_helper"

# IMP-e025722ef14e — APO-5 remainder, door 1: snapshot DELETE is approval-gated.
#
# APO-5 (IMP-4b4bed6967ed) landed system_delete_volume_snapshot behind the
# system.volumes.delete permission ALONE and said so at the declaration: the
# operator direction settled that a snapshot delete must be approval-gated,
# but policy_declarations.rb belonged to another lane that batch, and a
# guessed action_category is not inert — an unmatched one resolves to the
# default require_approval with no operator-visible row to tune. So the gate
# and the category land together here, exactly as the direction asked.
#
# THE ORACLE IS THE ROW, in every example (the IMP-ce5d320d3e4e lesson: a
# refusal rendered from an action body while the write lands). Each gated
# example reads the snapshot back and checks the provider was NOT asked; the
# approval-replay and auto_approve examples prove the verb still deletes, so
# "gated" cannot be satisfied by a verb that refuses everything.
RSpec.describe "SystemFleetTool volume-snapshot delete gating (IMP-e025722ef14e)" do
  let(:category) { Ai::Tools::SystemFleetTool::VOLUME_SNAPSHOT_DELETE_CATEGORY }

  let(:account) { create(:account) }
  # system.nodes.read is the tool floor Ai::Executors::DeferredToolCall
  # re-asks for before replaying an approved call (see the instance-pool
  # gating spec for why it rides alongside the per-action permission).
  let(:user) do
    create(:user, account: account,
                  permissions: %w[system.nodes.read system.volumes.read system.volumes.delete])
  end
  let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, user: user) }

  let(:volume) do
    create(:system_provider_volume, account: account, status: "available", external_id: "vol-1")
  end
  let!(:snapshot) do
    create(:system_provider_volume_snapshot, account: account, volume: volume,
                                             status: "completed", external_id: "snap-1")
  end

  let(:adapter) { instance_double(System::Providers::BaseProvider) }

  before do
    allow(System::Providers::Registry).to receive(:for_volume).and_return(adapter)
    allow(adapter).to receive(:supports_volume_snapshots?).and_return(true)
    allow(adapter).to receive(:delete_volume_snapshot).and_return({ success: true })
  end

  def delete!(id = snapshot.id)
    tool.execute(params: { action: "system_delete_volume_snapshot", id: id }.with_indifferent_access)
  end

  def latest_deferred
    ::Ai::DeferredOperation.where(account_id: account.id).order(created_at: :desc).first
  end

  describe "the declaration" do
    it "arms the gate with the full quartet on the generic replay executor" do
      declaration = Ai::Tools::SystemFleetTool.declared_action("system_delete_volume_snapshot")

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
    # operator's handle in the Autonomy modal and the seed's key, and a
    # constant-only comparison would stay green through a rename that
    # orphaned every existing policy row.
    it "names a category under the storage family" do
      expect(category).to eq("system.volume_snapshot_delete")
    end

    it "declares the category at the operator (global) shape, require_approval, in the same change" do
      declared = ::System::Governance::PolicyDeclarations::VOLUME_SNAPSHOT_OPERATOR_POLICIES
      expect(declared.fetch(category)).to eq("require_approval")

      sets = ::System::Governance::PolicyDeclarations::POLICY_SETS.select { |s| s[:policies].key?(category) }
      operator = sets.find { |s| s[:agent_key].nil? }
      expect(operator).to be_present, "no operator-shape POLICY_SETS entry carries #{category}"
      expect(operator[:scope]).to eq("global")
      # HIER-P2DECL: the operator set keeps this row AND has an agent twin.
      expect(sets.map { |s| s[:agent_key] }).to contain_exactly(nil, "storage-manager")
      expect(::System::Governance::PolicyDeclarations::OPERATOR_TWINS.fetch(operator[:key])).to eq("storage-manager")
    end

    it "registers the category so the Autonomy modal can save a row for it" do
      expect(Ai::InterventionPolicy.category_registered?(category)).to be(true)
    end

    # The by_domain pivot files every registered system.* category under a
    # drawn section; anything unmatched lands in the "other" bucket the panel
    # skips, which would make the row invisible exactly where an operator
    # would look for it.
    it "pivots into the storage domain of the Autonomy modal" do
      prefixes = ::System::AutonomyActions::DOMAIN_PREFIXES.fetch("storage")
      expect(prefixes.any? { |p| category.start_with?(p) }).to be(true),
                                                                "#{category} matches no storage prefix: #{prefixes.inspect}"
    end

    # An agent reads the CATALOG. A gated verb whose description reads as a
    # plain write is one an agent reports as completed on a pending envelope.
    it "announces the gate in the description an agent reads" do
      description = Ai::Tools::SystemFleetTool.action_definitions["system_delete_volume_snapshot"][:description]

      expect(description).to include(category)
      expect(description).to match(/pending/i)
    end

    # Both row writers are pinned: db:seed is first-boot only, so on an
    # already-booted install the reconciler is the only thing that mints the
    # operator row. Reading the real reconciler, not a hand-built set.
    it "is minted by the governance reconciler at the operator shape" do
      ::System::Governance::PolicyReconciler.new(account: account).reconcile!

      row = ::Ai::InterventionPolicy.find_by(account: account, action_category: category,
                                             scope: "global", ai_agent_id: nil)
      expect(row).to be_present
      expect(row.policy).to eq("require_approval")
    end
  end

  describe "deleting over MCP with no operator row" do
    it "parks the delete instead of destroying the restore point" do
      expect { delete! }.to change(::Ai::DeferredOperation, :count).by(1)

      expect(::System::ProviderVolumeSnapshot.find_by(id: snapshot.id)).to be_present,
                                                                            "the restore point was destroyed despite the gate"
      expect(adapter).not_to have_received(:delete_volume_snapshot)
      expect(latest_deferred.action_category).to eq(category)
      expect(latest_deferred.executor_class).to eq("Ai::Executors::DeferredToolCall")
    end

    it "anchors the parked operation to the snapshot row" do
      delete!

      expect(latest_deferred.source_type).to eq("System::ProviderVolumeSnapshot")
      expect(latest_deferred.source_id).to eq(snapshot.id)
    end

    it "answers the caller with the pending envelope" do
      response = delete!

      expect(response[:success]).to be(true)
      expect(response[:data][:pending]).to be(true)
      expect(response[:data][:action_category]).to eq(category)
      expect(response[:data][:deferred_operation_id]).to eq(latest_deferred.id)
    end

    # "It parks" and "the parked operation still performs the work" are two
    # different claims; only the second says the verb still functions.
    it "really deletes at the provider and drops the row when the parked operation is approved" do
      delete!

      latest_deferred.execute_now!

      expect(adapter).to have_received(:delete_volume_snapshot).with("snap-1")
      expect(::System::ProviderVolumeSnapshot.find_by(id: snapshot.id)).to be_nil
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
    it "deletes once and answers exactly as the ungated arm did" do
      response = delete!

      expect(adapter).to have_received(:delete_volume_snapshot).with("snap-1").once
      expect(::System::ProviderVolumeSnapshot.find_by(id: snapshot.id)).to be_nil
      expect(response[:success]).to be(true)
      expect(response[:data][:deleted]).to be(true)
      expect(response[:data][:provider_deleted]).to be(true)
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

    it "blocks the delete, keeps the row, and reports the refusal" do
      response = delete!

      expect(response[:success]).to be(false)
      expect(response[:error]).to be_present
      expect(::System::ProviderVolumeSnapshot.find_by(id: snapshot.id)).to be_present
      expect(adapter).not_to have_received(:delete_volume_snapshot)
    end
  end

  describe "authorization is not lost to the gate" do
    let(:user) { create(:user, account: account, permissions: []) }

    it "refuses an unauthorized caller and parks nothing" do
      response = delete!

      expect(response[:success]).to be(false)
      expect(response[:error]).to include("permission denied")
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end
  end

  describe "a target that cannot be resolved parks nothing" do
    it "refuses an unknown snapshot with the inline error, minting no approval" do
      response = delete!(SecureRandom.uuid)

      expect(response[:success]).to be(false)
      expect(response[:error]).to eq("Snapshot not found")
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
    end

    it "refuses another account's snapshot the same way" do
      other = create(:account)
      foreign = create(:system_provider_volume_snapshot,
                       account: other,
                       volume: create(:system_provider_volume, account: other, external_id: "vol-x"),
                       status: "completed", external_id: "snap-x")

      response = delete!(foreign.id)

      expect(response[:success]).to be(false)
      expect(response[:error]).to eq("Snapshot not found")
      expect(::Ai::DeferredOperation.where(account_id: account.id)).to be_empty
      expect(::System::ProviderVolumeSnapshot.find_by(id: foreign.id)).to be_present
    end
  end
end
