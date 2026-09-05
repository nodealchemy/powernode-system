# frozen_string_literal: true

require "rails_helper"
require_relative "../../../support/schema_defect_helpers"

# The snapshot is the history the dashboard and the health-check skill read.
# #persist swallowed every StandardError into `persisted: false`, which is
# the right answer for a transient write failure and the wrong one for the
# snapshots table not existing — the state the CI checkout was in for weeks,
# during which every run "succeeded" with nothing written.
RSpec.describe System::Platform::CompositeHealthProbe, "#persist" do
  let(:account) { create(:account) }
  let(:probe) { described_class.new(account: account, source: "spec") }

  before do
    described_class::SUBSYSTEMS.each do |name|
      allow(probe).to receive(:"probe_#{name}").and_return({ status: "ok", stubbed: true })
    end
  end

  it "writes one snapshot row when the table is there" do
    expect { probe.call_and_persist! }.to change(System::PlatformHealthSnapshot, :count).by(1)
  end

  it "re-raises when the snapshots table is missing rather than reporting persisted: false" do
    allow(System::PlatformHealthSnapshot).to receive(:create!)
      .and_raise(schema_defect_error("system_platform_health_snapshots"))

    expect { probe.call_and_persist! }.to raise_error(ActiveRecord::StatementInvalid, /does not exist/)
  end

  it "still returns the result with persisted: false on a transient write failure" do
    allow(System::PlatformHealthSnapshot).to receive(:create!).and_raise(transient_statement_error)

    result = probe.call_and_persist!

    expect(result[:persisted]).to be(false)
    expect(result[:snapshot_id]).to be_nil
    expect(result[:overall]).to be_present
  end
end
