# frozen_string_literal: true

require "rails_helper"

# IMP-e744d96da817 — two things IMP-190834701b0a left undone:
#   (b) a host key that CHANGED with no reboot between is the impersonation or
#       tamper shape, and was only audited and put on a feed: nothing paged a person;
#   (a) nothing measured how much of the fleet has reported a key, so the rollout
#       instruction ("verify coverage, then flip system.ssh.require_host_key") had
#       no tool behind it.
RSpec.describe System::Fleet::Sensors::SshHostKeySensor do
  let(:account) { create(:account) }
  let(:sensor)  { described_class.new(account: account) }

  let(:key) { SshHostKeyFixtures.entry("ssh-ed25519") }

  def instance_for(acct, status: "running", created: 2.hours.ago, keys: nil)
    inst = status == "running" ? create(:system_node_instance, :running, account: acct) : create(:system_node_instance, account: acct, status: status)
    inst.update_columns(created_at: created, ssh_host_keys: keys && { "keys" => keys, "boot_id" => "b1" })
    inst
  end

  def changed_event(inst, boot_id_changed:, at: 1.minute.ago, account: self.account, kind: System::SshHostKeyWriter::CHANGED_EVENT_KIND)
    create(:system_fleet_event, account: account, kind: kind, severity: boot_id_changed ? "medium" : "high",
           source: "system/ssh_host_key_writer", node_instance_id: inst.id, emitted_at: at,
           payload: { "previous_fingerprints" => [ "SHA256:old" ], "fingerprints" => [ "SHA256:new" ],
                      "key_types" => [ "ssh-ed25519" ], "boot_id_changed" => boot_id_changed, "instance_id" => inst.id })
  end

  def by_kind(signals, kind) = signals.select { |s| s.kind == kind }

  describe "a host-key change with no boot between (arm b)" do
    let!(:inst) { instance_for(account, keys: [ key ]) }

    it "emits one high signal naming the instance and the fingerprints, never key material" do
      event = changed_event(inst, boot_id_changed: false)

      signal = by_kind(sensor.sense, "system.ssh_host_key_changed_in_boot").sole

      expect(signal.severity).to eq(:high)
      expect(signal.payload).to include("instance_id" => inst.id, "event_id" => event.id,
                                        "previous_fingerprints" => [ "SHA256:old" ], "fingerprints" => [ "SHA256:new" ])
      expect(signal.payload.to_s).not_to include(key["key"])
      expect(signal.fingerprint).to eq("ssh_host_key_changed_in_boot:#{event.id}")
    end

    it "stays quiet for a change across a boot (a reimage looks like that)" do
      changed_event(inst, boot_id_changed: true)

      expect(by_kind(sensor.sense, "system.ssh_host_key_changed_in_boot")).to be_empty
    end

    it "ignores the recorded and cleared events, old events, and another account's" do
      changed_event(inst, boot_id_changed: false, kind: System::SshHostKeyWriter::RECORDED_EVENT_KIND)
      changed_event(inst, boot_id_changed: false, kind: System::SshHostKeyWriter::CLEARED_EVENT_KIND)
      changed_event(inst, boot_id_changed: false, at: 3.hours.ago)
      other = create(:account)
      changed_event(instance_for(other, keys: [ key ]), boot_id_changed: false, account: other)

      expect(by_kind(sensor.sense, "system.ssh_host_key_changed_in_boot")).to be_empty
    end

    it "widens the lookback only through the declared threshold" do
      changed_event(inst, boot_id_changed: false, at: 3.hours.ago)
      System::Fleet::SensorConfig.create!(account: account, sensor: "ssh_host_key", config: { "change_lookback_seconds" => 4 * 3600 })

      expect(by_kind(described_class.new(account: account).sense, "system.ssh_host_key_changed_in_boot").size).to eq(1)
    end
  end

  describe "host-key coverage (arm a)" do
    it "reports the instances with no recorded key, and says the fleet is not ready to enforce" do
      covered = instance_for(account, keys: [ key ])
      bare = instance_for(account)

      signal = by_kind(sensor.sense, "system.ssh_host_key_uncovered").sole

      expect(signal.severity).to eq(:medium)
      expect(signal.payload).to include("uncovered_count" => 1, "covered_count" => 1, "total" => 2,
                                        "uncovered_instance_ids" => [ bare.id ], "ready_to_enforce" => false)
      expect([ true, false ]).to include(signal.payload["require_host_key"])
      expect(covered).to be_present
    end

    it "treats a document with no valid key as uncovered" do
      bare = instance_for(account, keys: [ { "type" => "ssh-ed25519", "key" => "not base64 !!" } ])

      expect(by_kind(sensor.sense, "system.ssh_host_key_uncovered").sole.payload["uncovered_instance_ids"]).to eq([ bare.id ])
    end

    it "gives a young instance its first heartbeat before calling it uncovered" do
      instance_for(account, created: 2.minutes.ago)
      instance_for(account, keys: [ key ])

      signals = sensor.sense

      expect(by_kind(signals, "system.ssh_host_key_uncovered")).to be_empty
      expect(by_kind(signals, "system.ssh_host_key_coverage_complete")).to be_empty # not complete while one is still reporting in
    end

    it "delivers zero uncovered as a positive fact, with the counts" do
      instance_for(account, keys: [ key ])
      instance_for(account, keys: [ key ])

      signals = sensor.sense

      expect(by_kind(signals, "system.ssh_host_key_uncovered")).to be_empty
      complete = by_kind(signals, "system.ssh_host_key_coverage_complete").sole
      expect(complete.severity).to eq(:low)
      expect(complete.payload).to include("uncovered_count" => 0, "covered_count" => 2, "total" => 2, "ready_to_enforce" => true)
      expect(complete.fingerprint).to match(/\Assh_host_key_coverage_complete:#{account.id}:\d+\z/)
    end

    it "says nothing about a fleet with no instances: 0 of 0 is not coverage" do
      expect(sensor.sense).to eq([])
    end

    it "counts only this account's running or starting instances" do
      instance_for(account, keys: [ key ])
      instance_for(account, status: "stopped")
      instance_for(account, status: "terminated")
      other = create(:account)
      instance_for(other)

      expect(by_kind(sensor.sense, "system.ssh_host_key_coverage_complete").sole.payload["total"]).to eq(1)
    end

    it "caps the ids it names, but never the count" do
      System::Fleet::SensorConfig.create!(account: account, sensor: "ssh_host_key", config: { "max_uncovered_ids" => 2 })
      3.times { instance_for(account) }

      payload = by_kind(described_class.new(account: account).sense, "system.ssh_host_key_uncovered").sole.payload

      expect(payload["uncovered_count"]).to eq(3)
      expect(payload["uncovered_instance_ids"].size).to eq(2)
    end

    it "keys the uncovered fingerprint on the uncovered set, so a changed set is reported again" do
      first = instance_for(account)
      before = by_kind(sensor.sense, "system.ssh_host_key_uncovered").sole.fingerprint
      instance_for(account)
      after = by_kind(described_class.new(account: account).sense, "system.ssh_host_key_uncovered").sole.fingerprint

      expect(after).not_to eq(before)
      expect(first).to be_present
    end
  end

  describe "review hardening (IMP-e744d96da817)" do
    it "restates the positive fact per half hour rather than as one standing fingerprint (the standing-signal lane would page good news)" do
      instance_for(account, keys: [ key ])
      first = by_kind(sensor.sense, "system.ssh_host_key_coverage_complete").sole.fingerprint
      same_bucket = nil
      later = nil
      travel_to(Time.current.beginning_of_hour + 10.minutes) { same_bucket = by_kind(sensor.sense, "system.ssh_host_key_coverage_complete").sole.fingerprint }
      travel_to(Time.current + 2.hours) { later = by_kind(described_class.new(account: account).sense, "system.ssh_host_key_coverage_complete").sole.fingerprint }

      expect(later).not_to eq(first)
      expect(same_bucket).to match(/:\d+\z/)
    end

    it "keeps the uncovered fingerprint stable across ticks: a standing gap SHOULD age into an operator page" do
      instance_for(account)
      a = by_kind(sensor.sense, "system.ssh_host_key_uncovered").sole.fingerprint
      b = nil
      travel_to(Time.current + 2.hours) { b = by_kind(described_class.new(account: account).sense, "system.ssh_host_key_uncovered").sole.fingerprint }

      expect(b).to eq(a)
    end

    it "counts a starting instance, and draws the grace line at the threshold" do
      instance_for(account, status: "starting", created: 31.minutes.ago)
      instance_for(account, status: "starting", created: 29.minutes.ago)

      payload = by_kind(sensor.sense, "system.ssh_host_key_uncovered").sole.payload

      expect(payload).to include("uncovered_count" => 1, "awaiting_first_report_count" => 1, "total" => 2, "ready_to_enforce" => false)
    end

    it "ignores a changed event that carries no boot_id_changed (unknown is neither shape)" do
      inst = instance_for(account, keys: [ key ])
      create(:system_fleet_event, account: account, kind: System::SshHostKeyWriter::CHANGED_EVENT_KIND, severity: "high",
             source: "system/ssh_host_key_writer", node_instance_id: inst.id, emitted_at: 1.minute.ago,
             payload: { "previous_fingerprints" => [ "SHA256:old" ], "fingerprints" => [ "SHA256:new" ] })

      expect(by_kind(sensor.sense, "system.ssh_host_key_changed_in_boot")).to be_empty
    end

    describe "end to end through SshHostKeyWriter" do
      let(:inst)        { instance_for(account) }
      let(:replacement) { SshHostKeyFixtures.entry("ssh-ed25519") }

      it "pages a swap inside one boot" do
        System::SshHostKeyWriter.write!(instance: inst, payload: [ key ], boot_id: "boot-1")
        System::SshHostKeyWriter.write!(instance: inst, payload: [ replacement ], boot_id: "boot-1")

        signal = by_kind(sensor.sense, "system.ssh_host_key_changed_in_boot").sole
        expect(signal.payload["instance_id"]).to eq(inst.id)
        expect(signal.payload.to_json).not_to include(replacement["key"])
      end

      it "does not page a swap across a boot, nor one with no boot_id on either side" do
        System::SshHostKeyWriter.write!(instance: inst, payload: [ key ], boot_id: "boot-1")
        System::SshHostKeyWriter.write!(instance: inst, payload: [ replacement ], boot_id: "boot-2")
        other = instance_for(account)
        System::SshHostKeyWriter.write!(instance: other, payload: [ key ], boot_id: nil)
        System::SshHostKeyWriter.write!(instance: other, payload: [ SshHostKeyFixtures.entry("ssh-ed25519") ], boot_id: nil)

        expect(by_kind(sensor.sense, "system.ssh_host_key_changed_in_boot")).to be_empty
      end
    end
  end

  describe "wiring" do
    it "is a registered sensor" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end

    it "binds each kind with no skill (no applier exists), to its own category" do
      bindings = System::Fleet::DecisionEngine::SIGNAL_BINDINGS
      expect(bindings.fetch("system.ssh_host_key_changed_in_boot")).to include(skill: nil, action_category: "system.ssh_host_key_changed_investigate", advisory: true)
      expect(bindings.fetch("system.ssh_host_key_uncovered")).to include(skill: nil, action_category: "system.ssh_host_key_coverage_investigate")
      expect(bindings.fetch("system.ssh_host_key_coverage_complete")).to include(skill: nil, action_category: "system.observation")
    end

    it "gates the change in require_approval and the coverage gap in notify_and_proceed" do
      policies = System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES
      expect(policies.fetch("system.ssh_host_key_changed_investigate")).to eq("require_approval")
      expect(policies.fetch("system.ssh_host_key_coverage_investigate")).to eq("notify_and_proceed")
    end

    it "keeps both investigate lanes out of the effectiveness scoring: a person acts, not a skill" do
      exempt = System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES
      expect(exempt).to include("system.ssh_host_key_changed_investigate", "system.ssh_host_key_coverage_investigate")
    end
  end
end
