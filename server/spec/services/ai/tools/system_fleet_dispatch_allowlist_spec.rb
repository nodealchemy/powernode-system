# frozen_string_literal: true

require "rails_helper"

# NARROW-DISPATCH — system_dispatch_module_build_batch's explicit module
# allowlist: module_slugs + expand_dependents reach the planner, the batch
# records what was selected, what was withheld and who asked, and the gate's
# description tells an approver exactly what will build.
RSpec.describe Ai::Tools::SystemFleetTool, "dispatch module allowlist" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account, permissions: %w[system.admin]) }
  let(:tool)    { described_class.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  def plan_result(entries, withheld: [])
    ::System::ModuleBuildPlannerService::PlanResult.new(entries: entries, excluded: [], withheld_dependents: withheld)
  end

  def stub_orchestrator_dispatch
    allow(::System::NativeModuleBuildOrchestrator).to receive(:dispatch!).and_return(
      System::NativeModuleBuildOrchestrator::Result.new(
        ok?: true, dispatched: 1, queued: 0, succeeded: 0, retried: 0, failed: 0
      )
    )
  end

  before { auto_approve_policy! }

  it "passes the allowlist to the planner and records selection, withheld dependents and requester" do
    expect(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
      .with(base_sha: "b", head_sha: "h", force_all: false, source_repo: nil,
            module_slugs: [ "powernode-system-base" ], expand_dependents: false)
      .and_return(plan_result([ { module: "powernode-system-base", oci_ref: "hhhhhhh" } ],
                              withheld: %w[base-os redis]))
    stub_orchestrator_dispatch

    result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h",
                  module_slugs: [ "powernode-system-base" ], expand_dependents: false)

    expect(result[:success]).to be true
    expect(result[:data][:module_build_batch][:module_slugs]).to eq([ "powernode-system-base" ])
    expect(result[:data][:withheld_dependents]).to eq(%w[base-os redis])

    selection = System::ModuleBuildBatch.last.metadata["selection"]
    expect(selection).to include(
      "module_slugs" => [ "powernode-system-base" ],
      "expand_dependents" => false,
      "withheld_dependents" => %w[base-os redis],
      "withheld_dependents_count" => 2
    )
    expect(selection["requested_by"]).to eq("type" => "internal", "id" => nil)
  end

  it "records a user requester by id" do
    user_tool = described_class.new(account: account, user: user)
    allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
      .and_return(plan_result([ { module: "powernode-system-base", oci_ref: "hhhhhhh" } ]))
    stub_orchestrator_dispatch

    result = user_tool.execute(params: { action: "system_dispatch_module_build_batch", base_sha: "b", head_sha: "h",
                                         module_slugs: [ "powernode-system-base" ], expand_dependents: false })

    expect(result[:success]).to be true
    expect(System::ModuleBuildBatch.last.metadata.dig("selection", "requested_by"))
      .to eq("type" => "user", "id" => user.id)
  end

  it "keeps the default-mode planner call and batch metadata unchanged" do
    expect(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
      .with(base_sha: "b", head_sha: "h", force_all: false, source_repo: nil)
      .and_return(plan_result([ { module: "mod-a", oci_ref: "abc1234" } ]))
    stub_orchestrator_dispatch

    result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h")

    expect(result[:success]).to be true
    expect(result[:data]).not_to have_key(:withheld_dependents)
    expect(System::ModuleBuildBatch.last.metadata).not_to have_key("selection")
  end

  it "treats expand_dependents: true without module_slugs as default mode (no selection recorded)" do
    expect(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
      .with(base_sha: "b", head_sha: "h", force_all: false, source_repo: nil)
      .and_return(plan_result([ { module: "mod-a", oci_ref: "abc1234" } ]))
    stub_orchestrator_dispatch

    result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h", expand_dependents: true)

    expect(result[:success]).to be true
    expect(result[:data]).not_to have_key(:withheld_dependents)
    expect(System::ModuleBuildBatch.last.metadata).not_to have_key("selection")
  end

  it "still sends expand_dependents: false without module_slugs to the planner, which refuses it" do
    expect(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
      .with(hash_including(module_slugs: nil, expand_dependents: false))
      .and_call_original

    result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h", expand_dependents: false)

    expect(result[:success]).to be false
    expect(result[:error]).to include("expand_dependents: false needs an explicit module_slugs allowlist")
  end

  it "surfaces a planner allowlist refusal as an error_result and creates no batch" do
    allow(::System::ModuleBuildPlannerService).to receive(:plan_with_diagnostics)
      .and_raise(::System::ModuleBuildPlannerService::PlanningError, "module_slugs names module(s) not changed by x..y: redis")

    expect do
      @result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h",
                     module_slugs: [ "redis" ], expand_dependents: false)
    end.not_to change(System::ModuleBuildBatch, :count)

    expect(@result[:success]).to be false
    expect(@result[:error]).to include("not changed by")
  end

  it "rejects a non-array module_slugs" do
    result = call("system_dispatch_module_build_batch", base_sha: "b", head_sha: "h",
                  module_slugs: "powernode-system-base", expand_dependents: false)

    expect(result[:success]).to be false
    expect(result[:error]).to include("module_slugs must be an array")
  end

  describe "gate context" do
    it "names the allowlist and the withheld expansion so an approver sees what will build" do
      ctx = tool.send(:dispatch_module_build_batch_gate_context,
                      { base_sha: "b" * 40, head_sha: "h" * 40,
                        module_slugs: [ "powernode-system-base" ], expand_dependents: false })

      expect(ctx[:description]).to include("allowlist [powernode-system-base]")
      expect(ctx[:description]).to include("no reverse-dependency expansion")
    end

    it "is unchanged in default mode" do
      ctx = tool.send(:dispatch_module_build_batch_gate_context, { base_sha: "b" * 40, head_sha: "h" * 40 })

      expect(ctx[:description]).not_to include("allowlist")
    end
  end

  it "documents the allowlist and the base-os contract caveat in the verb description" do
    definition = described_class.action_definitions["system_dispatch_module_build_batch"]

    expect(definition[:parameters].keys).to include(:module_slugs, :expand_dependents)
    expect(definition[:description]).to include("module_slugs")
    expect(definition[:description]).to match(/service contract/i)
  end
end
