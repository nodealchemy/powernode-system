# frozen_string_literal: true

require "rails_helper"

# Campaign 01a07025 increment app-2 — the notify half of `notify_and_proceed`.
#
# THE DEFECT. FleetAutonomyService#notify_action wrote a durable FleetEvent and
# a Rails.logger line, and that was the whole of "notify". DecisionEngine says
# so in its own words at the module_promotion_stalled binding: "a record, not a
# page. Nobody is notified." An operator picks notify_and_proceed BECAUSE they
# want to be told; the ten `*_investigate` lanes have no applier at all, so for
# those the notification IS the remediation and it was landing nowhere a person
# looks.
#
# Asserted as ROWS in the operator's inbox, never as a return value or a log
# line. The FleetEvent half is pinned separately in
# notify_lane_operator_record_spec.rb and is deliberately not re-asserted here.
RSpec.describe "notify_and_proceed reaches the operator inbox" do
  let(:account)   { create(:account) }
  let!(:operator) { create(:user, account: account) }
  let(:agent)     { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Autonomy") }
  let(:service)   { System::Fleet::FleetAutonomyService.new(account: account, agent: agent) }

  def seed_policy!(category, policy)
    Ai::InterventionPolicy.create!(
      account: account, ai_agent_id: agent.id, scope: "agent",
      action_category: category, policy: policy, is_active: true
    )
  end

  def notify!(fingerprint: "module_verify_failed:m-1")
    service.gate_action!(
      "system.module_verify_investigate",
      metadata: { "signal_kind" => "system.module_verify_failed",
                  "signal_fingerprint" => fingerprint },
      reasoning: { summary: "module verify failed on 3 nodes" }
    )
  end

  def inbox_rows
    Notification.where(account_id: account.id, notification_type: "agent_status_update")
  end

  before { seed_policy!("system.module_verify_investigate", "notify_and_proceed") }

  it "writes an inbox ROW, not just a FleetEvent and a log line" do
    expect(notify![:gate]).to eq("notify_and_proceed")

    expect(inbox_rows.count).to eq(account.users.active.count),
                                "notify_and_proceed promises the operator is TOLD"
    expect(inbox_rows.first.metadata["action_category"]).to eq("system.module_verify_investigate")
    expect(inbox_rows.first.metadata["signal_fingerprint"]).to eq("module_verify_failed:m-1")
    expect(inbox_rows.first.metadata["gate"]).to eq("notify_and_proceed")
  end

  it "bounds the inbox row to one per fingerprint per notify interval" do
    SiteSetting.set("system.fleet.signal_state.notify_interval_seconds", 3600,
                    setting_type: "integer")

    3.times { notify! }

    # Three notify_and_proceed decisions on ONE fingerprint inside one
    # interval: the operator set is told once, not three times. Unbounded, a
    # standing condition writes 144 of these a day per active user.
    expect(inbox_rows.count).to eq(account.users.active.count)
  end

  it "tells the operator again about a DIFFERENT fingerprint in the same interval" do
    notify!(fingerprint: "module_verify_failed:m-1")
    notify!(fingerprint: "module_verify_failed:m-2")

    # The limit is per condition, not per lane — otherwise the first standing
    # signal of the hour silences every other one behind it.
    expect(inbox_rows.count).to eq(account.users.active.count * 2)
  end
end
