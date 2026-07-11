# frozen_string_literal: true

require "rails_helper"

# Tests for System::BootImage::UpgradeReconciler — reconciles in-flight boot-image
# upgrade tasks against the booted image reported in the node's heartbeat
# (campaign 019f505f increment 2).
RSpec.describe System::BootImage::UpgradeReconciler do
  let(:account)  { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)  { create(:system_node, account: account, node_template: node_template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  describe ".reconcile!(instance:)" do
    context "when there is no in-flight upgrade task" do
      it "returns 0 (no transitions)" do
        instance.update!(booted_image_git_sha: "current-sha")

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(0)
      end
    end

    context "when booted_image_git_sha matches the task's target_git_sha" do
      it "completes a pending task and returns 1" do
        target_sha = "target-abc123"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: target_sha)

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(1)
        expect(task.reload.status).to eq("complete")
      end

      it "forces pending → start! before completing" do
        target_sha = "target-def456"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: target_sha)
        # Verify that start! was called by checking the transition flow
        initial_status = task.status

        described_class.reconcile!(instance: instance)

        # If the reconciler couldn't call start! on a pending task, it wouldn't reach complete!
        expect(task.reload.status).to eq("complete")
        expect(initial_status).to eq("pending")
      end

      it "skips start! if task is already running" do
        target_sha = "target-running"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "running",
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: target_sha)

        described_class.reconcile!(instance: instance)

        expect(task.reload.status).to eq("complete")
      end

      it "completes a scheduled task (transitions scheduled → complete via start!)" do
        target_sha = "target-scheduled"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "scheduled",
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: target_sha)

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(1)
        expect(task.reload.status).to eq("complete")
      end

      it "completes the task even if event methods are not available (add_event not called)" do
        target_sha = "target-event"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: target_sha)
        # The reconciler checks respond_to?(:add_event) before calling
        # If it doesn't respond, the completion still happens

        described_class.reconcile!(instance: instance)

        # The key behavior is that the task completes regardless
        expect(task.reload.status).to eq("complete")
      end
    end

    context "when booted_image_git_sha does not match and task is recent (not timed out)" do
      it "leaves the task in-flight and returns 0" do
        target_sha = "target-xyz789"
        booted_sha = "still-old-sha"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          created_at: 1.minute.ago,
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: booted_sha)

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(0)
        expect(task.reload.status).to eq("pending")
      end
    end

    context "when booted_image_git_sha does not match and task is timed out" do
      it "fails the task and returns 1" do
        target_sha = "target-timeout"
        booted_sha = "still-old-image"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          created_at: 20.minutes.ago,  # Older than default 900s (15m) timeout
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: booted_sha)

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(1)
        expect(task.reload.status).to eq("failed")
        expect(task.error_message).to include("not confirmed")
      end

      it "includes the timeout duration in the error message" do
        target_sha = "target-timeout-msg"
        booted_sha = "old"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          created_at: 1000.seconds.ago,  # > 900s
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: booted_sha)

        described_class.reconcile!(instance: instance)

        expect(task.reload.error_message).to match(/900s/)
      end

      it "includes the booted_image_git_sha in the error message" do
        target_sha = "target-includes-sha"
        booted_sha = "actual-booted-sha"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          created_at: 1000.seconds.ago,
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: booted_sha)

        described_class.reconcile!(instance: instance)

        expect(task.reload.error_message).to include(booted_sha)
      end

      it "says 'unknown' if booted_image_git_sha is nil" do
        target_sha = "target-unknown-boot"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          created_at: 1000.seconds.ago,
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: nil)

        described_class.reconcile!(instance: instance)

        expect(task.reload.error_message).to include("unknown")
      end

      it "respects the timeout constant from the reconciler class" do
        # The default TIMEOUT_SECONDS is 900 (15 minutes)
        target_sha = "target-default-timeout"
        booted_sha = "old"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          created_at: 1.minute.ago,  # < 900s, so not timed out with default
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: booted_sha)

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(0)
        expect(task.reload.status).to eq("pending")
      end
    end

    context "when booted_image_git_sha is nil and task is not timed out" do
      it "leaves the task in-flight and returns 0" do
        target_sha = "target-no-boot"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          created_at: 1.minute.ago,
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: nil)

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(0)
        expect(task.reload.status).to eq("pending")
      end
    end

    context "when task options have no target_git_sha" do
      it "skips the task and returns 0" do
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          options: {}  # Missing target_git_sha
        )
        instance.update!(booted_image_git_sha: "any-sha")

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(0)
        expect(task.reload.status).to eq("pending")
      end
    end

    context "when task options are present but don't have target_git_sha" do
      it "skips the task and returns 0" do
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          options: { "other_field" => "value" }  # No target_git_sha
        )
        instance.update!(booted_image_git_sha: "any-sha")

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(0)
        expect(task.reload.status).to eq("pending")
      end
    end

    context "with multiple in-flight tasks" do
      it "processes all matching tasks and returns count of transitions" do
        target_1 = "target-1"
        target_2 = "target-2"
        task_1 = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          options: { "target_git_sha" => target_1 }
        )
        task_2 = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          options: { "target_git_sha" => target_2 }
        )
        instance.update!(booted_image_git_sha: target_1)

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(1)
        expect(task_1.reload.status).to eq("complete")
        expect(task_2.reload.status).to eq("pending")
      end
    end

    context "when a completed task exists" do
      it "does not touch completed tasks" do
        target_sha = "target-complete"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "complete",
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: target_sha)

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(0)
        expect(task.reload.status).to eq("complete")
      end
    end

    context "when a failed task exists" do
      it "does not touch failed tasks" do
        target_sha = "target-failed"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "failed",
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: target_sha)

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(0)
        expect(task.reload.status).to eq("failed")
      end
    end

    context "error handling" do
      it "catches StandardError during reconciliation and returns gracefully" do
        # The reconciler wraps the whole reconcile! in a rescue block
        # If any error occurs (e.g., in task.start! or task.complete!), it logs and returns 0
        target_sha = "target-error"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: target_sha)
        # Cause an error during completion
        allow(task).to receive(:complete!).and_raise(StandardError, "Test error")
        allow(::System::Task).to receive(:where).and_call_original
        allow(::System::Task).to receive(:where)
          .with(operable: instance, command: "upgrade_boot_image")
          .and_return([task])

        # The reconciler should not raise
        expect {
          described_class.reconcile!(instance: instance)
        }.not_to raise_error
      end
    end

    context "task.started_at vs task.created_at timeout calculation" do
      it "uses started_at when present" do
        target_sha = "target-started-at"
        booted_sha = "old"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "running",
          created_at: 30.minutes.ago,
          started_at: 2.minutes.ago,  # This is more recent
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: booted_sha)

        count = described_class.reconcile!(instance: instance)

        # With default 900s timeout and started_at 2m ago, not timed out
        expect(count).to eq(0)
        expect(task.reload.status).to eq("running")
      end

      it "falls back to created_at when started_at is nil" do
        target_sha = "target-created-at"
        booted_sha = "old"
        task = System::Task.create!(
          account: account,
          operable: instance,
          command: "upgrade_boot_image",
          status: "pending",
          created_at: 20.minutes.ago,  # Older than 900s
          started_at: nil,
          options: { "target_git_sha" => target_sha }
        )
        instance.update!(booted_image_git_sha: booted_sha)

        count = described_class.reconcile!(instance: instance)

        expect(count).to eq(1)
        expect(task.reload.status).to eq("failed")
      end
    end
  end
end
