# frozen_string_literal: true

require "rails_helper"

# N4 (review round 11, IMP-caef5c00d63f) — the CONSUMER half of the
# pending-upgrade-digest oracle. System::PendingModuleDigestsWriter persists
# the agent's PendingModuleDigests heartbeat lane, and this sensor is what
# makes a module stuck retrying the same upgrade digest reach a person —
# mirroring SecurityFailClosedSensor's own justification for its lane.
RSpec.describe System::Fleet::Sensors::PendingDigestStuckSensor do
  let(:account) { create(:account) }
  let(:node)    { create(:system_node, account: account) }

  subject(:signals) { described_class.new(account: account).sense }

  def signal = signals.find { |s| s[:kind] == "system.node_pending_digest_stuck" }

  def instance!(heartbeat_at: 1.minute.ago, status: "running", **attrs)
    create(:system_node_instance, node: node, status: status,
                                  last_heartbeat_at: heartbeat_at, **attrs)
  end

  # Writes the REAL writer's document shape directly (bypassing write!'s own
  # merge logic) so a test can pin an exact first_seen_at without racing
  # Time.current.
  def record!(instance, modules)
    instance.update!(config: instance.config.merge(
      System::PendingModuleDigestsWriter::CONFIG_KEY => {
        "observed_at" => Time.current.utc.iso8601,
        "modules" => modules
      }
    ))
  end

  describe "the quiet direction" do
    it "emits NOTHING for a node with no pending_module_digests document at all" do
      instance!

      expect(signals).to eq([])
    end

    it "emits NOTHING for a node whose document has an empty modules map" do
      record!(instance!, {})

      expect(signals).to eq([])
    end

    it "emits NOTHING for a module pending for LESS than the stuck threshold" do
      record!(instance!, "m1" => { "digest" => "d2", "first_seen_at" => 1.minute.ago.utc.iso8601 })

      expect(signals).to eq([])
    end

    it "emits NOTHING for a module with a missing first_seen_at (unmeasured, not stuck)" do
      record!(instance!, "m1" => { "digest" => "d2" })

      expect(signals).to eq([])
    end
  end

  describe "the alarm direction" do
    it "fires for a module pending PAST the stuck threshold" do
      record!(instance!, "m1" => { "digest" => "d2", "first_seen_at" => 20.minutes.ago.utc.iso8601 })

      expect(signal).not_to be_nil
      expect(signal[:severity]).to eq(:high)
      expect(signal.dig(:payload, "instances", 0, "modules", "m1", "digest")).to eq("d2")
    end

    it "aggregates into ONE signal per account, not one per instance" do
      record!(instance!, "m1" => { "digest" => "d2", "first_seen_at" => 20.minutes.ago.utc.iso8601 })
      record!(instance!, "m2" => { "digest" => "d3", "first_seen_at" => 20.minutes.ago.utc.iso8601 })

      matching = signals.select { |s| s[:kind] == "system.node_pending_digest_stuck" }
      expect(matching.size).to eq(1)
      expect(signal.dig(:payload, "instance_count")).to eq(2)
    end

    it "does not alarm on a silent (non-heartbeating) instance" do
      record!(instance!(heartbeat_at: 1.hour.ago), "m1" => { "digest" => "d2", "first_seen_at" => 20.minutes.ago.utc.iso8601 })

      expect(signals).to eq([])
    end

    it "does not alarm on a non-running instance" do
      record!(instance!(status: "stopped"), "m1" => { "digest" => "d2", "first_seen_at" => 20.minutes.ago.utc.iso8601 })

      expect(signals).to eq([])
    end

    it "uses a per-account fingerprint, not per-instance or per-module" do
      record!(instance!, "m1" => { "digest" => "d2", "first_seen_at" => 20.minutes.ago.utc.iso8601 })

      expect(signal[:fingerprint]).to eq("node_pending_digest_stuck:#{account.id}")
    end

    it "does NOT include another account's instance" do
      record!(instance!, "own-module" => { "digest" => "d2", "first_seen_at" => 20.minutes.ago.utc.iso8601 })

      other_account = create(:account)
      other_node = create(:system_node, account: other_account)
      other_instance = create(:system_node_instance, node: other_node, status: "running", last_heartbeat_at: 1.minute.ago)
      other_instance.update!(config: other_instance.config.merge(
        System::PendingModuleDigestsWriter::CONFIG_KEY => {
          "modules" => { "other-module" => { "digest" => "d9", "first_seen_at" => 20.minutes.ago.utc.iso8601 } }
        }
      ))

      expect(signal.dig(:payload, "instance_count")).to eq(1)
      names = signal.dig(:payload, "instances").flat_map { |i| i["modules"].keys }
      expect(names).to eq(%w[own-module])
    end

    # mirrors SecurityFailClosedSensor's own "clears once no longer reported"
    # test — proven through the REAL writer, not the raw record! helper, so
    # this also pins PendingModuleDigestsWriter's own drop-on-resolve rule as
    # the mechanism that makes recovery visible here.
    it "clears once a later heartbeat no longer reports the module (resolved, via the real writer)" do
      sense = -> { described_class.new(account: account).sense }

      stuck = instance!
      # Seed a stale first_seen_at directly (the writer would stamp "now" on
      # a fresh entry), then confirm a heartbeat reporting the SAME digest
      # carries that first_seen_at forward rather than resetting it.
      record!(stuck, "m1" => { "digest" => "d2", "first_seen_at" => 20.minutes.ago.utc.iso8601 })
      System::PendingModuleDigestsWriter.write!(instance: stuck, payload: { "pending_module_digests" => { "m1" => "d2" } })
      stuck.reload
      expect(sense.call.find { |s| s[:kind] == "system.node_pending_digest_stuck" }).not_to be_nil

      # The module commits (or reverts) — the NEXT heartbeat no longer names it.
      System::PendingModuleDigestsWriter.write!(instance: stuck, payload: { "pending_module_digests" => {} })

      expect(sense.call).to eq([])
    end

    it "resets first_seen_at when the pending digest CHANGES (a revert or re-target, N2)" do
      changed = instance!
      record!(changed, "m1" => { "digest" => "d2", "first_seen_at" => 20.minutes.ago.utc.iso8601 })

      # Reverted to d1 — a DIFFERENT digest than what was pending; must not
      # inherit d2's stale first_seen_at.
      System::PendingModuleDigestsWriter.write!(instance: changed, payload: { "pending_module_digests" => { "m1" => "d1" } })

      expect(signals).to eq([])
    end
  end

  describe "the wiring" do
    it "has a DecisionEngine binding" do
      expect(System::Fleet::DecisionEngine::SIGNAL_BINDINGS).to have_key("system.node_pending_digest_stuck")
    end

    it "has NO applier — skill is nil" do
      expect(System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.node_pending_digest_stuck"][:skill]).to be_nil
    end

    it "is declared non-remediating (no false fleet.remediation_stuck)" do
      category = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.node_pending_digest_stuck"][:action_category]
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES).to include(category)
    end

    it "resolves to notify_and_proceed, never auto_approve" do
      category = System::Fleet::DecisionEngine::SIGNAL_BINDINGS["system.node_pending_digest_stuck"][:action_category]
      expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES[category]).to eq("notify_and_proceed")
    end
  end
end
