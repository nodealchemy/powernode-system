# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block I — FleetEvent + EventBroadcaster.
RSpec.describe System::Fleet::EventBroadcaster do
  let(:account) { create(:account) }

  describe ".emit!" do
    it "creates a FleetEvent row with given fields" do
      expect {
        event = described_class.emit!(
          account: account,
          kind: "system.module_drift",
          severity: :high,
          payload: { instance_id: "inst-1", missing_count: 2 },
          source: "module_drift_sensor",
          correlation_id: "corr-1"
        )
        expect(event).to be_a(System::FleetEvent)
        expect(event.kind).to eq("system.module_drift")
        expect(event.severity).to eq("high")
        expect(event.payload["instance_id"]).to eq("inst-1")
        expect(event.correlation_id).to eq("corr-1")
        expect(event.source).to eq("module_drift_sensor")
      }.to change(System::FleetEvent, :count).by(1)
    end

    it "extracts node_instance_id from payload as a column ref" do
      uuid = SecureRandom.uuid
      described_class.emit!(
        account: account, kind: "x.y", severity: :low,
        payload: { instance_id: uuid }, source: "test"
      )
      expect(System::FleetEvent.last.node_instance_id).to eq(uuid)
    end

    it "returns nil on validation failure rather than raising" do
      result = described_class.emit!(
        account: account, kind: "x.y", severity: :nonsense,
        payload: {}, source: "test"
      )
      expect(result).to be_nil
    end

    it "returns nil when account is missing" do
      result = described_class.emit!(account: nil, kind: "x", severity: :low, payload: {})
      expect(result).to be_nil
    end
  end

  describe ".emit_signal!" do
    it "extracts kind/severity/fingerprint from a Signal value object" do
      i_uuid = SecureRandom.uuid
      m_uuid = SecureRandom.uuid
      signal = System::Fleet::Signal.new(
        kind: "system.module_drift",
        severity: :medium,
        payload: { instance_id: i_uuid, module_id: m_uuid },
        fingerprint: "drift:#{i_uuid}"
      )
      event = described_class.emit_signal!(account: account, signal: signal)
      expect(event.kind).to eq("system.module_drift")
      expect(event.payload["fingerprint"]).to eq("drift:#{i_uuid}")
      expect(event.node_instance_id).to eq(i_uuid)
      expect(event.node_module_id).to eq(m_uuid)
    end
  end

  describe ".emit_decision!" do
    it "constructs a decision.* event with source_signal context" do
      i_uuid = SecureRandom.uuid
      signal = System::Fleet::Signal.new(
        kind: "system.module_drift",
        severity: :medium,
        payload: { instance_id: i_uuid },
        fingerprint: "drift:#{i_uuid}"
      )
      decision = { decision: :proceed, gate: "auto_approve", action_category: "system.module_assign" }
      event = described_class.emit_decision!(account: account, decision: decision, signal: signal)
      expect(event.kind).to eq("decision.proceed")
      expect(event.payload["action_category"]).to eq("system.module_assign")
      expect(event.payload["gate"]).to eq("auto_approve")
      expect(event.correlation_id).to eq("drift:#{i_uuid}")
    end
  end
end

RSpec.describe System::FleetEvent do
  let(:account) { create(:account) }

  describe "#severity_weight" do
    it "matches Signal::SEVERITY_WEIGHTS so dashboards rank consistently" do
      e = described_class.create!(account: account, kind: "x", severity: "critical", payload: {})
      expect(e.severity_weight).to eq(System::Fleet::Signal::SEVERITY_WEIGHTS[:critical])
    end
  end

  describe "#as_broadcast" do
    it "produces a stable shape for ActionCable" do
      e = described_class.create!(account: account, kind: "x.y", severity: "low",
                                   payload: { foo: "bar" }, correlation_id: "c-1")
      shape = e.as_broadcast
      expect(shape).to include(:id, :kind, :severity, :payload, :correlation_id, :emitted_at, :account_id)
      expect(shape[:kind]).to eq("x.y")
      expect(shape[:correlation_id]).to eq("c-1")
    end
  end

  describe "scopes" do
    before do
      described_class.create!(account: account, kind: "system.module_drift", severity: "high", payload: {})
      described_class.create!(account: account, kind: "decision.proceed", severity: "low", payload: {})
      described_class.create!(account: account, kind: "system.module_drift", severity: "low", payload: {},
                              correlation_id: "tick-A")
    end

    it ".by_kind filters" do
      expect(described_class.by_kind("system.module_drift").count).to eq(2)
    end

    it ".high_or_critical filters" do
      expect(described_class.high_or_critical.count).to eq(1)
    end

    it ".by_correlation filters" do
      expect(described_class.by_correlation("tick-A").count).to eq(1)
    end
  end
end
