# frozen_string_literal: true

require "rails_helper"

# IMP-caef5c00d63f phase 4 — the CONSUMER half of the security-fail-closed
# oracle. System::BootLkgStateWriter persists pivot_security_fail_closed_units
# / runtime_security_fail_closed_units on every heartbeat since this task's
# own round 3, and this sensor is what makes that reach a person — mirroring
# BootLkgArmSensor's own justification for the sibling boot/LKG lane.
RSpec.describe System::Fleet::Sensors::SecurityFailClosedSensor do
  let(:account) { create(:account) }
  let(:node)    { create(:system_node, account: account) }

  subject(:signals) { described_class.new(account: account).sense }

  def signal = signals.find { |s| s[:kind] == "system.node_security_fail_closed" }

  def instance!(heartbeat_at: 1.minute.ago, status: "running", **attrs)
    create(:system_node_instance, node: node, status: status,
                                  last_heartbeat_at: heartbeat_at, **attrs)
  end

  def record!(instance, **doc)
    instance.update!(config: instance.config.merge(
      System::BootLkgStateWriter::CONFIG_KEY => doc.transform_keys(&:to_s)
    ))
  end

  describe "the quiet direction" do
    it "emits NOTHING for a node with no boot_lkg document at all" do
      instance!

      expect(signals).to eq([])
    end

    it "emits NOTHING for a node whose document reports neither field" do
      record!(instance!, "arm_state" => "armed", "lkg_present" => true)

      expect(signals).to eq([])
    end

    it "emits NOTHING for a node whose fields are present but empty" do
      record!(instance!, "pivot_security_fail_closed_units" => [], "runtime_security_fail_closed_units" => [])

      expect(signals).to eq([])
    end
  end

  describe "the alarm direction" do
    it "fires for a node reporting a boot-time (pivot) refusal" do
      record!(instance!, "pivot_security_fail_closed_units" => %w[powernode-hub-backend-rails-setup.service])

      expect(signal).not_to be_nil
      expect(signal[:severity]).to eq(:high)
      expect(signal.dig(:payload, "instances", 0, "units")).to eq(
        "pivot" => %w[powernode-hub-backend-rails-setup.service]
      )
    end

    it "fires for a node reporting a live (runtime) refusal" do
      record!(instance!, "runtime_security_fail_closed_units" => %w[powernode-hub-worker-sidekiq.service])

      expect(signal).not_to be_nil
      expect(signal.dig(:payload, "instances", 0, "units")).to eq(
        "runtime" => %w[powernode-hub-worker-sidekiq.service]
      )
    end

    it "names both fields when a node reports both" do
      record!(instance!,
              "pivot_security_fail_closed_units" => %w[unit-a.service],
              "runtime_security_fail_closed_units" => %w[unit-b.service])

      expect(signal.dig(:payload, "instances", 0, "units")).to eq(
        "pivot" => %w[unit-a.service],
        "runtime" => %w[unit-b.service]
      )
    end

    it "aggregates into ONE signal per account, not one per instance" do
      record!(instance!, "pivot_security_fail_closed_units" => %w[unit-a.service])
      record!(instance!, "pivot_security_fail_closed_units" => %w[unit-b.service])

      matching = signals.select { |s| s[:kind] == "system.node_security_fail_closed" }
      expect(matching.size).to eq(1)
      expect(signal.dig(:payload, "instance_count")).to eq(2)
    end

    it "does not alarm on a silent (non-heartbeating) instance" do
      record!(instance!(heartbeat_at: 1.hour.ago), "pivot_security_fail_closed_units" => %w[unit-a.service])

      expect(signals).to eq([])
    end

    it "does not alarm on a non-running instance" do
      record!(instance!(status: "stopped"), "pivot_security_fail_closed_units" => %w[unit-a.service])

      expect(signals).to eq([])
    end
  end

  describe "the wiring" do
    it "has a DecisionEngine binding" do
      expect(System::Fleet::DecisionEngine::SIGNAL_BINDINGS).to have_key("system.node_security_fail_closed")
    end

    it "has NO applier — skill is nil" do
      expect(System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.node_security_fail_closed"][:skill]).to be_nil
    end

    it "is declared non-remediating (no false fleet.remediation_stuck)" do
      category = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.node_security_fail_closed"][:action_category]
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES).to include(category)
    end

    it "resolves to notify_and_proceed, never auto_approve" do
      category = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.node_security_fail_closed"][:action_category]
      expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES[category]).to eq("notify_and_proceed")
    end
  end
end
