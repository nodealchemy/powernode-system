# frozen_string_literal: true

require "rails_helper"

# IMP-d6826c872d88 — the MANUAL promote paths bypassed PromotionCriteria.
#
# Both operator-driven paths — POST
# /api/v1/system/node_module_versions/:id/promote and the MCP
# `system_promote_module_version` — could pin a plane to a version no instance
# on the rung below had ever run, and the response said nothing about it.
#
# Operator ruling D17 (2026-09-02): consult and WARN, never refuse. The manual
# paths keep their authority; what they lose is the SILENCE. This class is the
# single place that decides when the criteria are relevant, what the result
# carries, and what lands in the audit log, so the two callers cannot drift
# apart (or from the automated lane in the DecisionEngine).
#
# Environment campaign, increment 4b: "relevant" used to mean a target state on
# a decorative ladder. It now means a promotion INTO A PINNED PLANE — the one
# step where "the rung below has run this and lived" has an answer.
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

  # A version that could actually be mounted, which #ladder_refusal requires:
  # a recorded digest and an artifact clearing the publish floor.
  def usable_version(number = 1, dig = digest)
    System::NodeModuleVersion.create!(
      node_module: mod, version_number: number,
      mask: [], file_spec: [], package_spec: [], config: {},
      oci_digest: dig,
      artifacts: { "erofs" => { "oci_digest" => dig, "size" => 12_345_000 } }
    )
  end

  let(:staging) { account.environments.find_by!(slug: "staging") }
  let(:dev)     { account.environments.find_by!(slug: "dev") }
  let!(:version) { usable_version }

  # staging is the bottom pinned rung, so the version it will take is the
  # module's current one.
  before { mod.promote_to_version!(version) }

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
    it "does not consult the criteria for a FOLLOWING plane, which is never promoted into" do
      advisory = described_class.evaluate(version: version, environment: dev)

      expect(advisory.consulted?).to be false
      expect(advisory.warned?).to be false
      expect(advisory.record!(source: "spec")).to eq({})
      expect(override_events.count).to eq(0)
    end

    it "reports the criteria verdict and warns when a manual promote outruns the evidence" do
      advisory = described_class.evaluate(version: version, environment: staging)

      expect(advisory.consulted?).to be true
      expect(advisory.warned?).to be true

      fields = advisory.record!(source: "spec", actor_id: "user-1")
      expect(fields[:promotion_criteria][:eligible]).to be false
      expect(fields[:promotion_criteria][:reason]).to match(/running_count 0 < required/)
      expect(fields[:promotion_criteria_warning]).to include("staging")
      expect(fields[:promotion_criteria_warning]).to include("running_count 0 < required")
    end

    it "writes ONE auditable FleetEvent carrying the refusal reason and the actor" do
      described_class.evaluate(version: version, environment: staging)
                     .record!(source: "rest_promote", actor_id: "user-1", actor_type: "user")

      expect(override_events.count).to eq(1)
      event = override_events.first
      expect(event.severity).to eq(described_class::SEVERITY.to_s)
      expect(event.source).to eq("rest_promote")
      expect(event.node_module_id).to eq(mod.id)
      expect(event.node_module_version_id).to eq(version.id)
      expect(event.payload["environment"]).to eq("staging")
      expect(event.payload["environment_id"]).to eq(staging.id)
      expect(event.payload["reason"]).to match(/running_count 0 < required/)
      expect(event.payload["actor_id"]).to eq("user-1")
      expect(event.payload["actor_type"]).to eq("user")
      expect(event.payload["module_name"]).to eq(mod.name)
    end

    # A User id and an Ai::Agent id are both bare UUIDs and both manual paths
    # can carry either, so an actor_id ALONE does not name who overrode the
    # criteria — which is the whole deliverable here.
    it "distinguishes an agent override from a human one" do
      described_class.evaluate(version: version, environment: staging)
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
      described_class.evaluate(version: version, environment: staging)
                     .record!(source: "spec")

      payload = override_events.first.payload
      expect(payload).to have_key("actor_id")
      expect(payload["actor_id"]).to be_nil
      expect(payload["actor_type"]).to eq(described_class::UNKNOWN_ACTOR)
    end

    it "refuses to record an actor_type it does not recognise" do
      described_class.evaluate(version: version, environment: staging)
                     .record!(source: "spec", actor_id: "x", actor_type: "root")

      expect(override_events.first.payload["actor_type"]).to eq(described_class::UNKNOWN_ACTOR)
    end

    it "reports an eligible verdict without a warning or an event" do
      make_eligible!

      advisory = described_class.evaluate(version: version, environment: staging)
      expect(advisory.consulted?).to be true
      expect(advisory.warned?).to be false

      fields = advisory.record!(source: "spec")
      expect(fields[:promotion_criteria][:eligible]).to be true
      expect(fields).not_to have_key(:promotion_criteria_warning)
      expect(override_events.count).to eq(0)
    end

    it "never blocks the promotion when the audit write itself fails" do
      allow(System::Fleet::EventBroadcaster).to receive(:emit!).and_raise(StandardError, "sink down")

      advisory = described_class.evaluate(version: version, environment: staging)
      fields = nil
      expect { fields = advisory.record!(source: "spec") }.not_to raise_error
      expect(fields[:promotion_criteria][:eligible]).to be false
    end
  end

  # EQUALITY ORACLE. The advisory exists to fire on exactly the promotions the
  # ladder will accept, and a comment saying so rots the moment either side
  # changes. So this computes the set THREE ways from three independent places
  # and asserts they are the same set, over every environment in the account:
  #
  #   1. the advisory consults (this class)
  #   2. the plane is pinned  (Ai::Environment#follows_publish?, core)
  #   3. NodeModule#ladder_refusal does not reject it AS A TARGET (the ext model)
  #
  # A set widened on one side and not the others fails here. Increment 4b
  # replaced an oracle that drove the deleted ModulePromotionService over every
  # decorative target state; the shape of the check is the part worth keeping.
  describe "the set of criteria-relevant promotions matches the ladder" do
    it "consults exactly the pinned planes, over EVERY environment" do
      environments = account.environments.to_a
      expect(environments.map(&:slug)).to include("dev", "staging", "ops", "prod")

      consulted_by_advisory = environments.select do |env|
        described_class.evaluate(version: version, environment: env).consulted?
      end

      pinned = environments.reject(&:follows_publish?)

      # A version can be refused for reasons OTHER than the plane following
      # publishes (a skipped rung), so this asks only whether the plane is a
      # legal promotion TARGET at all.
      accepted_as_target = environments.reject do |env|
        mod.ladder_refusal(environment: env, version: version).to_s.include?("follows publishes")
      end

      # Non-vacuity: an oracle where every side is empty proves nothing.
      expect(consulted_by_advisory).not_to be_empty
      expect(consulted_by_advisory).to match_array(pinned)
      expect(consulted_by_advisory).to match_array(accepted_as_target)
      # And it is a STRICT subset — the following planes really are excluded.
      expect(consulted_by_advisory.size).to be < environments.size
    end
  end

  # The MCP twin. It shares the advisory with the REST path, so this pins the
  # WIRE payload an agent sees — the half a service-level spec cannot reach.
  describe "the MCP twin (system_promote_module_version)" do
    let(:tool) { Ai::Tools::SystemFleetTool.new(account: account, internal: true) }

    # HIER-P2B-ENG approval-gated this verb on core's `release.promote`
    # category, and the platform's no-row default is require_approval — so
    # with nothing seeded every call below would park (success: true,
    # data.pending) and promote nothing. An auto_approve row is the operator
    # ruling that lets the body run; the gate then replays the call through
    # Ai::Executors::DeferredToolCall as the ORIGINAL principal, which is what
    # makes the actor_type assertions below a test of the replayed identity
    # rather than of this spec's own constructor.
    before do
      Ai::InterventionPolicy.create!(
        account: account, scope: "action_type",
        action_category: Ai::Tools::SystemFleetTool::RELEASE_PROMOTE_CATEGORY,
        policy: "auto_approve", priority: 10, is_active: true
      )
    end

    def promote(environment = "staging", **rest)
      tool.execute(params: { action: "system_promote_module_version", module_id: mod.id,
                             environment: environment, version_id: version.id }.merge(rest))
    end

    it "still promotes, but carries the verdict and a warning, and audits the override" do
      r = promote

      expect(r[:success]).to be true
      expect(mod.served_version_for(staging)).to eq(version)
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
      # The permissions are REAL, not a stubbed action_permitted?: the gate
      # replays the call on a tool Ai::Executors::DeferredToolCall rebuilds
      # from the recorded principal, and a stub on this instance never reaches
      # that one — the rebuilt tool would refuse, promote nothing and audit
      # nothing, which is exactly what a stub hid here. Both the tool-level
      # REQUIRED_PERMISSION (what the replay re-asks) and the per-action
      # permission (what the door asks) are needed, as they are for a real
      # operator.
      user = create(:user, account: account,
                           permissions: [ Ai::Tools::SystemFleetTool::REQUIRED_PERMISSION, "system.modules.update" ])
      user_tool = Ai::Tools::SystemFleetTool.new(account: account, user: user)

      user_tool.execute(params: { action: "system_promote_module_version", module_id: mod.id,
                                  environment: "staging", version_id: version.id })

      event = override_events.first
      expect(event.payload["actor_type"]).to eq("user")
      expect(event.payload["actor_id"]).to eq(user.id)
    end

    it "carries an eligible verdict with no warning when the evidence is there" do
      make_eligible!

      r = promote

      expect(r[:success]).to be true
      expect(r.dig(:data, :promotion_criteria, :eligible)).to be true
      expect(r.dig(:data, :promotion_criteria, :running_count)).to eq(1)
      expect(r.dig(:data)).not_to have_key(:promotion_criteria_warning)
      expect(override_events.count).to eq(0)
    end

    it "audits nothing when the ladder refused the promotion" do
      # A version no rung below serves is a skip: refused before the pin moves,
      # so there is no override to record.
      newer = usable_version(2, "sha256:#{'c' * 64}")

      r = promote("staging", version_id: newer.id)

      expect(r[:success]).to be false
      expect(mod.served_version_for(staging)).to be_nil
      expect(override_events.count).to eq(0)
    end
  end
end
