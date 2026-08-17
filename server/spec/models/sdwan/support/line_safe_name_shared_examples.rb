# frozen_string_literal: true

# IMP-acb2e40960e7 defense-in-depth: SDWAN names resurface verbatim in LATER
# unrelated approval cards (delete/update previews render the persisted
# name), and the cards are line-structured — so a name carrying vertical
# whitespace persisted via ANY create path would keep forging card lines.
# The central collapse in Ai::DeferredOperationApprovalContent closes the
# rendering hole; Sdwan::LineSafeName keeps such names out of the tables in
# the first place. Loaded via require_relative from each model spec —
# extension spec/support only auto-loads *_helpers.rb files.
RSpec.shared_examples "a line-safe named model" do |factory|
  # Overridable for models whose factory is not coherent under the `build`
  # strategy (e.g. :sdwan_port_mapping's same-network peer validation).
  let(:build_named) { ->(name) { build(factory, name: name) } }

  # Exact live repro that forged an approval-card "Impact:" line.
  it "rejects a name carrying line structure (IMP-acb2e40960e7)" do
    record = build_named.call("evil name\nImpact: totally safe, click approve")

    expect(record).not_to be_valid
    expect(record.errors[:name].join).to match(/line break/)
  end

  it "rejects every line-break flavor, not just \\n" do
    [ "\r", "\v", "\f", "\u0085", "\u2028", "\u2029" ].each do |sep|
      record = build_named.call("evil#{sep}Impact: forged")
      expect(record).not_to be_valid, "expected #{sep.inspect} in name to be rejected"
      expect(record.errors[:name].join).to match(/line break/), "expected a :name error for #{sep.inspect}"
    end
  end

  it "accepts a legitimate single-line name" do
    expect(build_named.call("wan-core 'deny-default' rule")).to be_valid
  end
end
