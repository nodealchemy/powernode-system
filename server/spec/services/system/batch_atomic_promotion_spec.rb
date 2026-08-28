# frozen_string_literal: true

require "rails_helper"

# Batch-atomic promotion — 2026-08-28 outage remediation.
#
# Publishing auto-promotes per module the moment each build finishes, and build
# durations inside one batch differ by an order of magnitude (measured that day:
# extension ~2 min, hub-backend ~20 min). ops-hub ran the new extension against
# the old core for ~19 minutes, could not boot, and crash-looped with MCP down
# alongside it. These examples pin the holdback that closes that window.
RSpec.describe "batch-atomic promotion" do
  let(:account) { create(:account) }

  def a_module(name)
    create(:system_node_module, account: account, name: name)
  end

  def a_version(node_module, number)
    System::NodeModuleVersion.create!(
      node_module: node_module, version_number: number,
      artifacts: { "erofs" => { "size_bytes" => 4_000_000 } }
    )
  end

  def batch_for(mods, status: "dispatched")
    plan = mods.map { |m| { module: m.name, oci_ref: "native-abc1234" } }
    b = System::ModuleBuildBatch.create_for(
      account: account, plan: plan, trigger: "manual",
      base_sha: "base0000", head_sha: "head0000"
    )
    b.update_columns(status: status)
    b.reload
  end

  describe "System::ModulePublicationProcessor.deferring_batch_for" do
    let(:core) { a_module("powernode-hub-backend") }
    let(:ext)  { a_module("powernode-extension-system") }

    it "returns the in-flight batch when the module has a sibling still building" do
      batch = batch_for([ core, ext ])

      expect(described_class_processor.deferring_batch_for(core)).to eq(batch)
    end

    # The common case must not change: with no sibling there is nothing to skew
    # against, so a single-module batch promotes immediately as it always has.
    it "returns nil for a SINGLE-module batch" do
      batch_for([ ext ])

      expect(described_class_processor.deferring_batch_for(ext)).to be_nil
    end

    it "returns nil once the batch has finished" do
      batch_for([ core, ext ], status: "complete")

      expect(described_class_processor.deferring_batch_for(core)).to be_nil
    end

    it "does not see another account's batch" do
      other = create(:account)
      plan = [ { module: core.name, oci_ref: "x" }, { module: ext.name, oci_ref: "x" } ]
      System::ModuleBuildBatch.create_for(account: other, plan: plan, trigger: "manual",
                                          base_sha: "b", head_sha: "h").update_columns(status: "dispatched")

      expect(described_class_processor.deferring_batch_for(core)).to be_nil
    end

    it "does not claim a module the batch never planned" do
      unrelated = a_module("redis")
      batch_for([ core, ext ])

      expect(described_class_processor.deferring_batch_for(unrelated)).to be_nil
    end

    def described_class_processor = ::System::ModulePublicationProcessor
  end

  describe "release on completion" do
    let(:core) { a_module("powernode-hub-backend") }
    let(:ext)  { a_module("powernode-extension-system") }

    it "promotes every deferred member together" do
      batch = batch_for([ core, ext ])
      v_core = a_version(core, 85)
      v_ext  = a_version(ext, 74)
      [ v_core, v_ext ].each { |v| v.update_columns(deferred_promotion_batch_id: batch.id) }

      System::NativeModuleBuildOrchestrator.new(batch: batch).send(:release_deferred_promotions!)

      expect(core.reload.current_version_id).to eq(v_core.id)
      expect(ext.reload.current_version_id).to eq(v_ext.id)
      expect(v_core.reload.deferred_promotion_batch_id).to be_nil
    end

    # THE LOAD-BEARING GUARANTEE. Promoting the survivors of a partial batch
    # recreates exactly the skew this exists to prevent — one module of two
    # going live alone is the shape of the outage.
    it "promotes NOTHING when the batch only partially succeeded" do
      batch = batch_for([ core, ext ])
      v_core = a_version(core, 85)
      v_ext  = a_version(ext, 74)
      [ v_core, v_ext ].each { |v| v.update_columns(deferred_promotion_batch_id: batch.id) }

      System::NativeModuleBuildOrchestrator.new(batch: batch).send(:hold_deferred_promotions!, "batch completed partially")

      expect(core.reload.current_version_id).to be_nil
      expect(ext.reload.current_version_id).to be_nil
      # Still held, so an operator can promote them deliberately.
      expect(v_core.reload.deferred_promotion_batch_id).to eq(batch.id)
    end

    it "is a no-op when the batch deferred nothing" do
      batch = batch_for([ core, ext ])

      expect {
        System::NativeModuleBuildOrchestrator.new(batch: batch).send(:release_deferred_promotions!)
      }.not_to raise_error
    end
  end
end
