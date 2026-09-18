# frozen_string_literal: true

require "rails_helper"

# IMP-80a353489ba4: health_check split out of this executor into
# System::Ai::Skills::PlatformHealthCheckExecutor (bound to
# platform_health_monitor, not concierge) — see
# platform_health_check_executor_spec.rb for the moved coverage (fleet
# instance state, not_measured discipline, persistence, DB-driven
# thresholds…), unchanged in substance.
#
# This file pins the OTHER half of the split: PlatformMaintenanceExecutor
# itself no longer recognizes "health_check" as an action. Without this, a
# caller that still passes action: "health_check" here would silently get
# `success: false` from the generic ACTIONS guard, which reads the same as
# any other typo — nothing distinguishes "the action moved" from "the action
# was never spelled right". Asserted on `ACTIONS` (the enum the MCP wrapper's
# `op:` parameter reads, extensions/system/server/app/services/ai/tools/
# system_fleet_tool.rb) so a future action gains the same regression floor
# without a bespoke assertion.
RSpec.describe System::Ai::Skills::PlatformMaintenanceExecutor do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:executor) { described_class.new(account: account, user: user) }

  it "no longer lists health_check among its actions" do
    expect(described_class::ACTIONS).not_to include("health_check")
  end

  it "rejects action: health_check as unknown, not routes it" do
    result = executor.execute(action: "health_check")

    expect(result[:success]).to be(false)
    expect(result[:error]).to match(/Unknown action: "health_check"/)
  end

  it "still routes its three surviving actions" do
    expect(described_class::ACTIONS).to match_array(%w[cert_status cert_rotate drift_check])
  end
end
