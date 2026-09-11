# frozen_string_literal: true

require "rails_helper"

# SystemFleetTool#call turns a refused state-machine transition into an error
# result. It used to name `System::NodeModuleVersion::InvalidTransition`, a
# constant that has not existed since the version ladder was deleted. A rescue
# resolves its class only when an exception is raised, so the clause raised
# NameError at exactly the moment it should have handled a failure, and
# spec/services/ai/tools/tool_constant_resolution_spec.rb reported it.
#
# Every state machine the tool drives is AASM, so the class the clause must
# name is AASM::InvalidTransition. The example below fires a REAL refused
# transition from a real model through a real verb: the build-batch cancel,
# with the orchestrator's guard stubbed away so the model's own event refuses.
RSpec.describe Ai::Tools::SystemFleetTool do
  let(:account) { create(:account) }
  let(:tool)    { described_class.new(account: account, internal: true) }
  let(:batch) do
    System::ModuleBuildBatch.create!(account: account, status: "complete", trigger: "push",
                                     base_sha: "a" * 40, head_sha: "b" * 40)
  end

  def cancel_batch
    tool.execute(params: { action: "system_cancel_module_build_batch", batch_id: batch.id })
  end

  it "answers a refused AASM transition with an error result, not a NameError" do
    allow(System::NativeModuleBuildOrchestrator).to receive(:cancel!) { |batch:, **| batch.cancel! }

    result = cancel_batch

    expect(result[:success]).to be false
    expect(result[:error]).to match(/cancel/).and match(/complete/)
    expect(batch.reload.status).to eq("complete")
  end

  it "still lets an unrelated failure escape, so the clause stays narrow" do
    allow(System::NativeModuleBuildOrchestrator).to receive(:cancel!).and_raise(RuntimeError, "builder exploded")

    expect { cancel_batch }.to raise_error(RuntimeError, "builder exploded")
  end
end
