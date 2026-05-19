# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Slo::TelemetryAdapter do
  describe ".latency_p99_ms" do
    let(:account) { create(:account) }
    let(:node_module) do
      create(:system_node_module, account: account,
                                   node_platform: create(:system_node_platform, account: account),
                                   category: create(:system_node_module_category, account: account))
    end
    let(:since) { 1.hour.ago }

    def emit(value, kind: "metric.latency_ms", at: 5.minutes.ago, module_id: node_module.id, acct: account)
      ::System::FleetEvent.create!(
        account: acct,
        kind: kind,
        severity: "low",
        source: "test",
        node_module_id: module_id,
        payload: { "value" => value, "node_module_id" => module_id.to_s },
        emitted_at: at
      )
    end

    it "returns nil when no samples exist for the module" do
      expect(described_class.latency_p99_ms(node_module: node_module, since: since)).to be_nil
    end

    it "returns nil when only out-of-window samples exist" do
      emit(100, at: 2.hours.ago)
      expect(described_class.latency_p99_ms(node_module: node_module, since: since)).to be_nil
    end

    it "returns the single-sample value when only one in-window sample exists" do
      emit(42.5)
      expect(described_class.latency_p99_ms(node_module: node_module, since: since)).to eq(42.5)
    end

    it "computes p99 across multiple samples" do
      # 100 samples 1..100; p99 ≈ 99.01 with linear interpolation.
      (1..100).each { |v| emit(v, at: (100 - v).minutes.ago.clamp(50.minutes.ago, Time.current)) }
      result = described_class.latency_p99_ms(node_module: node_module, since: since)
      expect(result).to be_within(0.5).of(99.0)
    end

    it "scopes by account (no cross-tenant leakage)" do
      other_account = create(:account)
      foreign_module = create(:system_node_module, account: other_account,
                                                    node_platform: create(:system_node_platform, account: other_account),
                                                    category: create(:system_node_module_category, account: other_account))
      emit(999, module_id: foreign_module.id, acct: other_account)
      expect(described_class.latency_p99_ms(node_module: node_module, since: since)).to be_nil
    end

    it "scopes by node_module (other modules in same account don't leak)" do
      other_module = create(:system_node_module, account: account,
                                                  node_platform: node_module.node_platform,
                                                  category: node_module.category, name: "other-#{SecureRandom.hex(3)}")
      emit(999, module_id: other_module.id)
      expect(described_class.latency_p99_ms(node_module: node_module, since: since)).to be_nil
    end

    it "ignores non-latency metric kinds" do
      emit(500, kind: "metric.cpu_pct")
      expect(described_class.latency_p99_ms(node_module: node_module, since: since)).to be_nil
    end

    it "tolerates payload values that aren't coercible to Float" do
      emit("nope")
      emit(50)
      result = described_class.latency_p99_ms(node_module: node_module, since: since)
      expect(result).to eq(50.0)
    end

    it "falls back to payload['node_module_id'] when the typed column is null" do
      # Some samplers write payload-only (e.g. external telemetry forwarders
      # that don't know about the system_node_modules FK). The adapter MUST
      # still pick up those samples.
      ::System::FleetEvent.create!(
        account: account, kind: "metric.latency_ms", severity: "low", source: "test",
        node_module_id: nil,
        payload: { "value" => 77, "node_module_id" => node_module.id.to_s },
        emitted_at: 5.minutes.ago
      )
      expect(described_class.latency_p99_ms(node_module: node_module, since: since)).to eq(77.0)
    end
  end
end
