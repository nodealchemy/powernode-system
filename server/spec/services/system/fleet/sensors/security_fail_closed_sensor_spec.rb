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

    it "uses a per-account fingerprint, not per-instance or per-unit" do
      record!(instance!, "pivot_security_fail_closed_units" => %w[unit-a.service])

      expect(signal[:fingerprint]).to eq("node_security_fail_closed:#{account.id}")
    end

    # review G6: a node's own document is never cross-account visible.
    it "does NOT include another account's instance" do
      record!(instance!, "pivot_security_fail_closed_units" => %w[own-account-unit.service])

      other_account = create(:account)
      other_node = create(:system_node, account: other_account)
      other_instance = create(:system_node_instance, node: other_node, status: "running", last_heartbeat_at: 1.minute.ago)
      other_instance.update!(config: other_instance.config.merge(
        System::BootLkgStateWriter::CONFIG_KEY => { "pivot_security_fail_closed_units" => %w[other-account-unit.service] }
      ))

      expect(signal.dig(:payload, "instance_count")).to eq(1)
      names = signal.dig(:payload, "instances").flat_map { |i| i["units"].values }.flatten
      expect(names).to eq(%w[own-account-unit.service])
    end

    # review G6: a live heartbeat that stops reporting the field (the unit
    # recovered, or the agent's rollout replaced the field with an absence)
    # must clear the alarm — proven through the REAL writer, not the raw
    # record! helper, so this also pins BootLkgStateWriter's own "rewrite on
    # every heartbeat" rule as the mechanism that makes recovery visible here.
    it "clears once a later heartbeat no longer reports the field" do
      # `signals`/`signal` are memoized `subject`s (one query per example) —
      # this test needs to observe the sensor's output at TWO different
      # points, so it calls the sensor fresh each time rather than through
      # the memoized helpers.
      sense = -> { described_class.new(account: account).sense }

      failing = instance!
      System::BootLkgStateWriter.write!(
        instance: failing,
        payload: { "pivot_security_fail_closed_units" => %w[unit-a.service] }
      )
      expect(sense.call.find { |s| s[:kind] == "system.node_security_fail_closed" }).not_to be_nil

      System::BootLkgStateWriter.write!(instance: failing, payload: { "lkg_present" => true })

      expect(sense.call).to eq([])
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
