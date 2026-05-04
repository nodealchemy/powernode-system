# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Concierge::FleetContextBuilder do
  describe ".build" do
    let(:account) { create(:account) }
    let(:other_account) { create(:account) }

    it "returns a Markdown snapshot with fleet counts" do
      create(:system_node, account: account)
      create(:system_node, account: account)

      snapshot = described_class.build(account: account)

      expect(snapshot).to include("## Fleet snapshot")
      expect(snapshot).to include("Nodes: 2")
    end

    it "is account-scoped (no cross-tenant leak)" do
      create(:system_node, account: account)
      create(:system_node, account: other_account)
      create(:system_node, account: other_account)
      create(:system_node, account: other_account)

      snapshot = described_class.build(account: account)

      expect(snapshot).to include("Nodes: 1")
    end

    it "returns an empty string when account is nil" do
      expect(described_class.build(account: nil)).to eq("")
    end

    it "includes the SDWAN section only when networks exist for the account" do
      snapshot_without = described_class.build(account: account)
      expect(snapshot_without).not_to include("## SDWAN snapshot")
    end

    it "includes the recent fleet events section when events exist" do
      3.times do |i|
        ::System::FleetEvent.create!(
          account: account, kind: "test.event_#{i}", severity: "low",
          payload: {}, source: "spec"
        )
      end

      snapshot = described_class.build(account: account)

      expect(snapshot).to include("## Recent fleet events")
      expect(snapshot).to include("test.event_0")
    end

    it "truncates to MAX_CHARS when content would be longer" do
      stub_const("System::Concierge::FleetContextBuilder::MAX_CHARS", 80)

      ::System::FleetEvent.create!(
        account: account, kind: "very.long.event.name.that.takes.up.bytes",
        severity: "high", payload: {}, source: "spec"
      )

      snapshot = described_class.build(account: account)

      expect(snapshot.length).to be <= System::Concierge::FleetContextBuilder::MAX_CHARS
      expect(snapshot).to include("context truncated")
    end

    it "never raises — returns empty string on internal failure" do
      allow(::System::Node).to receive(:where).and_raise(StandardError, "boom")
      expect { described_class.build(account: account) }.not_to raise_error
    end
  end
end
