# frozen_string_literal: true

require "rails_helper"

# IMP-9f4e162d9ed1 — the operator-visible half of the fail-closed assignment
# rules. The agent keeps modules it would otherwise detach (an empty or
# config-only assignment list, IMP-1023e79cc82d) and skips the identity render
# when a module's manifest cannot be resolved. Both are safe and both are silent:
# a node stuck in either runs a composition that no longer matches what the
# platform assigned. BootLkgStateWriter persists the agent's assignment_deferral
# report; this sensor makes a PERSISTENT one reach a person.
RSpec.describe System::Fleet::Sensors::AssignmentDeferralSensor do
  let(:account) { create(:account) }
  let(:node)    { create(:system_node, account: account) }

  subject(:signals) { described_class.new(account: account).sense }

  def signal = signals.find { |s| s[:kind] == "system.node_assignment_deferred" }

  def instance!(heartbeat_at: 1.minute.ago, status: "running")
    create(:system_node_instance, node: node, status: status, last_heartbeat_at: heartbeat_at)
  end

  def report!(instance, *deferrals)
    System::BootLkgStateWriter.write!(instance: instance, payload: { "assignment_deferral" => deferrals })
    instance.reload
  end

  def deferral(reason: "empty_assignment", modules: %w[m1], seconds: 3600)
    { "reason" => reason, "module_ids" => modules, "persisted_seconds" => seconds }
  end

  describe "the quiet direction" do
    it "emits nothing for a node that reports no deferral" do
      instance!

      expect(signals).to eq([])
    end

    it "emits nothing for a deferral younger than the threshold (a blip is not a condition)" do
      report!(instance!, deferral(seconds: 60))

      expect(signals).to eq([])
    end

    it "emits nothing for an unmeasured duration" do
      report!(instance!, deferral(seconds: nil))

      expect(signals).to eq([])
    end

    it "does not alarm on a silent or non-running instance" do
      report!(instance!(heartbeat_at: 1.hour.ago), deferral)
      report!(instance!(status: "stopped"), deferral)

      expect(signals).to eq([])
    end
  end

  describe "the alarm direction" do
    it "fires for a deferral that has persisted past the threshold, naming reason and modules" do
      report!(instance!, deferral(modules: %w[m1 m2]))

      expect(signal).not_to be_nil
      expect(signal[:severity]).to eq(:high)
      named = signal.dig(:payload, "instances", 0)
      expect(named["deferrals"]).to eq([ { "reason" => "empty_assignment", "module_ids" => %w[m1 m2], "persisted_seconds" => 3600 } ])
    end

    it "fires for a persistent identity render skip" do
      report!(instance!, deferral(reason: "identity_render_skipped", modules: %w[m3]))

      expect(signal.dig(:payload, "instances", 0, "deferrals", 0, "reason")).to eq("identity_render_skipped")
    end

    it "aggregates into ONE signal per account with a per-account fingerprint" do
      report!(instance!, deferral)
      report!(instance!, deferral(modules: %w[m9]))

      expect(signals.count { |s| s[:kind] == "system.node_assignment_deferred" }).to eq(1)
      expect(signal.dig(:payload, "instance_count")).to eq(2)
      expect(signal[:fingerprint]).to eq("node_assignment_deferred:#{account.id}")
    end

    it "does not include another account's instance" do
      report!(instance!, deferral(modules: %w[own]))
      other_node = create(:system_node, account: create(:account))
      other = create(:system_node_instance, node: other_node, status: "running", last_heartbeat_at: 1.minute.ago)
      report!(other, deferral(modules: %w[theirs]))

      expect(signal.dig(:payload, "instance_count")).to eq(1)
      expect(signal.dig(:payload, "instances").flat_map { |i| i["deferrals"].flat_map { |d| d["module_ids"] } }).to eq(%w[own])
    end

    it "clears once a later heartbeat no longer reports it (via the real writer)" do
      inst = instance!
      report!(inst, deferral)
      expect(signal).not_to be_nil

      System::BootLkgStateWriter.write!(instance: inst, payload: { "lkg_present" => true })

      expect(described_class.new(account: account).sense).to eq([])
    end

    it "honours the operator threshold setting" do
      report!(instance!, deferral(seconds: 120))
      allow(SiteSetting).to receive(:get).and_call_original
      allow(SiteSetting).to receive(:get).with("system.assignment_deferral.persisted_after_seconds").and_return("60")

      expect(signal).not_to be_nil
    end
  end

  describe "the wiring" do
    it "is bound in the DecisionEngine to a notify-only investigation with no skill" do
      binding = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.node_assignment_deferred"]

      expect(binding).to include(skill: nil, action_category: "system.node_assignment_deferred_investigate")
    end

    it "declares the category notify_and_proceed and exempts it from remediation scoring" do
      expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES["system.node_assignment_deferred_investigate"])
        .to eq("notify_and_proceed")
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.node_assignment_deferred_investigate")
    end

    it "is registered with the fleet autonomy sensor list" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end
  end
end
