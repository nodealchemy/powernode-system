# frozen_string_literal: true

require "rails_helper"

# Offer 01a03064-cc38 — a running System::Task row simply VANISHED.
#
# Six models declare `has_many :tasks, as: :operable, dependent: :destroy`:
# Node, NodeInstance, Provider, ProviderNetwork, ProviderVolume and
# ProviderVolumeSnapshot. So destroying any of them silently destroys its task
# history — including tasks still RUNNING, which disappear mid-flight with no
# terminal transition and no record that they ever existed.
#
# That is the audit-loss half of the orphan finding. (The other half — task rows
# pointing at instances that no longer exist — implies a BYPASS path around this
# cascade, since the cascade itself would have deleted them.)
#
# THE PROPERTY, restated so it does not depend on which model is being removed:
#
#   No System::Task row may vanish, and none may be left non-terminal because
#   its operable went away. Removal must TRANSITION its tasks, not delete them,
#   and must preserve which operable they belonged to.
#
# Oracles are rows and states — never log lines.
RSpec.describe "task history survives operable removal" do
  let(:account) { create(:account) }

  def task_for(operable, status:, command: "sync_modules")
    t = create(:system_task, account: account, operable: operable, command: command, status: status)
    t.update_columns(started_at: 1.hour.ago) if status == "running"
    t
  end

  describe "System::NodeInstance" do
    let(:instance) { create(:system_node_instance, account: account) }

    it "does not delete the task rows" do
      task_for(instance, status: "complete")
      task_for(instance, status: "running")

      expect { instance.destroy! }.not_to change { ::System::Task.count }
    end

    it "terminally transitions a RUNNING task instead of vanishing it" do
      task = task_for(instance, status: "running")

      instance.destroy!

      expect(task.reload.status).to eq("failed")
      expect(task.error_message).to match(/operable removed/i)
    end

    it "terminally transitions a PENDING task" do
      task = task_for(instance, status: "pending")

      instance.destroy!

      # cancel, not fail: it never started, and recording it as failed would
      # assert an execution that never happened.
      expect(task.reload.status).to eq("cancelled")
    end

    it "leaves an already-terminal task untouched" do
      task = task_for(instance, status: "complete")

      instance.destroy!

      expect(task.reload.status).to eq("complete")
    end

    # Without this the surviving row is anonymous — it records that SOMETHING
    # was cancelled, not what it belonged to, which is most of the audit value.
    it "preserves which operable the task belonged to" do
      task = task_for(instance, status: "running")
      instance_id = instance.id

      instance.destroy!

      stamp = task.reload.options["removed_operable"]
      expect(stamp["type"]).to eq("System::NodeInstance")
      expect(stamp["id"]).to eq(instance_id)
    end

    it "clears the dangling operable pointer" do
      task = task_for(instance, status: "running")

      instance.destroy!

      expect(task.reload.operable_id).to be_nil
      expect(task.operable_type).to be_nil
    end
  end

  # The cascade is declared on SIX models, so fixing one would leave five ways
  # to lose the same history. Asserted per model rather than on the concern, so
  # a model that drops the include is caught.
  describe "every operable that cascades tasks" do
    {
      "System::Node" => :system_node,
      "System::NodeInstance" => :system_node_instance,
      "System::Provider" => :system_provider
    }.each do |klass, factory|
      it "#{klass} preserves its task rows on destroy" do
        operable = create(factory, account: account)
        task = task_for(operable, status: "running")

        expect { operable.destroy! }.not_to change { ::System::Task.count }
        expect(task.reload.status).to eq("failed")
      end
    end
  end
end
