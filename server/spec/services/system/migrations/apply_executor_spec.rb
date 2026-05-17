# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Migrations::ApplyExecutor, type: :service do
  let(:account) { create(:account) }
  let(:node_module) { create(:system_node_module, account: account) }

  # `transferring` is the state the source-side controller leaves the
  # migration in just before invoking the destination's apply. Operation
  # defaults to "migrate" here so PK-collision conflict policies apply
  # — `duplicate` plans cannot legitimately PK-collide under LD #14 and
  # have their own dedicated context below.
  let(:migration) do
    create(:system_migration, account: account, status: "transferring",
                              operation: "migrate",
                              root_resource_kind: "module_service")
  end

  def make_step(**overrides)
    create(:system_migration_plan_step, **{
      migration: migration,
      resource_kind: "module_service",
      action: "create",
      conflict_policy: "fail"
    }.merge(overrides))
  end

  describe ".apply!" do
    context "with a single create step (no conflict)" do
      let(:new_id) { SecureRandom.uuid }
      let!(:step) do
        make_step(
          resource_id: new_id,
          payload: {
            "id" => new_id,
            "node_module_id" => node_module.id,
            # Source-account id in payload — should be rewritten to destination's
            "account_id" => SecureRandom.uuid,
            "name" => "test-service",
            "start_command" => "/usr/bin/true",
            "restart_policy" => "always",
            "health_method" => "GET",
            "health_interval_seconds" => 30,
            "health_timeout_seconds" => 5,
            "health_initial_delay_seconds" => 10,
            "env" => {},
            "metadata" => {}
          }
        )
      end

      it "creates the record at the destination and marks the step applied" do
        result = described_class.apply!(migration: migration)
        expect(result.ok?).to be true
        expect(result.applied_count).to eq(1)
        expect(::System::ModuleService.find_by(id: new_id)).to be_present
        expect(step.reload.applied?).to be true
      end

      it "rewrites account_id from the source's to the destination's account" do
        described_class.apply!(migration: migration)
        record = ::System::ModuleService.find_by(id: new_id)
        expect(record.account_id).to eq(account.id)
      end

      it "transitions the migration to completed" do
        described_class.apply!(migration: migration)
        expect(migration.reload.status).to eq("completed")
        expect(migration.completed_at).to be_present
      end

      it "appends apply_started + apply_completed events to audit_log" do
        described_class.apply!(migration: migration)
        events = migration.reload.audit_log.map { |e| e["event"] }
        expect(events).to include("apply_started", "apply_completed")
      end
    end

    context "when migration is in a non-transitionable state" do
      let(:migration) { create(:system_migration, account: account, status: "completed") }

      it "returns failure without modifying state" do
        result = described_class.apply!(migration: migration)
        expect(result.ok?).to be false
        expect(result.error).to match(/cannot apply/)
        expect(migration.reload.status).to eq("completed")
      end
    end

    context "with conflict_policy: skip_if_exists on a PK collision" do
      let!(:existing) { create(:system_module_service, account: account, node_module: node_module, name: "untouched") }
      let!(:step) do
        make_step(
          resource_id: existing.id,
          conflict_policy: "skip_if_exists",
          payload: existing.attributes.merge("name" => "would-overwrite")
        )
      end

      it "leaves the existing record untouched + records skip in step metadata" do
        described_class.apply!(migration: migration)
        expect(existing.reload.name).to eq("untouched")
        expect(step.reload.metadata["skipped"]).to match(/policy=skip_if_exists/)
      end

      it "completes the migration with skipped_count > 0" do
        result = described_class.apply!(migration: migration)
        expect(result.ok?).to be true
        expect(result.skipped_count).to eq(1)
        expect(result.applied_count).to eq(0)
      end
    end

    context "with conflict_policy: overwrite on a PK collision" do
      let!(:existing) do
        create(:system_module_service, account: account, node_module: node_module, name: "old-name")
      end
      let!(:step) do
        make_step(
          resource_id: existing.id,
          conflict_policy: "overwrite",
          payload: existing.attributes.merge("name" => "new-name")
        )
      end

      it "updates the existing record with payload attributes" do
        result = described_class.apply!(migration: migration)
        expect(result.ok?).to be true
        expect(result.applied_count).to eq(1)
        expect(existing.reload.name).to eq("new-name")
      end
    end

    context "with conflict_policy: fail on a PK collision" do
      let!(:existing) { create(:system_module_service, account: account, node_module: node_module) }
      let!(:successful_step) do
        # Step 0: a clean insert that WOULD succeed
        make_step(
          step_order: 0,
          resource_id: SecureRandom.uuid,
          payload: {
            "id" => SecureRandom.uuid, "node_module_id" => node_module.id,
            "account_id" => account.id, "name" => "fresh-service",
            "start_command" => "/usr/bin/true", "restart_policy" => "always",
            "health_method" => "GET", "health_interval_seconds" => 30,
            "health_timeout_seconds" => 5, "health_initial_delay_seconds" => 10,
            "env" => {}, "metadata" => {}
          }
        )
      end
      let!(:colliding_step) do
        # Step 1: the collision that should fail the whole txn
        make_step(
          step_order: 1,
          resource_id: existing.id,
          conflict_policy: "fail",
          payload: existing.attributes
        )
      end

      it "rolls back ALL steps (no partial-apply state) and marks migration failed" do
        expect {
          described_class.apply!(migration: migration)
        }.not_to change { ::System::ModuleService.count }
        expect(migration.reload.status).to eq("failed")
      end

      it "captures the policy=fail reason in error_message" do
        described_class.apply!(migration: migration)
        expect(migration.reload.error_message).to match(/policy=fail/)
      end
    end

    context "with action: link_local hitting an existing local record" do
      let!(:existing) { create(:system_module_service, account: account, node_module: node_module) }
      let!(:step) do
        make_step(
          resource_id: existing.id,
          action: "link_local",
          payload: {} # link_local doesn't need a payload
        )
      end

      it "verifies the record exists and marks the step applied" do
        result = described_class.apply!(migration: migration)
        expect(result.ok?).to be true
        expect(result.applied_count).to eq(1)
        expect(step.reload.applied?).to be true
      end
    end

    context "with action: link_local when the target is missing locally" do
      let!(:step) do
        make_step(
          resource_id: SecureRandom.uuid,  # nonexistent
          action: "link_local"
        )
      end

      it "fails the migration with link_local target missing error" do
        result = described_class.apply!(migration: migration)
        expect(result.ok?).to be false
        expect(result.error).to match(/link_local target missing/)
        expect(migration.reload.status).to eq("failed")
      end
    end

    context "with action: skip" do
      let!(:step) do
        make_step(action: "skip", payload: {})
      end

      it "marks the step as explicitly skipped + completes the migration" do
        result = described_class.apply!(migration: migration)
        expect(result.ok?).to be true
        expect(result.skipped_count).to eq(1)
        expect(step.reload.applied?).to be false
        expect(step.reload.metadata["skipped"]).to eq("explicit skip")
      end
    end

    context "LD #14 — duplicate-plan PK collision is treated as a composer bug" do
      let(:migration) do
        create(:system_migration, account: account, status: "transferring",
                                  operation: "duplicate",
                                  root_resource_kind: "module_service")
      end
      let!(:existing) { create(:system_module_service, account: account, node_module: node_module) }
      let!(:colliding_step) do
        # A duplicate plan emitting a preserved UUID is the composer
        # misbehaving — the executor refuses to fall through to
        # conflict policy even when a benign policy is supplied.
        make_step(
          resource_id: existing.id,
          conflict_policy: "skip_if_exists",
          payload: existing.attributes
        )
      end

      it "fails the migration with an LD #14 composer-bug error" do
        result = described_class.apply!(migration: migration)
        expect(result.ok?).to be false
        expect(result.error).to match(/duplicate plan step PK-collided/)
        expect(migration.reload.status).to eq("failed")
      end

      it "rolls back the transaction (no records created)" do
        expect {
          described_class.apply!(migration: migration)
        }.not_to change { ::System::ModuleService.count }
      end
    end

    context "with an unknown resource_kind" do
      let!(:step) do
        make_step(
          resource_kind: "this_kind_does_not_exist",
          payload: { "id" => SecureRandom.uuid }
        )
      end

      it "fails the migration with unknown-kind error" do
        result = described_class.apply!(migration: migration)
        expect(result.ok?).to be false
        expect(result.error).to match(/unknown resource_kind/)
        expect(migration.reload.status).to eq("failed")
      end
    end

    context "with a step that fails validation at save time" do
      let!(:step) do
        # Missing required `name` field → ModuleService validation fails
        make_step(
          resource_id: SecureRandom.uuid,
          payload: {
            "id" => SecureRandom.uuid, "node_module_id" => node_module.id,
            "account_id" => account.id, "name" => nil,
            "start_command" => "/usr/bin/true", "restart_policy" => "always"
          }
        )
      end

      it "fails the migration with the validation error message" do
        result = described_class.apply!(migration: migration)
        expect(result.ok?).to be false
        expect(result.error).to match(/save failed/i)
        expect(migration.reload.status).to eq("failed")
      end
    end
  end
end
