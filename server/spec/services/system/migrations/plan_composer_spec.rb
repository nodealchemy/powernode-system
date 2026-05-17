# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Migrations::PlanComposer, type: :service do
  let(:account) { create(:account) }

  before do
    # Install a controlled inventory mapping "user" → declared kind.
    registry = System::Federation::InventoryRegistry.new
    registry.register_kind(
      extension: "test", kind: "user", dependencies: [],
      duplicable: true, migratable: true,
      metadata: {}
    )
    registry.register_kind(
      extension: "test", kind: "account", dependencies: [ "user" ],
      duplicable: true, migratable: false,
      metadata: {}
    )
    System::Federation::InventoryRegistry.install_test_double(registry)
  end

  after { System::Federation::InventoryRegistry.install_test_double(nil) }

  describe ".compose!" do
    it "fails when root_kind is not declared in the inventory" do
      result = described_class.compose!(
        account: account, operation: "duplicate",
        root_kind: "unknown_kind", root_id: SecureRandom.uuid
      )
      expect(result.ok?).to be false
      expect(result.error).to include("not in federation_inventory.yaml")
    end

    it "fails when root record cannot be found" do
      result = described_class.compose!(
        account: account, operation: "duplicate",
        root_kind: "account", root_id: SecureRandom.uuid
      )
      expect(result.ok?).to be false
      expect(result.error).to include("root record not found")
    end

    it "fails for an invalid operation" do
      result = described_class.compose!(
        account: account, operation: "bogus",
        root_kind: "account", root_id: account.id
      )
      expect(result.ok?).to be false
      expect(result.error).to include("operation must be")
    end

    it "creates a Migration row with status='planned' for a valid root" do
      result = described_class.compose!(
        account: account, operation: "duplicate",
        root_kind: "account", root_id: account.id
      )
      expect(result.ok?).to be true
      m = result.migration
      expect(m).to be_persisted
      expect(m.status).to eq("planned")
      expect(m.root_resource_id).to eq(account.id)
      expect(m.operation).to eq("duplicate")
      expect(m.dry_run).to be true
    end

    it "produces at least one plan step (the root record)" do
      result = described_class.compose!(
        account: account, operation: "duplicate",
        root_kind: "account", root_id: account.id
      )
      expect(result.step_count).to be >= 1
      root_step = result.migration.plan_steps.find_by(step_order: 0)
      expect(root_step.resource_kind).to eq("account")
      # LD #14: duplicate operations assign a FRESH UUIDv7 at the destination.
      # Source UUID lives in payload.metadata.duplicated_from for lineage.
      expect(root_step.resource_id).to be_present
      expect(root_step.resource_id).not_to eq(account.id)
      expect(root_step.payload["id"]).to eq(root_step.resource_id)
      expect(root_step.payload.dig("metadata", "duplicated_from", "uuid")).to eq(account.id)
      expect(root_step.action).to eq("create")
    end

    it "walks declared dependencies via AR has_many reflection" do
      _user = create(:user, account: account)
      result = described_class.compose!(
        account: account, operation: "duplicate",
        root_kind: "account", root_id: account.id
      )
      kinds = result.migration.plan_steps.pluck(:resource_kind)
      expect(kinds).to include("account")
      expect(kinds).to include("user")  # walked via account.has_many :users
    end

    it "deduplicates: doesn't revisit a (kind, id) pair" do
      user = create(:user, account: account)
      result = described_class.compose!(
        account: account, operation: "duplicate",
        root_kind: "account", root_id: account.id
      )
      # LD #14: dedup is by source-record identity, not resource_id (which is
      # fresh per step). Match via the lineage metadata.
      user_steps = result.migration.plan_steps.where(resource_kind: "user")
      matching = user_steps.select { |s| s.payload.dig("metadata", "duplicated_from", "uuid") == user.id }
      expect(matching.length).to eq(1)
    end

    it "populates plan_summary with totals + visited kinds" do
      create(:user, account: account)
      result = described_class.compose!(
        account: account, operation: "duplicate",
        root_kind: "account", root_id: account.id
      )
      summary = result.migration.plan_summary
      expect(summary["total_steps"]).to be >= 2
      expect(summary["kinds_visited"]).to include("account", "user")
      expect(summary["root_kind"]).to eq("account")
    end

    it "appends a plan_composed entry to audit_log" do
      result = described_class.compose!(
        account: account, operation: "duplicate",
        root_kind: "account", root_id: account.id
      )
      audit = result.migration.audit_log
      expect(audit.last["event"]).to eq("plan_composed")
      expect(audit.last["at"]).to be_present
    end

    it "rejects roots not in the caller's account" do
      other_account = create(:account)
      result = described_class.compose!(
        account: account, operation: "duplicate",
        root_kind: "account", root_id: other_account.id
      )
      expect(result.ok?).to be false
      expect(result.error).to include("does not belong to account")
    end

    context "LD #14 — UUID semantics per operation" do
      it "for migrate operations, preserves the source UUID on each step" do
        user = create(:user, account: account)
        result = described_class.compose!(
          account: account, operation: "migrate",
          root_kind: "user", root_id: user.id
        )
        expect(result.ok?).to be true
        root_step = result.migration.plan_steps.find_by(step_order: 0)
        # Migrate transfers ownership — UUID flows with the record.
        expect(root_step.resource_id).to eq(user.id)
        expect(root_step.payload["id"]).to eq(user.id)
        # No duplicated_from lineage for migrate (it's the same record, new home).
        expect(root_step.payload.dig("metadata", "duplicated_from")).to be_nil
      end

      it "for duplicate operations, every step gets a fresh UUID + lineage" do
        create(:user, account: account)
        result = described_class.compose!(
          account: account, operation: "duplicate",
          root_kind: "account", root_id: account.id
        )
        # Every step has resource_id != its source's id; every step's payload
        # carries the duplicated_from lineage pointing back to the source.
        result.migration.plan_steps.each do |step|
          source_uuid = step.payload.dig("metadata", "duplicated_from", "uuid")
          expect(source_uuid).to be_present, "step #{step.step_order} (#{step.resource_kind}) missing lineage"
          expect(step.resource_id).not_to eq(source_uuid)
          expect(step.payload["id"]).to eq(step.resource_id)
        end
      end
    end
  end
end
