# frozen_string_literal: true

require "rails_helper"

# IMP-a8f9fa74284d — the CONSUMER half of the boot/LKG ARM oracle.
#
# System::BootLkgStateWriter has written `arm_state` into
# System::NodeInstance#config on every heartbeat since IMP-b8d5cfa33b79, and
# Ai::Tools::SystemFleetTool exposes it over MCP. Nothing ASKED. The platform
# could answer "is this node armed?" while the question an operator actually
# faces — before pulling a control plane — was still answered by the absence of
# an alarm.
#
# Three claims this file pins hardest, and the first is the whole feature:
#
#   1. ABSENCE ALARMS. Every boot/LKG field on the wire is Go `omitempty`, so a
#      *false* value is never transmitted: absence IS the normal wire state for
#      an un-armed node. A consumer that reads "unreported" as "probably fine"
#      turns this into the green light it exists to prevent. The oracle
#      therefore runs in BOTH directions — armed proceeds, unreported alarms —
#      and the no-document-at-all case is asserted explicitly, because that is
#      the case a real un-armed node produces.
#   2. THE LANE REACHES A PERSON. A sensor emitting a kind with no
#      DecisionEngine::SIGNAL_BINDINGS entry terminates as `decision: skipped`
#      and routes nowhere. The wiring block is as load-bearing as the sensing.
#   3. NO APPLIER, DECLARED. Nothing can re-arm a node automatically, so the
#      category is notify-only AND is declared non-remediating — otherwise its
#      standing fingerprint manufactures a false fleet.remediation_stuck.
RSpec.describe System::Fleet::Sensors::BootLkgArmSensor do
  let(:account) { create(:account) }
  let(:node)    { create(:system_node, account: account) }

  subject(:signals) { described_class.new(account: account).sense }

  def unarmed = signals.find { |s| s[:kind] == "system.node_lkg_unarmed" }
  def stale   = signals.find { |s| s[:kind] == "system.node_lkg_stale" }

  # A LIVE, running instance — the population the decommission question applies
  # to. A silent node is InstanceStatusSensor's alarm; a second one here would
  # be two sensors firing on one cause.
  def instance!(heartbeat_at: 1.minute.ago, status: "running", **attrs)
    create(:system_node_instance, node: node, status: status,
                                  last_heartbeat_at: heartbeat_at, **attrs)
  end

  # Writes the document exactly as BootLkgStateWriter shapes it.
  def record!(instance, observed_at: Time.current, **doc)
    instance.update!(config: instance.config.merge(
      System::BootLkgStateWriter::CONFIG_KEY => {
        "observed_at" => observed_at.utc.iso8601
      }.merge(doc.transform_keys(&:to_s))
    ))
  end

  def armed!(instance, confirmed_at: 1.day.ago, **doc)
    record!(instance,
            "arm_state" => System::BootLkgStateWriter::ARMED,
            "lkg_present" => true,
            "lkg_confirmed_at" => confirmed_at&.utc&.iso8601,
            **doc)
  end

  describe "the armed direction — a reporting, armed node is silent" do
    it "emits NOTHING for a node that reported an explicit lkg_present" do
      armed!(instance!)

      expect(signals).to eq([])
    end

    it "does not alarm merely because other boot facts are absent" do
      # Only lkg_present is load-bearing for the arm question. A node that
      # reported it and nothing else is armed.
      record!(instance!,
              "arm_state" => System::BootLkgStateWriter::ARMED,
              "lkg_present" => true,
              "lkg_confirmed_at" => 1.hour.ago.utc.iso8601,
              "booted_from_lkg" => nil,
              "lkg_module_count" => nil)

      expect(signals).to eq([])
    end
  end

  describe "the unreported direction — absence BLOCKS" do
    # THE CASE THAT MATTERS MOST. `omitempty` means an un-armed node transmits
    # nothing at all, so no document is the SHAPE a real un-armed node takes.
    # If this passes silently the whole feature is inverted.
    it "alarms on a live node with NO boot_lkg document at all" do
      instance!

      expect(unarmed).to be_present
      expect(unarmed[:payload]["reasons"]).to eq({ "never_reported" => 1 })
    end

    it "alarms on an explicit arm_state of unreported" do
      record!(instance!, "arm_state" => System::BootLkgStateWriter::UNREPORTED,
                         "lkg_present" => nil)

      expect(unarmed).to be_present
      expect(unarmed[:payload]["reasons"]).to eq({ "unreported" => 1 })
    end

    # A document old enough that it no longer describes the node cannot assert
    # the node is armed NOW. Rewriting happens on every heartbeat once a
    # document exists, so a frozen one means the lane stopped.
    it "alarms when the document is too stale to describe the node" do
      armed!(instance!, observed_at: 3.hours.ago)

      expect(unarmed).to be_present
      expect(unarmed[:payload]["reasons"]).to eq({ "stale_report" => 1 })
    end

    # Neither "armed" nor "unreported" — a document from some other writer, or
    # a hand-edited config. Anything that is not an explicit ARMED is unarmed.
    it "alarms on an arm_state it does not recognise" do
      record!(instance!, "arm_state" => "probably_fine", "lkg_present" => true)

      expect(unarmed).to be_present
      expect(unarmed[:payload]["reasons"]).to eq({ "arm_state_unrecognized" => 1 })
    end

    it "carries high severity and names the offending instances" do
      inst = instance!

      expect(unarmed[:severity]).to eq(:high)
      named = unarmed[:payload]["instances"]
      expect(named.map { |i| i["instance_id"] }).to eq([ inst.id ])
      expect(named.first["reason"]).to eq("never_reported")
    end

    # There is no applier and can be none, so the payload must never suggest one.
    it "names no remediation action" do
      instance!

      expect(unarmed[:payload]).to have_key("remediation_action")
      expect(unarmed[:payload]["remediation_action"]).to be_nil
    end
  end

  describe "aggregation" do
    it "emits ONE signal for the whole un-armed set, not one per instance" do
      3.times { instance! }

      expect(signals.select { |s| s[:kind] == "system.node_lkg_unarmed" }.size).to eq(1)
      expect(unarmed[:payload]["instance_count"]).to eq(3)
    end

    # A fingerprint that moved with the count would mint a fresh signal every
    # tick and could never dedup as a standing condition.
    it "keeps the fingerprint stable as the set grows" do
      instance!
      first = described_class.new(account: account).sense.first[:fingerprint]
      2.times { instance! }
      second = described_class.new(account: account).sense.first[:fingerprint]

      expect(second).to eq(first)
    end

    it "truncates the named sample but still reports the full count" do
      stub_const("#{described_class}::MAX_NAMED_INSTANCES", 2)
      3.times { instance! }

      expect(unarmed[:payload]["instances"].size).to eq(2)
      expect(unarmed[:payload]["instance_count"]).to eq(3)
      expect(unarmed[:payload]["truncated"]).to be(true)
    end

    # Reports "at least N", never a total it never finished counting.
    it "marks the count a FLOOR when the sweep hit its cap" do
      stub_const("#{described_class}::MAX_TRACKED_PER_TICK", 2)
      3.times { instance! }

      expect(unarmed[:payload]["count_is_floor"]).to be(true)
      expect(unarmed[:payload]["summary"]).to include("at least")
    end
  end

  describe "scope" do
    it "ignores an instance that is not heartbeating (InstanceStatusSensor's alarm)" do
      instance!(heartbeat_at: 2.days.ago)

      expect(signals).to eq([])
    end

    it "ignores an instance that is not running" do
      instance!(status: "stopped")

      expect(signals).to eq([])
    end

    it "ignores another account's un-armed instance" do
      other_node = create(:system_node, account: create(:account))
      create(:system_node_instance, node: other_node, status: "running",
                                    last_heartbeat_at: 1.minute.ago)

      expect(signals).to eq([])
    end
  end

  describe "stale LKG — armed, but the confirmation has aged out" do
    it "is silent for a recently confirmed LKG" do
      armed!(instance!, confirmed_at: 1.day.ago)

      expect(stale).to be_nil
    end

    it "alarms when the LKG confirmation is older than the window" do
      armed!(instance!, confirmed_at: 90.days.ago)

      expect(stale).to be_present
      expect(stale[:severity]).to eq(:medium)
      expect(stale[:payload]["reasons"]).to eq({ "confirmation_aged" => 1 })
    end

    # Same doctrine one level down: an armed node that never said WHEN its LKG
    # was confirmed has not asserted freshness, and absence is not freshness.
    it "alarms when an armed node reports no confirmation time" do
      armed!(instance!, confirmed_at: nil)

      expect(stale).to be_present
      expect(stale[:payload]["reasons"]).to eq({ "unconfirmed" => 1 })
    end

    it "never double-counts an instance as both unarmed and stale" do
      instance!

      expect(unarmed).to be_present
      expect(stale).to be_nil
    end
  end

  describe "thresholds are DB-driven" do
    it "honours a per-account staleness override" do
      account.update!(settings: { "boot_lkg_stale_seconds" => 3600 })
      armed!(instance!, confirmed_at: 2.hours.ago)

      expect(stale).to be_present
    end

    it "honours a per-account document-freshness override" do
      account.update!(settings: { "boot_lkg_report_fresh_seconds" => 60 })
      armed!(instance!, observed_at: 5.minutes.ago)

      expect(unarmed[:payload]["reasons"]).to eq({ "stale_report" => 1 })
    end
  end

  # A producer with no consumer is the half-lane shape this campaign exists to
  # stop; a consumer with no BINDING is the same defect one hop later.
  describe "wiring" do
    it "runs in the sense pass that gates as Fleet Autonomy" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end

    # Asserted against the CONSTANT, so an unbound kind fails here rather than
    # terminating as `decision: skipped` in production.
    it "routes both kinds to the notify-level investigate category" do
      bindings = System::Fleet::DecisionEngine::SIGNAL_BINDINGS

      %w[system.node_lkg_unarmed system.node_lkg_stale].each do |kind|
        expect(bindings).to have_key(kind)
        expect(bindings[kind][:action_category]).to eq("system.node_lkg_investigate")
        # No applier exists and none can: nothing re-arms a node. Borrowing a
        # nearby side-effectful executor to fill this slot is worse than an
        # unbound lane (IMP-df40782d3f4d).
        expect(bindings[kind][:skill]).to be_nil
      end
    end

    it "is reachable — every kind the sensor can emit is bound" do
      armed!(instance!, confirmed_at: 90.days.ago)
      instance!

      emitted = described_class.new(account: account).sense.map { |s| s[:kind] }
      expect(emitted).not_to be_empty
      expect(emitted.uniq).to all(satisfy { |k| System::Fleet::DecisionEngine::SIGNAL_BINDINGS.key?(k) })
    end

    # NOT system.observation: the fleet seed maps that to auto_approve, which
    # files the signal for a dashboard and reaches NO operator.
    #
    # Asserted against PolicyDeclarations, not seed text: the declared sets
    # moved out of the seed files so PolicyReconciler could assert them against
    # a running database, and that constant is now the authority the seed, the
    # reconciler and the engine's category registry all read.
    it "declares the gate policy on the agent that runs the sense pass" do
      expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES)
        .to include("system.node_lkg_investigate" => "notify_and_proceed")
    end

    it "registers the category so an operator can retune it" do
      expect(Ai::InterventionPolicy.category_registered?("system.node_lkg_investigate")).to be(true)
    end

    # Membership is DECLARED, never inferred. Without it the standing
    # fingerprint of a fleet that has not been re-armed scores ineffective every
    # settle window until the F3-11 streak manufactures a false
    # fleet.remediation_stuck HIGH escalation on a lane that never actuated.
    it "is declared non-remediating so it stays out of the validate arc" do
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.node_lkg_investigate")
    end
  end
end
