# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc10 — System::ModuleBuildTriggerService. The single
# place that turns "a push moved base_sha..head_sha" into mode-appropriate
# behavior: full no-op in "gitea" mode, a shadow (native-tagged, no-promote)
# batch in "dual" mode, an authoritative batch in "native" mode.
RSpec.describe System::ModuleBuildTriggerService do
  let!(:account) { create(:account, name: "Powernode") }

  def stub_plan(modules:, source_repo: nil)
    allow(::System::ModuleBuildPlannerService).to receive(:plan)
      .with(base_sha: "base0000", head_sha: "headsha1234567", force_all: false, source_repo: source_repo)
      .and_return(modules.map { |m| { module: m, oci_ref: "headsha1" } })
  end

  def stub_dispatch!(dispatched: 1)
    allow(::System::NativeModuleBuildOrchestrator).to receive(:dispatch!).and_return(
      System::NativeModuleBuildOrchestrator::Result.new(
        ok?: true, dispatched: dispatched, queued: 0, succeeded: 0, retried: 0, failed: 0
      )
    )
  end

  describe "gitea mode (default) — full no-op" do
    it "never calls the planner or the orchestrator" do
      expect(::System::ModuleBuildPlannerService).not_to receive(:plan)
      expect(::System::NativeModuleBuildOrchestrator).not_to receive(:dispatch!)

      result = described_class.trigger!(base_sha: "base0000", head_sha: "headsha1234567")

      expect(result.ok?).to be true
      expect(result.mode).to eq("gitea")
      expect(result.dispatched).to be false
      expect(result.batch).to be_nil
      expect(System::ModuleBuildBatch.count).to eq(0)
    end
  end

  describe "dual mode — shadow batch" do
    before { SiteSetting.set("system.module_builds.mode", "dual") }

    it "creates a shadow batch, prefixes tags with native-, and dispatches via the orchestrator" do
      stub_plan(modules: %w[mod-a mod-b])
      stub_dispatch!(dispatched: 2)

      result = described_class.trigger!(base_sha: "base0000", head_sha: "headsha1234567")

      expect(result.ok?).to be true
      expect(result.mode).to eq("dual")
      expect(result.dispatched).to be true
      expect(result.shadow).to be true

      batch = result.batch
      expect(batch).to be_persisted
      expect(batch.shadow).to be true
      expect(batch.trigger).to eq("push")
      expect(batch.metadata["plan"]).to contain_exactly(
        { "module" => "mod-a", "oci_ref" => "native-headsha1" },
        { "module" => "mod-b", "oci_ref" => "native-headsha1" }
      )
      expect(::System::NativeModuleBuildOrchestrator).to have_received(:dispatch!).with(batch: batch)
    end

    it "never mints a plain (un-prefixed) oci_ref for a shadow batch" do
      stub_plan(modules: %w[mod-a])
      stub_dispatch!

      result = described_class.trigger!(base_sha: "base0000", head_sha: "headsha1234567")

      tag = result.batch.metadata["plan"].first["oci_ref"]
      expect(tag).to start_with("native-")
    end
  end

  describe "native mode — authoritative batch" do
    before { SiteSetting.set("system.module_builds.mode", "native") }

    it "creates a non-shadow batch with plain tags and dispatches via the orchestrator" do
      stub_plan(modules: %w[mod-a])
      stub_dispatch!

      result = described_class.trigger!(base_sha: "base0000", head_sha: "headsha1234567")

      expect(result.ok?).to be true
      expect(result.mode).to eq("native")
      expect(result.dispatched).to be true
      expect(result.shadow).to be false

      batch = result.batch
      expect(batch.shadow).to be false
      expect(batch.trigger).to eq("push")
      expect(batch.metadata["plan"]).to contain_exactly({ "module" => "mod-a", "oci_ref" => "headsha1" })
    end
  end

  describe "error handling" do
    it "surfaces a planner PlanningError as a failure result rather than raising, in dual mode" do
      SiteSetting.set("system.module_builds.mode", "dual")
      allow(::System::ModuleBuildPlannerService).to receive(:plan)
        .and_raise(::System::ModuleBuildPlannerService::PlanningError, "no active Gitea credential resolvable")

      result = described_class.trigger!(base_sha: "base0000", head_sha: "headsha1234567")

      expect(result.ok?).to be false
      expect(result.error).to include("no active Gitea credential resolvable")
      expect(System::ModuleBuildBatch.count).to eq(0)
    end

    it "returns a failure result when no account is resolvable" do
      allow(::Account).to receive(:find_by).and_return(nil)
      allow(::Account).to receive(:first).and_return(nil)

      result = described_class.trigger!(base_sha: "base0000", head_sha: "headsha1234567")

      expect(result.ok?).to be false
      expect(result.error).to include("no account resolvable")
    end
  end

  describe "force_all passthrough" do
    it "forwards force_all: true to the planner" do
      SiteSetting.set("system.module_builds.mode", "native")
      allow(::System::ModuleBuildPlannerService).to receive(:plan)
        .with(base_sha: "base0000", head_sha: "headsha1234567", force_all: true, source_repo: nil)
        .and_return([])
      stub_dispatch!(dispatched: 0)

      described_class.trigger!(base_sha: "base0000", head_sha: "headsha1234567", force_all: true)

      expect(::System::ModuleBuildPlannerService).to have_received(:plan)
        .with(base_sha: "base0000", head_sha: "headsha1234567", force_all: true, source_repo: nil)
    end
  end

  describe "source_repo passthrough (imp 019f71e2)" do
    it "threads source_repo to the planner and records it on the batch" do
      SiteSetting.set("system.module_builds.mode", "native")
      stub_plan(modules: %w[mod-a], source_repo: "powernode/powernode-platform")
      stub_dispatch!

      result = described_class.trigger!(
        base_sha: "base0000", head_sha: "headsha1234567", source_repo: "powernode/powernode-platform"
      )

      expect(::System::ModuleBuildPlannerService).to have_received(:plan)
        .with(base_sha: "base0000", head_sha: "headsha1234567", force_all: false, source_repo: "powernode/powernode-platform")
      expect(result.batch.metadata["source_repo"]).to eq("powernode/powernode-platform")
    end
  end
end
