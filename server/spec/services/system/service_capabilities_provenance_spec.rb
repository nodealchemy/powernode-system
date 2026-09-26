# frozen_string_literal: true

require "rails_helper"

# IMP-caef5c00d63f — the read-only drift check run before promoting any agent
# that carries the per-service resolver. It compares every service row with
# its module's stored manifest on key PRESENCE and reports the modules that
# stay unmarked (legacy inherit mode) and why.
RSpec.describe System::ServiceCapabilitiesProvenance do
  let(:account) { create(:account) }

  def module_with(yaml)
    create(:system_node_module, account: account, manifest_yaml: yaml)
  end

  def row(mod, name, capabilities:, flagged:)
    create(:system_module_service, node_module: mod, account: account, name: name,
           capabilities: capabilities, capabilities_presence_recorded: flagged)
  end

  describe ".classify" do
    let(:yaml) do
      <<~YAML
        services:
          - { name: a, start_command: x }
          - { name: b, start_command: x, capabilities: [] }
          - { name: c, start_command: x, capabilities: [CAP_CHOWN] }
          - { name: d, start_command: x, capabilities: CAP_CHOWN }
          - { name: e, start_command: x, capabilities: null }
      YAML
    end

    it "classifies each shape of a stored service entry" do
      expect(described_class.classify(yaml, "a")).to eq([ :absent, nil ])
      expect(described_class.classify(yaml, "b")).to eq([ :empty, [] ])
      expect(described_class.classify(yaml, "c")).to eq([ :list, %w[CAP_CHOWN] ])
      expect(described_class.classify(yaml, "d").first).to eq(:invalid)
      expect(described_class.classify(yaml, "e")).to eq([ :absent, nil ])
      expect(described_class.classify(yaml, "zzz").first).to eq(:missing)
      expect(described_class.classify("services: [unclosed", "a").first).to eq(:unparseable)
      expect(described_class.classify(nil, "a").first).to eq(:unparseable)
    end
  end

  describe ".drift_report" do
    it "reports rows that disagree with the stored manifest on key presence" do
      mod = module_with("services:\n  - { name: absent, start_command: x }\n  - { name: listed, start_command: x, capabilities: [CAP_CHOWN] }\n")
      row(mod, "absent", capabilities: [], flagged: false)        # pre-stage-1 collapse
      row(mod, "listed", capabilities: nil, flagged: true)        # presence lost the other way

      report = described_class.drift_report

      drifted = report[:drift].map { |d| d[:service] }
      expect(drifted).to contain_exactly("absent", "listed")
    end

    it "reports no drift for rows that match their stored manifest" do
      mod = module_with("services:\n  - { name: absent, start_command: x }\n  - { name: empty, start_command: x, capabilities: [] }\n")
      row(mod, "absent", capabilities: nil, flagged: true)
      row(mod, "empty", capabilities: [], flagged: false)

      expect(described_class.drift_report[:drift]).to be_empty
    end

    it "names modules left unmarked because of a legacy declared [] (republish from the swept manifest)" do
      mod = module_with("services:\n  - { name: absent, start_command: x }\n  - { name: empty, start_command: x, capabilities: [] }\n")
      row(mod, "absent", capabilities: nil, flagged: true)
      row(mod, "empty", capabilities: [], flagged: false)

      report = described_class.drift_report

      expect(report[:legacy_empty_modules].map { |m| m[:module_id] }).to eq([ mod.id ])
      expect(report[:legacy_empty_modules].first[:services]).to eq([ "empty" ])
      expect(report[:marked_module_ids]).not_to include(mod.id)
    end

    it "names modules it cannot vouch for (unparseable manifest or service not in it)" do
      bad = module_with("services: [unclosed")
      row(bad, "x", capabilities: [], flagged: false)

      report = described_class.drift_report

      expect(report[:unvouched_modules].map { |m| m[:module_id] }).to eq([ bad.id ])
    end

    it "lists fully flagged modules as marked" do
      mod = module_with("services:\n  - { name: a, start_command: x }\n")
      row(mod, "a", capabilities: nil, flagged: true)

      expect(described_class.drift_report[:marked_module_ids]).to eq([ mod.id ])
    end
  end
end
