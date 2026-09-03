# frozen_string_literal: true

require "rails_helper"

# IMP-d6826c872d88 — the MANUAL promote paths bypassed PromotionCriteria.
#
# After IMP-249aa98969bd the AUTOMATED lane (System::Fleet::ModulePromotionService,
# reached from the DecisionEngine) gates staging→blessed on real dwell and
# liveness. The two operator-driven twins — POST
# /api/v1/system/node_module_versions/:id/promote and the MCP
# `system_promote_module_version` — called NodeModuleVersion#promote_to!
# directly, so a human (or an agent over MCP) could bless a version no instance
# had ever run, and the response said nothing about it.
#
# Operator ruling D17 (2026-09-02): consult and WARN, never refuse. The manual
# paths keep their authority; what they lose is the SILENCE. This class is the
# single place that decides which target states are criteria-relevant, what the
# result carries, and what lands in the audit log, so the two callers cannot
# drift apart (or from the automated lane).
RSpec.describe System::Fleet::ManualPromotionAdvisory do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:digest)   { "sha256:#{'b' * 64}" }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "advisory-mod")
  end

  def version_in(state, number)
    System::NodeModuleVersion.create!(
      node_module: mod, version_number: number,
      mask: [], file_spec: [], package_spec: [], config: {},
      oci_digest: digest, promotion_state: state
    )
  end

  def staging_version(number = 1)
    version_in("staging", number)
  end

  let!(:version) { staging_version }

  # Makes the version genuinely eligible: the thresholds drop to a one-instance
  # fleet with no dwell (both are documented operator overrides) and one live
  # instance really is running this digest. Nothing is stubbed — the advisory
  # must report the criteria's own verdict.
  def make_eligible!
    account.update!(settings: { "module_promotion_required_count" => 1,
                                "module_promotion_dwell_minutes" => 0 })
    node = create(:system_node, account: account, node_template: template, name: "advisory-node")
    node.node_modules << mod
    create(:system_node_instance, :running, node: node).tap do |inst|
      inst.update!(running_module_digests: { mod.id => digest },
                   last_heartbeat_at: 5.seconds.ago)
    end
  end

  def override_events
    System::FleetEvent.where(account_id: account.id,
                             kind: described_class::EVENT_KIND)
  end

  describe ".evaluate" do
    it "does not consult the criteria for a target state the automated lane never gates" do
      advisory = described_class.evaluate(version: version, target_state: "retired")

      expect(advisory.consulted?).to be false
      expect(advisory.warned?).to be false
      expect(advisory.record!(source: "spec")).to eq({})
      expect(override_events.count).to eq(0)
    end

    it "reports the criteria verdict and warns when a manual promote outruns the evidence" do
      advisory = described_class.evaluate(version: version, target_state: "blessed")

      expect(advisory.consulted?).to be true
      expect(advisory.warned?).to be true

      fields = advisory.record!(source: "spec", actor_id: "user-1")
      expect(fields[:promotion_criteria][:eligible]).to be false
      expect(fields[:promotion_criteria][:reason]).to match(/running_count 0 < required/)
      expect(fields[:promotion_criteria_warning]).to include("blessed")
      expect(fields[:promotion_criteria_warning]).to include("running_count 0 < required")
    end

    it "writes ONE auditable FleetEvent carrying the refusal reason and the actor" do
      described_class.evaluate(version: version, target_state: "blessed")
                     .record!(source: "rest_promote", actor_id: "user-1", actor_type: "user")

      expect(override_events.count).to eq(1)
      event = override_events.first
      expect(event.severity).to eq(described_class::SEVERITY.to_s)
      expect(event.source).to eq("rest_promote")
      expect(event.node_module_id).to eq(mod.id)
      expect(event.node_module_version_id).to eq(version.id)
      expect(event.payload["target_state"]).to eq("blessed")
      expect(event.payload["reason"]).to match(/running_count 0 < required/)
      expect(event.payload["actor_id"]).to eq("user-1")
      expect(event.payload["actor_type"]).to eq("user")
      expect(event.payload["module_name"]).to eq(mod.name)
    end

    # A User id and an Ai::Agent id are both bare UUIDs and both manual paths
    # can carry either, so an actor_id ALONE does not name who overrode the
    # criteria — which is the whole deliverable here.
    it "distinguishes an agent override from a human one" do
      described_class.evaluate(version: version, target_state: "blessed")
                     .record!(source: "mcp_promote_module_version",
                              actor_id: "agent-1", actor_type: "agent")

      expect(override_events.first.payload["actor_type"]).to eq("agent")
    end

    # SystemFleetTool admits principals that carry NEITHER a user nor an agent
    # (internal: true, and instance principals that cleared the per-tool grant).
    # An override by one of those must still record an actor pair: the keys stay
    # present so an actor-less override reads as unknown, not as a payload that
    # predates the field.
    it "records an anonymous principal as unknown rather than dropping the keys" do
      described_class.evaluate(version: version, target_state: "blessed")
                     .record!(source: "spec")

      payload = override_events.first.payload
      expect(payload).to have_key("actor_id")
      expect(payload["actor_id"]).to be_nil
      expect(payload["actor_type"]).to eq(described_class::UNKNOWN_ACTOR)
    end

    it "refuses to record an actor_type it does not recognise" do
      described_class.evaluate(version: version, target_state: "blessed")
                     .record!(source: "spec", actor_id: "x", actor_type: "root")

      expect(override_events.first.payload["actor_type"]).to eq(described_class::UNKNOWN_ACTOR)
    end

    it "reports an eligible verdict without a warning or an event" do
      make_eligible!

      advisory = described_class.evaluate(version: version, target_state: "blessed")
      expect(advisory.consulted?).to be true
      expect(advisory.warned?).to be false

      fields = advisory.record!(source: "spec")
      expect(fields[:promotion_criteria][:eligible]).to be true
      expect(fields).not_to have_key(:promotion_criteria_warning)
      expect(override_events.count).to eq(0)
    end

    it "never blocks the promotion when the audit write itself fails" do
      allow(System::Fleet::EventBroadcaster).to receive(:emit!).and_raise(StandardError, "sink down")

      advisory = described_class.evaluate(version: version, target_state: "blessed")
      fields = nil
      expect { fields = advisory.record!(source: "spec") }.not_to raise_error
      expect(fields[:promotion_criteria][:eligible]).to be false
    end
  end

  # EQUALITY ORACLE. The advisory exists to mirror the automated lane, and a
  # comment saying so rots the moment either side changes. This drives
  # ModulePromotionService — the automated lane itself — on an ineligible
  # version and asserts that the states it REFUSES are exactly the states this
  # advisory consults on. A gated set widened on one side and not the other
  # fails here.
  #
  # Scoped to EVERY promotion state, not to the three transitions legal from
  # `staging`: "live" and "staging" are the two most likely widenings of
  # GATED_TARGET_STATES (they are exactly the rungs the constant's comment
  # reasons about excluding) and neither is reachable from `staging`, so a
  # staging-scoped oracle would pin the intersection and stay green through
  # both. Each target is driven from a source state that can legally reach it.
  describe "the gated target-state set matches the automated lane" do
    def source_state_reaching(target)
      System::NodeModuleVersion::PROMOTION_TRANSITIONS
        .find { |_source, allowed| allowed.include?(target) }&.first
    end

    it "consults exactly the states ModulePromotionService refuses on, over EVERY target state" do
      targets = System::NodeModuleVersion::PROMOTION_STATES
      number = 1

      refused_by_automated_lane = targets.select do |target|
        source = source_state_reaching(target)
        expect(source).not_to(be_nil, "no legal source state reaches #{target}; widen the oracle")

        number += 1
        candidate = version_in(source, number)
        result = System::Fleet::ModulePromotionService.promote!(version: candidate, target_state: target)
        expect(result.error.to_s).not_to include("cannot transition")

        !result.ok? && result.error.to_s.include?("not eligible")
      end

      consulted_by_advisory = targets.select do |target|
        described_class.evaluate(version: version, target_state: target).consulted?
      end

      # Non-vacuity: an oracle where both sides are empty proves nothing.
      expect(refused_by_automated_lane).to include("blessed")
      expect(consulted_by_advisory).to match_array(refused_by_automated_lane)
      expect(consulted_by_advisory).to match_array(System::Fleet::PromotionCriteria::GATED_TARGET_STATES)
    end
  end

  # The MCP twin. It shares the advisory with the REST path, so this pins the
  # WIRE payload an agent sees — the half a service-level spec cannot reach.
  describe "the MCP twin (system_promote_module_version)" do
    let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, internal: true) }

    def promote(target_state)
      tool.execute(params: { action: "system_promote_module_version",
                             module_version_id: version.id, target_state: target_state })
    end

    it "still promotes, but carries the verdict and a warning, and audits the override" do
      r = promote("blessed")

      expect(r[:success]).to be true
      expect(version.reload.promotion_state).to eq("blessed")
      expect(r.dig(:data, :promotion_criteria, :eligible)).to be false
      expect(r.dig(:data, :promotion_criteria_warning)).to match(/running_count 0 < required/)

      expect(override_events.count).to eq(1)
      event = override_events.first
      expect(event.source).to eq(described_class::MCP_SOURCE)
      # `internal: true` carries neither a user nor an agent; the tool declares
      # the principal kind rather than leaving a bare nil actor_id behind.
      expect(event.payload["actor_type"]).to eq("internal")
      expect(event.payload).to have_key("actor_id")
    end

    it "names a human principal when the MCP caller carries a user" do
      user = create(:user, account: account)
      user_tool = Ai::Tools::SystemFleetTool.new(account: account, user: user)
      allow(user_tool).to receive(:action_permitted?).and_return(true)

      user_tool.execute(params: { action: "system_promote_module_version",
                                  module_version_id: version.id, target_state: "blessed" })

      event = override_events.first
      expect(event.payload["actor_type"]).to eq("user")
      expect(event.payload["actor_id"]).to eq(user.id)
    end

    it "carries an eligible verdict with no warning when the evidence is there" do
      make_eligible!

      r = promote("blessed")

      expect(r[:success]).to be true
      expect(r.dig(:data, :promotion_criteria, :eligible)).to be true
      expect(r.dig(:data, :promotion_criteria, :running_count)).to eq(1)
      expect(r.dig(:data)).not_to have_key(:promotion_criteria_warning)
      expect(override_events.count).to eq(0)
    end

    it "leaves an ungated target state (retired) with no verdict and no event" do
      r = promote("retired")

      expect(r[:success]).to be true
      expect(version.reload.promotion_state).to eq("retired")
      expect(r.dig(:data)).not_to have_key(:promotion_criteria)
      expect(override_events.count).to eq(0)
    end

    it "audits nothing when the transition itself was refused" do
      version.update!(promotion_state: "built")

      r = promote("blessed")

      expect(r[:success]).to be false
      expect(version.reload.promotion_state).to eq("built")
      expect(override_events.count).to eq(0)
    end
  end
end
