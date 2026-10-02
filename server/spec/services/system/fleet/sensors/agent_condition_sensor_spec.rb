# frozen_string_literal: true

require "rails_helper"

# IMP-a6d61b01490d — the operator-visible half of the agent's standing
# conditions. The agent keeps a known-degraded unit and a refused sudoers grant
# off the failure path on purpose, and used to say so only on stderr.
# BootLkgStateWriter persists its agent_conditions report; this sensor makes a
# live node's standing conditions reach a person. Notify-only.
RSpec.describe System::Fleet::Sensors::AgentConditionSensor do
  let(:account) { create(:account) }
  let(:node)    { create(:system_node, account: account) }

  # NOT `subject`/`let`: those memoize within an example, and several examples
  # here re-read the sensor after the node's report changes.
  def signals = described_class.new(account: account).sense

  def signal = signals.find { |s| s[:kind] == "system.node_agent_condition" }

  def instance!(heartbeat_at: 1.minute.ago, status: "running")
    create(:system_node_instance, node: node, status: status, last_heartbeat_at: heartbeat_at)
  end

  def report!(instance, conditions)
    System::BootLkgStateWriter.write!(instance: instance, payload: { "agent_conditions" => conditions })
    instance.reload
  end

  def condition(kind: "known_degraded_unit", subject: "powernode-m1-credential.service", detail: "module m1")
    { "kind" => kind, "subject" => subject, "detail" => detail, "first_seen" => "2026-10-01T10:00:00Z" }
  end

  describe "the quiet direction" do
    it "emits nothing for a node that reports an empty list (measured, none)" do
      report!(instance!, [])

      expect(signals).to eq([])
    end

    it "emits nothing for a node that has not reported at all (an agent too old to say)" do
      instance!

      expect(signals).to eq([])
    end

    it "does not alarm on a silent or non-running instance" do
      report!(instance!(heartbeat_at: 1.hour.ago), [ condition ])
      report!(instance!(status: "stopped"), [ condition ])

      expect(signals).to eq([])
    end
  end

  describe "the alarm direction" do
    it "emits ONE notify-only signal per account naming each affected node and its conditions" do
      a = instance!
      b = instance!
      report!(a, [ condition, condition(kind: "sudoers_refused", subject: "mod-a/bad name", detail: "illegal drop-in name") ])
      report!(b, [ condition ])

      expect(signals.size).to eq(1)
      payload = signal[:payload]
      expect(signal[:severity]).to eq(:high)
      expect(payload["instance_count"]).to eq(2)
      expect(payload["remediation_action"]).to be_nil
      expect(payload["instances"].map { |i| i["instance_id"] }).to contain_exactly(a.id, b.id)
      kinds = payload["instances"].flat_map { |i| i["conditions"].map { |c| c["kind"] } }
      expect(kinds).to include("known_degraded_unit", "sudoers_refused")
    end

    it "keeps the fingerprint STABLE while the same conditions stand, and changes it when the set changes" do
      inst = instance!
      report!(inst, [ condition ])
      first = signal[:fingerprint]

      report!(inst, [ condition ])
      expect(signal[:fingerprint]).to eq(first)

      report!(inst, [ condition, condition(kind: "sudoers_refused", subject: "mod-a/g", detail: "x") ])
      expect(signal[:fingerprint]).not_to eq(first)
    end

    it "goes quiet once the node reports the empty list" do
      inst = instance!
      report!(inst, [ condition ])
      expect(signal).to be_present

      report!(inst, [])
      expect(signals).to eq([])
    end
  end
end
