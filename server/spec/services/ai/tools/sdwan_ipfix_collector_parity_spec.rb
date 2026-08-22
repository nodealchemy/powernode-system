# frozen_string_literal: true

require "rails_helper"

# IMP-6bbe5c673c38 — the IPFIX collector verbs were split across two
# surfaces with no overlap in the middle:
#
#   REST  (ipfix_collectors_controller) — index, show, update, destroy
#   MCP   (Ai::Tools::SdwanTool)        — create, list, delete
#
# The consequence is not cosmetic. `update` is the ONLY non-destructive way
# to take a collector out of service, and it lived only on REST. An agent
# holding SdwanTool that needed to stop a mis-sampling collector exporting
# had exactly one reachable verb: delete. And deleting is not the same act —
# Sdwan::IpfixCollector `has_many :flow_samples, dependent: :destroy`, with
# `on_delete: :cascade` on the FK underneath it (20250101000009_system_baseline),
# so the destructive substitute also erases every flow sample recorded
# against that collector. The correlation history the fleet sensors read
# (System::Fleet::Sensors::SdwanServiceHealthSensor) goes with it.
#
# The first example below is a CHARACTERIZATION of that cascade, not a
# wish: it exists so the reason the toggle must be reachable stays pinned
# even if someone later changes the association.
#
# Gate treatment follows the regime IMP-97c7b4123d8f established for this
# family — an Sdwan::Executors class owning the write, its ACTION_CATEGORY
# as the single declaration site, registration in the engine's autonomy
# category list and a seeded policy row. The tier follows that task's own
# stated rule for this family: "creates and state transitions notify,
# deletes require approval" — so ipfix_collector_update takes
# notify_and_proceed, the tier host_bridge_update already carries for the
# structurally identical activate arm. Filling parity WITHOUT that
# treatment would add a new agent-reachable mutating verb with no
# configurable authorization, which is worse than the destructive
# substitute it replaces.
RSpec.describe "SdwanTool IPFIX collector verb parity (IMP-6bbe5c673c38)" do
  let(:account) { create(:account) }
  let(:tool)    { Ai::Tools::SdwanTool.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  # Forces the gate's :proceed branch. The default policy resolution is
  # require_approval, so nothing else exercises the inline path.
  def auto_approve_policy!
    allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
      { policy: "auto_approve", channels: [], conditions: {}, record: nil }
    )
  end

  # Fetch helpers are `def`, not `let`: every one of them is a probe of
  # CURRENT database state, and a memoized probe that answered before the
  # arm ran would make the oracle below assert nothing.
  def reloaded(collector)
    ::Sdwan::IpfixCollector.find_by(id: collector.id)
  end

  def sample_count(collector)
    ::Sdwan::FlowSample.where(ipfix_collector_id: collector.id).count
  end

  def approve!(response)
    deferred = Ai::DeferredOperation.find_by(id: response.dig(:data, :deferred_operation_id))
    expect(deferred).to be_present, "no deferred operation was parked: #{response.inspect}"
    deferred.execute_now!
    deferred
  end

  def collector_with_samples(state: "active", **attrs)
    collector = create(:sdwan_ipfix_collector, account: account, state: state, **attrs)
    create_list(:sdwan_flow_sample, 2, account: account, ipfix_collector: collector)
    collector
  end

  # ─── The severity claim, pinned ────────────────────────────────────────

  describe "the destructive substitute" do
    it "cascades the collector's flow samples, which is why delete is not a stand-in for disable" do
      auto_approve_policy!
      collector = collector_with_samples
      expect(sample_count(collector)).to eq(2)

      r = call("system_sdwan_delete_ipfix_collector", collector_id: collector.id)

      expect(r[:success]).to be true
      expect(reloaded(collector)).to be_nil
      expect(sample_count(collector)).to eq(0),
                                         "delete no longer cascades flow_samples — re-read this file's premise"
    end
  end

  # ─── The missing state toggle (priority arm) ───────────────────────────

  describe "system_sdwan_update_ipfix_collector" do
    it "is advertised on the tool" do
      expect(Ai::Tools::SdwanTool.action_definitions.keys)
        .to include("system_sdwan_update_ipfix_collector")
    end

    it "carries the family's manage permission" do
      permissions = Ai::Tools::SdwanTool.const_get(:ACTION_PERMISSIONS)
      expect(permissions["system_sdwan_update_ipfix_collector"]).to eq("system.sdwan.ipfix.manage")
    end

    it "is wired to SdwanTool in the platform tool registry" do
      expect(::Ai::Tools::PlatformApiToolRegistry::TOOLS["system_sdwan_update_ipfix_collector"])
        .to eq("Ai::Tools::SdwanTool")
    end

    it "declares its action category on an executor, and that category is registered" do
      category = ::Sdwan::Executors::UpdateIpfixCollector::ACTION_CATEGORY
      expect(category).to eq("sdwan.ipfix_collector_update")
      expect(::Ai::InterventionPolicy.category_registered?(category)).to be(true),
                                                                     "the category is not registered — an operator cannot tune a tier for it"
    end

    # THE ORACLE. "update returned 200" is satisfied by an implementation
    # that destroys the row and creates a replacement — which would take
    # the flow samples with it and defeat the entire point of the verb.
    # What has to be true is that THIS row transitioned and its samples
    # survived.
    it "transitions the row in place — the collector survives and its flow samples are intact" do
      auto_approve_policy!
      collector = collector_with_samples(state: "active")

      r = call("system_sdwan_update_ipfix_collector", collector_id: collector.id, state: "disabled")

      expect(r[:success]).to be true
      expect(r.dig(:data, :ipfix_collector, :state)).to eq("disabled")

      survivor = reloaded(collector)
      expect(survivor).to be_present,
                          "the toggle did not transition the row — it destroyed it (or replaced it with a new id)"
      expect(survivor.state).to eq("disabled")
      expect(sample_count(collector)).to eq(2),
                                         "the toggle cascaded flow_samples — it destroyed rather than updated"
    end

    it "re-enables a disabled collector in place" do
      auto_approve_policy!
      collector = collector_with_samples(state: "disabled")

      r = call("system_sdwan_update_ipfix_collector", collector_id: collector.id, state: "active")

      expect(r[:success]).to be true
      expect(reloaded(collector).state).to eq("active")
      expect(sample_count(collector)).to eq(2)
    end

    it "parks instead of transitioning when the account's tier requires approval" do
      collector = collector_with_samples(state: "active")

      r = call("system_sdwan_update_ipfix_collector", collector_id: collector.id, state: "disabled")

      expect(r[:success]).to be true
      expect(r.dig(:data, :pending)).to be(true),
                                        "the arm wrote inline instead of parking: #{r.inspect}"
      expect(reloaded(collector).state).to eq("active"),
                                           "the arm transitioned the row and reported pending afterwards"
    end

    it "applies the transition when the parked operation is approved, still without cascading" do
      collector = collector_with_samples(state: "active")

      deferred = approve!(call("system_sdwan_update_ipfix_collector",
                               collector_id: collector.id, state: "disabled"))

      expect(deferred.action_category).to eq("sdwan.ipfix_collector_update")
      expect(deferred.executor_class).to eq("Sdwan::Executors::UpdateIpfixCollector")
      expect(reloaded(collector).state).to eq("disabled")
      expect(sample_count(collector)).to eq(2)
    end

    # VALIDATE BEFORE THE GATE (the IMP-97c7b4123d8f contract): a request
    # that could only ever fail must fail now, not sit in an operator's
    # queue until they approve it and watch it fail.
    it "refuses an unknown state without parking anything" do
      collector = create(:sdwan_ipfix_collector, account: account, state: "active")

      expect {
        @result = call("system_sdwan_update_ipfix_collector", collector_id: collector.id, state: "paused")
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
      expect(@result[:error].to_s).to match(/active/i).and match(/disabled/i)
      expect(reloaded(collector).state).to eq("active")
    end

    it "refuses a missing state without parking anything" do
      collector = create(:sdwan_ipfix_collector, account: account, state: "active")

      expect {
        @result = call("system_sdwan_update_ipfix_collector", collector_id: collector.id)
      }.not_to change(Ai::DeferredOperation, :count)

      expect(@result[:success]).to be false
    end

    it "does not reach a collector belonging to another account" do
      foreign = create(:sdwan_ipfix_collector, account: create(:account), state: "active")

      r = call("system_sdwan_update_ipfix_collector", collector_id: foreign.id, state: "disabled")

      expect(r[:success]).to be false
      expect(foreign.reload.state).to eq("active")
    end
  end

  # ─── The missing single-row read ───────────────────────────────────────

  describe "system_sdwan_get_ipfix_collector" do
    it "is advertised on the tool and carries the family's read permission" do
      expect(Ai::Tools::SdwanTool.action_definitions.keys)
        .to include("system_sdwan_get_ipfix_collector")
      permissions = Ai::Tools::SdwanTool.const_get(:ACTION_PERMISSIONS)
      expect(permissions["system_sdwan_get_ipfix_collector"]).to eq("system.sdwan.ipfix.read")
    end

    it "is wired to SdwanTool in the platform tool registry" do
      expect(::Ai::Tools::PlatformApiToolRegistry::TOOLS["system_sdwan_get_ipfix_collector"])
        .to eq("Ai::Tools::SdwanTool")
    end

    it "returns the row, and does not write" do
      collector = collector_with_samples(state: "active")

      r = call("system_sdwan_get_ipfix_collector", collector_id: collector.id)

      expect(r[:success]).to be true
      expect(r.dig(:data, :ipfix_collector, :id)).to eq(collector.id)
      expect(r.dig(:data, :ipfix_collector, :state)).to eq("active")
      expect(reloaded(collector)).to be_present
      expect(sample_count(collector)).to eq(2)
    end

    # The compiler stamps ONE collector onto the OVS bridges — the account's
    # oldest active row — so "which of my collectors is actually exporting"
    # is the question this verb has to be able to answer. REST #show already
    # answers it (is_winning_collector); an agent could not ask at all.
    it "reports whether this collector is the one the compiler will stamp" do
      winner = create(:sdwan_ipfix_collector, account: account, state: "active",
                                              created_at: 2.hours.ago)
      loser  = create(:sdwan_ipfix_collector, account: account, state: "active",
                                              created_at: 1.hour.ago)

      expect(call("system_sdwan_get_ipfix_collector", collector_id: winner.id)
               .dig(:data, :ipfix_collector, :is_winning_collector)).to be(true)
      expect(call("system_sdwan_get_ipfix_collector", collector_id: loser.id)
               .dig(:data, :ipfix_collector, :is_winning_collector)).to be(false)
    end

    it "does not disclose a collector belonging to another account" do
      foreign = create(:sdwan_ipfix_collector, account: create(:account))

      r = call("system_sdwan_get_ipfix_collector", collector_id: foreign.id)

      expect(r[:success]).to be false
    end
  end
end
