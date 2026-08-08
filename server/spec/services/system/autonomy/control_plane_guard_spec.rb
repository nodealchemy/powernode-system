# frozen_string_literal: true

require "rails_helper"

# IMP-211d8e0fb9e7 — standby_tick_result's reason must not claim "dual-plane
# mode is armed" when the gate ERRORED (on an unarmed single plane a DB hiccup
# during the armed? read would otherwise report a fence that does not exist).
RSpec.describe System::Autonomy::ControlPlaneGuard do
  let(:host) { Class.new { include System::Autonomy::ControlPlaneGuard }.new }

  it "reports the fence for a genuine standby" do
    result = host.standby_tick_result(status: :standby)

    expect(result[:ok]).to be(false)
    expect(result[:standby]).to be(true)
    expect(result[:gate_status]).to eq(:standby)
    expect(result[:reason]).to match(/dual-plane mode is armed/)
  end

  it "reports a gate error WITHOUT claiming dual-plane mode is armed" do
    result = host.standby_tick_result(status: :gate_error)

    expect(result[:ok]).to be(false)
    expect(result[:standby]).to be(true)
    expect(result[:gate_status]).to eq(:gate_error)
    expect(result[:reason]).to match(/gate error/)
    expect(result[:reason]).not_to match(/armed/)
  end

  it "computes the status itself when called bare (existing caller compatibility)" do
    allow(System::Autonomy::ControlPlaneRole).to receive(:status).and_return(:gate_error)

    result = host.standby_tick_result

    expect(result[:gate_status]).to eq(:gate_error)
    expect(result[:reason]).to match(/gate error/)
  end
end
