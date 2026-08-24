# frozen_string_literal: true

require "rails_helper"

# G4 migrated-caller pin.
#
# LearningTool gained a per-action permission gate: create_learning now requires
# ai.analytics.manage. Both learning extractors run inside an autonomy tick with
# NO user, so without an explicit `internal: true` every call is refused and the
# platform silently stops recording learnings — a new inert lane created by the
# very change meant to close an escalation.
#
# A nil user deliberately does NOT imply internal (IMP-9030413bc292): an MCP
# instance principal arrives with none too, and tools that inferred it handed
# those principals every per-action permission. So the flag must be passed, and
# that is a property of the CALL SITE which no test of the tool can observe.
#
# Pinned on the constructor arguments rather than on a spy of the whole flow,
# because the failure mode is precisely someone deleting the flag during an
# unrelated refactor — the call still compiles and the tick still "succeeds",
# recording nothing.
RSpec.describe "learning extractors opt in as internal callers" do
  EXTRACTORS = {
    "fleet" => "app/services/system/fleet/learning_extractor.rb",
    "cve_ops" => "app/services/system/cve_ops/learning_extractor.rb"
  }.freeze

  EXTRACTORS.each do |name, rel|
    it "#{name} constructs LearningTool with internal: true" do
      source = Rails.root.join("../extensions/system/server", rel).read
      construction = source[/::Ai::Tools::LearningTool\.new\([^)]*\)/]

      expect(construction).to be_present, "#{rel} no longer constructs LearningTool"
      expect(construction).to include("internal: true"),
        "#{rel} constructs LearningTool without internal: true — create_learning " \
        "requires ai.analytics.manage and this caller has no user, so every " \
        "learning would be silently refused"
    end
  end

  # The behavioural half: an extractor-shaped caller can actually record.
  # Without this the pin above is satisfiable by a comment.
  it "records a learning through the tool as a user-less internal caller" do
    account = create(:account)
    tool = ::Ai::Tools::LearningTool.new(account: account, agent: nil, user: nil, internal: true)

    expect {
      tool.execute(params: { action: "create_learning", content: "g4 pin", category: "discovery" })
    }.to change { ::Ai::CompoundLearning.count }.by(1)
  end

  # ...and the same caller WITHOUT the flag is refused, so the flag is load-bearing.
  it "is refused without the flag, proving the opt-in is what permits it" do
    account = create(:account)
    tool = ::Ai::Tools::LearningTool.new(account: account, agent: nil, user: nil)

    expect {
      tool.execute(params: { action: "create_learning", content: "g4 pin 2", category: "discovery" })
    }.not_to change { ::Ai::CompoundLearning.count }
  end
end
