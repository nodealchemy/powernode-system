# frozen_string_literal: true

require "rails_helper"
require "rake"

# IMP-f1f96c292991 — `rails sample_content:remove` wraps
# System::SampleContentRemovalService, dry-run by default, CONFIRM_DELETE=yes
# to apply. Mirrors the sdwan:debris_report convention (lib/tasks/sdwan_debris.rake).
RSpec.describe "sample_content:remove rake task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("sample_content:remove")
  end

  before do
    Rake::Task["sample_content:remove"].reenable
  end

  def capture_task_output
    original_out = $stdout
    $stdout = StringIO.new
    Rake::Task["sample_content:remove"].invoke
    $stdout.string
  ensure
    $stdout = original_out
  end

  let!(:account) { create(:account) }
  let!(:agent) { create(:ai_agent, account: account, name: "Customer Success Agent") }

  after { ENV.delete("CONFIRM_DELETE") }

  it "defaults to dry run and performs zero writes" do
    output = capture_task_output

    expect(output).to include("DRY RUN")
    expect(output).to include("Zero writes performed")
    expect(Ai::Agent.exists?(agent.id)).to be(true)
  end

  it "applies and destroys candidate rows only when CONFIRM_DELETE=yes" do
    ENV["CONFIRM_DELETE"] = "yes"
    output = capture_task_output

    expect(output).to include("APPLY")
    expect(output).to include("row(s) destroyed")
    expect(Ai::Agent.exists?(agent.id)).to be(false)
  end

  it "states the candidate count before acting" do
    output = capture_task_output

    expect(output).to match(/candidate row\(s\)/)
  end
end
