# frozen_string_literal: true

require "rails_helper"

# IMP-469117835ccb — system_dispatch_module_build_batch surfaces the planner's
# withheld source regressions the way it surfaces withheld dependents: in the
# result when there are any, on the batch always, and never when there are
# none (a clean dispatch's payload is byte-identical to before).
RSpec.describe Ai::Tools::SystemFleetTool, "dispatch source-regression guard" do
  let(:account) { create(:account) }
  let(:tool)    { described_class.new(account: account, internal: true) }

  let(:withheld) do
    [ { module: "powernode-extension-system", reason: "source_regression",
        detail: "core pins extensions/system 4 commit(s) behind ...",
        pinned_sha: "c" * 40, published_sha: "d" * 40, published_version_number: 132 } ]
  end

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  def plan_result(entries, withheld: [])
    ::System::ModuleBuildPlannerService::PlanResult.new(entries: entries, excluded: [], withheld_dependents: [],
                                                       withheld_regressions: withheld)
  end

  def stub_orchestrator_dispatch
    allow(::System::NativeModuleBuildOrchestrator).to receive(:dispatch!).and_return(
      System::NativeModuleBuildOrchestrator::Result.new(
        ok?: true, dispatched: 1, queued: 0, succeeded: 0, retried: 0, failed: 0
      )
    )
  end

  before { auto_approve_policy! }

  it "reports a withheld regression in the result and records it on the batch" do
    allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
      .and_return(plan_result([ { module: "powernode-hub-backend", oci_ref: "hhhhhhh" } ], withheld: withheld))
    stub_orchestrator_dispatch

    result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h",
                  source_repo: "powernode/powernode-platform")

    expect(result[:success]).to be true
    expect(result[:data][:module_build_batch][:module_slugs]).to eq([ "powernode-hub-backend" ])
    expect(result[:data][:withheld_regressions]).to eq(withheld)

    batch = System::ModuleBuildBatch.last
    expect(batch.metadata["withheld_regressions"]).to eq([
      { "module" => "powernode-extension-system", "reason" => "source_regression",
        "detail" => "core pins extensions/system 4 commit(s) behind ...",
        "pinned_sha" => "c" * 40, "published_sha" => "d" * 40, "published_version_number" => 132 }
    ])
    expect(batch.metadata["withheld_regressions_count"]).to eq(1)

    detail = call("system_get_module_build_batch", batch_id: batch.id)
    expect(detail[:success]).to be true
    expect(detail[:data][:module_build_batch][:withheld_regressions_count]).to eq(1)
    expect(detail[:data][:module_build_batch][:withheld_regressions].first).to include("reason" => "source_regression")
  end

  it "leaves a clean dispatch's payload and batch metadata unchanged" do
    allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
      .and_return(plan_result([ { module: "mod-a", oci_ref: "abc1234" } ]))
    stub_orchestrator_dispatch

    result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h")

    expect(result[:success]).to be true
    expect(result[:data]).not_to have_key(:withheld_regressions)
    expect(System::ModuleBuildBatch.last.metadata).not_to have_key("withheld_regressions")
  end

  it "surfaces the planner's every-module-withheld refusal as an error and creates no batch" do
    allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
      .and_raise(::System::ModuleBuildPlannerService::PlanningError,
                 "planned 0 modules — every planned module was withheld: powernode-extension-system withheld (source_regression): ...")

    expect do
      @result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h",
                     source_repo: "powernode/powernode-platform")
    end.not_to change(System::ModuleBuildBatch, :count)

    expect(@result[:success]).to be false
    expect(@result[:error]).to include("powernode-extension-system withheld (source_regression)")
  end

  it "documents the guard and the remedy in the verb description" do
    definition = described_class.action_definitions["system_dispatch_module_build_batch"]

    expect(definition[:description]).to include("withheld_regressions")
    expect(definition[:description]).to include("source_ancestry_undetermined")
    expect(definition[:description]).to match(/extension-range build/)
  end
end
