# frozen_string_literal: true

require "rails_helper"

# Audit F5-04 — companion coverage for the build half of the module
# deployment pipeline (the commit half is module_commit_service_spec.rb;
# AgentModuleCommitService is pinned by the node_api commit request spec).
RSpec.describe System::ModuleBuildService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, name: "buildable-mod", enabled: true)
  end

  def build!(options = {})
    described_class.build(node_module: node_module, options: options)
  end

  it "refuses a disabled module" do
    node_module.update!(enabled: false)

    result = build!

    expect(result.success?).to be false
    expect(result.error).to match(/disabled/i)
  end

  it "raises on a non-module argument (caller bug, not a Result)" do
    expect {
      described_class.build(node_module: "not-a-module")
    }.to raise_error(ArgumentError)
  end

  it "builds through all stages and stamps build info on the module" do
    result = build!

    expect(result.success?).to be true
    expect(result.data[:build_id]).to be_present
    expect(result.data[:artifacts]).to be_an(Array)
    expect(result.data[:duration]).to be_a(Numeric)

    node_module.reload
    expect(node_module.config.dig("last_build", "build_id")).to eq(result.data[:build_id])
  end

  it "fails the build (with the stage name) when a stage errors, and cleans the build dir" do
    allow_any_instance_of(described_class).to receive(:stage_validate)
      .and_return({ success: false, error: "manifest invalid" })

    result = build!

    expect(result.success?).to be false
    expect(result.error).to match(/Build failed at validate: manifest invalid/)
    expect(Dir.glob(Rails.root.join("tmp", "builds", node_module.id.to_s, "build-*").to_s)).to be_empty
  end
end
