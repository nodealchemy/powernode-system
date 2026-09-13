# frozen_string_literal: true

require "rails_helper"

# IMP-79e075dc73a0 — "what is running" in one call.
#
# system_list_instances took node_id, template_id and environment only. A
# fleet whose newest rows are ephemeral CI builders (most of them terminated)
# pushed every long-lived instance off the first page, so an operator or agent
# asking "what is running" or "what is in error" had to page the whole table
# and filter client-side.
#
# The filter is a status (one or a list) plus a `live_only` convenience. Like
# the environment filter, a value that cannot be honoured is REFUSED rather
# than dropped: a dropped filter answers "what is in error" with the whole
# fleet. The unfiltered default is unchanged.
#
# Each row also stops presenting `status` as a bare fact: it names the
# platform's recorded lifecycle state as such, and carries what was actually
# observed beside it, with when and on what basis.
RSpec.describe Ai::Tools::SystemFleetTool, "system_list_instances status filter" do
  let(:account)   { create(:account) }
  let!(:operator) { create(:user, account: account, permissions: %w[system.node_instances.read]) }
  let(:agent)     { create(:ai_agent, account: account, agent_type: "monitor", name: "Fleet Reader") }
  let(:tool)      { described_class.new(account: account, agent: agent, internal: true) }
  let(:node)      { create(:system_node, account: account) }

  let!(:running)    { create(:system_node_instance, node: node, status: "running") }
  let!(:stopped)    { create(:system_node_instance, node: node, status: "stopped") }
  let!(:errored)    { create(:system_node_instance, node: node, status: "error") }
  let!(:terminated) { create(:system_node_instance, node: node, status: "terminated") }

  def call(**rest)
    tool.execute(params: { action: "system_list_instances" }.merge(rest).with_indifferent_access)
  end

  def ids(result)
    result.dig(:data, :instances).map { |i| i[:id] }
  end

  it "declares the status and live_only parameters" do
    params = described_class.action_definitions.dig("system_list_instances", :parameters)
    expect(params).to include(:status, :live_only)
  end

  it "leaves the unfiltered answer whole" do
    r = call
    expect(r[:success]).to be true
    expect(ids(r)).to contain_exactly(running.id, stopped.id, errored.id, terminated.id)
  end

  it "narrows to one status, and count reports the narrowed total" do
    r = call(status: "error")
    expect(r[:success]).to be(true), r.inspect
    expect(ids(r)).to contain_exactly(errored.id)
    expect(r.dig(:data, :count)).to eq(1)
  end

  it "narrows to a list of statuses" do
    r = call(status: %w[running error])
    expect(r[:success]).to be(true), r.inspect
    expect(ids(r)).to contain_exactly(running.id, errored.id)
  end

  it "refuses an unknown status instead of ignoring the filter" do
    r = call(status: %w[running exploded])
    expect(r[:success]).to be false
    expect(r[:error]).to match(/exploded/)
    expect(r[:error]).to include("terminated")
    expect(r.dig(:data, :instances)).to be_nil
  end

  it "live_only keeps the statuses the control plane still counts on and drops terminated and error" do
    r = call(live_only: true)
    expect(r[:success]).to be(true), r.inspect
    expect(ids(r)).to contain_exactly(running.id, stopped.id)
    expect(r.dig(:data, :count)).to eq(2)
  end

  it "live_only false is no filter" do
    expect(ids(call(live_only: false))).to contain_exactly(running.id, stopped.id, errored.id, terminated.id)
  end

  it "live_only with a live status is the intersection" do
    r = call(live_only: true, status: %w[running stopped])
    expect(ids(r)).to contain_exactly(running.id, stopped.id)
  end

  # An empty page here would read as "nothing is terminated".
  it "refuses live_only together with a status outside the live set" do
    r = call(live_only: true, status: "terminated")
    expect(r[:success]).to be false
    expect(r[:error]).to match(/terminated/)
    expect(r.dig(:data, :instances)).to be_nil
  end

  describe "row shape — no bare status" do
    def row_for(result, instance)
      result.dig(:data, :instances).find { |i| i[:id] == instance.id }
    end

    it "names the recorded state as the lifecycle status" do
      expect(row_for(call, errored)[:lifecycle_status]).to eq("error")
    end

    it "reports an instance nothing has observed as not_measured, with no observed_at" do
      observed = row_for(call, running)[:observed]
      expect(observed).to include(basis: "not_measured", observed_at: nil,
                                  agent_heartbeat_at: nil, provider_power_state: nil)
    end

    it "carries the heartbeat as a measurement dated by the heartbeat, not by the call" do
      beat = 3.days.ago.change(usec: 0)
      running.update_columns(last_heartbeat_at: beat)

      observed = row_for(call, running)[:observed]
      expect(observed[:basis]).to eq("measured")
      expect(observed[:agent_heartbeat_at]).to eq(beat.iso8601)
      expect(observed[:observed_at]).to eq(beat.iso8601)
    end

    it "dates observed_at by the most recent of the two observers" do
      beat = 5.days.ago.change(usec: 0)
      power_at = 1.day.ago.change(usec: 0)
      stopped.update_columns(last_heartbeat_at: beat, provider_power_state: "stopped",
                             provider_power_state_at: power_at)

      observed = row_for(call, stopped)[:observed]
      expect(observed).to include(basis: "measured", provider_power_state: "stopped",
                                  provider_power_state_at: power_at.iso8601,
                                  observed_at: power_at.iso8601)
    end
  end
end
