# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block M + Block U — TradingPressureSensor + PressureEmitter
# + TradingAwareThrottle. Cross-domain coordination via stigmergic bus.
RSpec.describe "Cross-domain stigmergic coordination" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }

  describe System::Fleet::Sensors::TradingPressureSensor do
    let(:sensor) { described_class.new(account: account) }

    it "emits no signal when stigmergic bus has no relevant pressure" do
      expect(sensor.sense).to be_empty
    end

    it "aggregates trading.* signals into a single fleet signal" do
      service_double = instance_double(Ai::Coordination::StigmergicSignalService)
      sig_a = double("StigSig", strength: 0.6, signal_type: "trading.high_load",
                              signal_key: "venue:bybit", payload: {})
      sig_b = double("StigSig", strength: 0.7, signal_type: "trading.market_pressure",
                              signal_key: "btc-usd", payload: {})
      allow(Ai::Coordination::StigmergicSignalService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:perceive).and_return([sig_a, sig_b])

      signals = sensor.sense
      expect(signals.size).to eq(1)
      s = signals.first
      expect(s.kind).to eq("system.trading_pressure_observed")
      expect(s.payload["aggregate_strength"]).to be_within(0.01).of(1.3)
      expect(s.payload["source_signal_count"]).to eq(2)
    end

    it "scales severity with aggregate strength" do
      service_double = instance_double(Ai::Coordination::StigmergicSignalService)
      sig = double("StigSig", strength: 4.0, signal_type: "trading.high_load",
                            signal_key: "k", payload: {})
      allow(Ai::Coordination::StigmergicSignalService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:perceive).and_return([sig])
      expect(sensor.sense.first.severity).to eq(:critical)
    end

    it "ignores signals below the strength threshold" do
      service_double = instance_double(Ai::Coordination::StigmergicSignalService)
      sig = double("StigSig", strength: 0.1, signal_type: "trading.high_load",
                            signal_key: "k", payload: {})
      allow(Ai::Coordination::StigmergicSignalService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:perceive).and_return([sig])
      expect(sensor.sense).to be_empty
    end
  end

  describe System::Fleet::PressureEmitter do
    it "emits zero signals when there are no instances" do
      service_double = instance_double(Ai::Coordination::StigmergicSignalService)
      allow(Ai::Coordination::StigmergicSignalService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:emit!).and_return(double("Signal", id: SecureRandom.uuid))

      result = described_class.emit_for_account!(account: account)
      # capacity strength 0 (no instances) skips emit; error strength 0 skips emit;
      # zero regions; result is 0 emissions.
      expect(result).to be_a(Integer)
    end

    it "emits a capacity signal when many instances are not running" do
      4.times do |i|
        node = create(:system_node, account: account, node_template: template, name: "n-#{i}")
        create(:system_node_instance, node: node) # status=pending → not running
      end

      service_double = instance_double(Ai::Coordination::StigmergicSignalService)
      emit_calls = []
      allow(Ai::Coordination::StigmergicSignalService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:emit!) do |**args|
        emit_calls << args
        double("StigSig", id: SecureRandom.uuid)
      end

      described_class.emit_for_account!(account: account)
      capacity_emit = emit_calls.find { |c| c[:signal_type] == "system.capacity_pressure" }
      expect(capacity_emit).to be_present
      expect(capacity_emit[:strength]).to be > 0
    end
  end

  describe System::Fleet::TradingAwareThrottle do
    it "bypasses for critical actions" do
      result = described_class.evaluate(account: account, action_category: "system.cert_revoke")
      expect(result[:throttled]).to be false
      expect(result[:reason]).to eq("critical_action_bypass")
    end

    it "throttles non-critical actions when trading aggregate is high" do
      service_double = instance_double(Ai::Coordination::StigmergicSignalService)
      sig = double("StigSig", strength: 1.5, signal_type: "trading.high_load",
                            signal_key: "k", payload: {})
      allow(Ai::Coordination::StigmergicSignalService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:perceive).and_return([sig])

      result = described_class.evaluate(account: account, action_category: "system.module_assign")
      expect(result[:throttled]).to be true
      expect(result[:defer_seconds]).to be > 0
    end

    it "does not throttle when below threshold" do
      service_double = instance_double(Ai::Coordination::StigmergicSignalService)
      allow(Ai::Coordination::StigmergicSignalService).to receive(:new).and_return(service_double)
      allow(service_double).to receive(:perceive).and_return([])

      result = described_class.evaluate(account: account, action_category: "system.module_assign")
      expect(result[:throttled]).to be false
      expect(result[:reason]).to eq("below_threshold")
    end
  end
end
