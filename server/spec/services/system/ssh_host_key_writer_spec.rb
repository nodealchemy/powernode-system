# frozen_string_literal: true

require "rails_helper"

# IMP-190834701b0a — heartbeat ingest of the node's SSH host PUBLIC keys.
#
# The oracle contract:
#   * a valid report is stored as type + key + SHA256 fingerprint;
#   * the FIRST recording and every CHANGE are audited — fingerprints only,
#     old -> new, never a key blob — and emit a fleet event (a change at high
#     severity, so a reimage and an impersonation are both visible);
#   * an unchanged report writes nothing;
#   * malformed, oversized or injected input is ignored without raising, and
#     never clobbers what is already recorded.
RSpec.describe System::SshHostKeyWriter do
  let(:account)  { create(:account) }
  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node, account: account) }

  let(:ed25519) { SshHostKeyFixtures.entry("ssh-ed25519") }
  let(:rsa)     { SshHostKeyFixtures.entry("ssh-rsa", body_bytes: 64) }

  def write!(payload, boot_id: "boot-1")
    described_class.write!(instance: instance, payload: payload, boot_id: boot_id)
  end

  def audits
    ::AuditLog.where(resource_type: "System::NodeInstance", resource_id: instance.id.to_s)
              .where(action: [ described_class::RECORDED_ACTION, described_class::CHANGED_ACTION ])
              .order(:created_at)
  end

  def stored
    instance.reload.ssh_host_keys
  end

  it "does nothing when the heartbeat carries no host keys" do
    expect(write!(nil)).to be_nil
    expect(stored).to be_nil
    expect(audits).to be_empty
  end

  describe "first recording" do
    it "stores type, key and fingerprint, ed25519 first" do
      expect(write!([ rsa, ed25519 ])).to eq(:recorded)

      expect(stored["keys"]).to eq([
        ed25519.merge("fingerprint" => SshHostKeyFixtures.fingerprint(ed25519["key"])),
        rsa.merge("fingerprint" => SshHostKeyFixtures.fingerprint(rsa["key"]))
      ])
      expect(stored["boot_id"]).to eq("boot-1")
      expect(stored["recorded_at"]).to be_present
    end

    it "audits the first recording with fingerprints only" do
      write!([ ed25519 ])

      row = audits.sole
      expect(row.action).to eq(described_class::RECORDED_ACTION)
      expect(row.account_id).to eq(instance.account_id)
      expect(row.metadata["previous_fingerprints"]).to eq([])
      expect(row.metadata["fingerprints"]).to eq([ SshHostKeyFixtures.fingerprint(ed25519["key"]) ])
      expect(row.metadata.to_json).not_to include(ed25519["key"])
    end

    it "emits a low-severity recorded event" do
      write!([ ed25519 ])

      event = System::FleetEvent.find_by!(kind: described_class::RECORDED_EVENT_KIND, node_instance_id: instance.id)
      expect(event.severity).to eq("low")
      expect(event.payload.to_json).not_to include(ed25519["key"])
    end
  end

  describe "an unchanged report" do
    it "writes nothing and audits nothing on the same boot" do
      write!([ ed25519 ])
      before_doc = stored

      expect(write!([ ed25519 ], boot_id: "boot-1")).to eq(:unchanged)

      expect(stored).to eq(before_doc)
      expect(audits.count).to eq(1)
    end

    # Review round 1, critic A F1: the stored boot_id is "the last boot on
    # which these keys were confirmed". Without this refresh, a key swapped
    # INSIDE a later boot compared against the boot the keys were first
    # recorded on and read as a reboot.
    it "refreshes only the confirming boot_id on a new boot, without an audit row" do
      write!([ ed25519 ])
      keys_before = stored["keys"]

      expect(write!([ ed25519 ], boot_id: "boot-2")).to eq(:unchanged)

      expect(stored["keys"]).to eq(keys_before)
      expect(stored["boot_id"]).to eq("boot-2")
      expect(audits.count).to eq(1)
    end
  end

  describe "a changed key" do
    let(:replacement) { SshHostKeyFixtures.entry("ssh-ed25519") }

    before { write!([ ed25519 ]) }

    it "accepts the new key from the authenticated heartbeat" do
      expect(write!([ replacement ], boot_id: "boot-2")).to eq(:changed)

      expect(stored["keys"].map { |e| e["key"] }).to eq([ replacement["key"] ])
    end

    it "audits old -> new fingerprints, never either blob" do
      write!([ replacement ], boot_id: "boot-2")

      row = audits.last
      expect(row.action).to eq(described_class::CHANGED_ACTION)
      expect(row.metadata["previous_fingerprints"]).to eq([ SshHostKeyFixtures.fingerprint(ed25519["key"]) ])
      expect(row.metadata["fingerprints"]).to eq([ SshHostKeyFixtures.fingerprint(replacement["key"]) ])
      expect(row.metadata["boot_id_changed"]).to be(true)
      json = row.metadata.to_json
      expect(json).not_to include(ed25519["key"])
      expect(json).not_to include(replacement["key"])
    end

    it "records a change WITHOUT a reboot as such — the shape that is not a reimage" do
      write!([ replacement ], boot_id: "boot-1")

      expect(audits.last.metadata["boot_id_changed"]).to be(false)
    end

    # IMP-e744d96da817 (review): nil == nil must not read as "the same boot", or a
    # reimage reported by an agent with no boot_id is paged as the tamper shape.
    it "leaves boot_id_changed UNKNOWN (absent, never false) when either side has no boot_id" do
      instance.update_columns(ssh_host_keys: nil)
      write!([ ed25519 ], boot_id: nil)

      expect(write!([ replacement ], boot_id: nil)).to eq(:changed)

      expect(audits.last.metadata).not_to have_key("boot_id_changed")
      event = System::FleetEvent.where(kind: described_class::CHANGED_EVENT_KIND, node_instance_id: instance.id).sole
      expect(event.payload).not_to have_key("boot_id_changed")
      expect(event.severity).to eq("high") # still on the feed, as before; just not classified
    end

    it "leaves it unknown when only the new report has no boot_id" do
      expect(write!([ replacement ], boot_id: nil)).to eq(:changed)

      expect(audits.last.metadata).not_to have_key("boot_id_changed")
    end

    it "emits a MEDIUM changed event for a change across a reboot (what a reimage looks like)" do
      write!([ replacement ], boot_id: "boot-2")

      event = System::FleetEvent.find_by!(kind: described_class::CHANGED_EVENT_KIND, node_instance_id: instance.id)
      expect(event.severity).to eq("medium")
      expect(event.payload["boot_id_changed"]).to be(true)
      expect(event.payload["previous_fingerprints"]).to eq([ SshHostKeyFixtures.fingerprint(ed25519["key"]) ])
      expect(event.payload.to_json).not_to include(replacement["key"])
    end

    it "emits a HIGH changed event for a change inside one boot" do
      write!([ replacement ], boot_id: "boot-1")

      event = System::FleetEvent.find_by!(kind: described_class::CHANGED_EVENT_KIND, node_instance_id: instance.id)
      expect(event.severity).to eq("high")
      expect(event.payload["boot_id_changed"]).to be(false)
    end

    # Review round 1, critic A F1 (b): the regression the stale comparison
    # produced. Recorded on boot-1, confirmed unchanged on boot-2, then swapped
    # on boot-2 with no reboot: that is an in-boot change, not a reimage.
    it "classifies a swap after an unchanged reboot as in-boot (boot_id_changed false, high)" do
      expect(write!([ ed25519 ], boot_id: "boot-2")).to eq(:unchanged)

      expect(write!([ replacement ], boot_id: "boot-2")).to eq(:changed)

      expect(audits.last.metadata["boot_id_changed"]).to be(false)
      event = System::FleetEvent.where(kind: described_class::CHANGED_EVENT_KIND, node_instance_id: instance.id).sole
      expect(event.severity).to eq("high")
    end
  end

  # Review round 1, critic A F7 / critic B F5: a transiently unreadable .pub
  # makes a heartbeat report a strict SUBSET of the recorded keys. Replacing
  # on that alone flapped the set (and the alarm) every other tick.
  describe "a narrowed report (strict subset of the recorded keys)" do
    before { write!([ ed25519, rsa ]) }

    it "does not replace the recorded set within the same boot, and audits nothing" do
      expect(write!([ ed25519 ], boot_id: "boot-1")).to eq(:unchanged)

      expect(stored["keys"].map { |e| e["type"] }).to eq(%w[ssh-ed25519 ssh-rsa])
      expect(audits.count).to eq(1)
      expect(System::FleetEvent.where(kind: described_class::CHANGED_EVENT_KIND)).to be_empty
    end

    it "narrows the recorded set across a boot change, audited as a change" do
      expect(write!([ ed25519 ], boot_id: "boot-2")).to eq(:changed)

      expect(stored["keys"].map { |e| e["type"] }).to eq(%w[ssh-ed25519])
      expect(audits.last.action).to eq(described_class::CHANGED_ACTION)
    end

    it "still treats a report that ADDS a key within the boot as a change" do
      extra = SshHostKeyFixtures.entry("ecdsa-sha2-nistp256")

      expect(write!([ ed25519, extra ], boot_id: "boot-1")).to eq(:changed)
    end
  end

  # Review round 1, critic A F3: the node API resolves a legacy shared-CN
  # certificate to the newest sibling instance. Host keys are a trust anchor,
  # so they are ingested only when the identity is bound to THIS instance.
  describe "instance binding" do
    it "ignores the report when the instance carries a shared (non-instance) mTLS subject" do
      instance.update_columns(mtls_subject: "legacy-shared-hostname")
      allow(Rails.logger).to receive(:warn).and_call_original

      expect(write!([ ed25519 ])).to be_nil

      expect(stored).to be_nil
      expect(audits).to be_empty
      expect(Rails.logger).to have_received(:warn).with(/not instance-bound/)
    end

    it "ingests when the mTLS subject is the instance id" do
      instance.update_columns(mtls_subject: instance.id.to_s)

      expect(write!([ ed25519 ])).to eq(:recorded)
    end
  end

  # Review round 1, critic A F4: a retried heartbeat can overlap its original;
  # the read-compare-write runs under a row lock.
  describe "row locking" do
    it "reads, compares and writes under the instance row lock" do
      allow(instance).to receive(:with_lock).and_call_original

      write!([ ed25519 ])

      expect(instance).to have_received(:with_lock)
    end
  end

  # Review round 1, critic B F3: the operator recovery for a stale recorded
  # key (docs/design/ssh-host-key-verification.md). Audited; no key material.
  describe ".clear!" do
    let(:operator) { create(:user, account: account) }

    before { write!([ ed25519 ]) }

    it "clears the recorded keys and audits the previous fingerprints, the actor and the reason" do
      expect(described_class.clear!(instance: instance, actor: operator, reason: "reprovisioned")).to be(true)

      expect(stored).to be_nil
      row = ::AuditLog.find_by!(action: described_class::CLEARED_ACTION, resource_id: instance.id.to_s)
      expect(row.user_id).to eq(operator.id)
      expect(row.metadata["previous_fingerprints"]).to eq([ SshHostKeyFixtures.fingerprint(ed25519["key"]) ])
      expect(row.metadata["reason"]).to eq("reprovisioned")
      expect(row.metadata.to_json).not_to include(ed25519["key"])
    end

    # Review round 2: recovery is a human act. The audit row names the User
    # who cleared the key; anything else is refused before the key is touched.
    it "names the clearing User on the audit row" do
      described_class.clear!(instance: instance, actor: operator, reason: "reprovisioned")

      row = ::AuditLog.find_by!(action: described_class::CLEARED_ACTION, resource_id: instance.id.to_s)
      expect(row.user).to eq(operator)
    end

    # IMP-a41ceb3cdd64 — a clear decided earlier (an approval parked for the key the approver saw).
    it "clears when the recorded set is exactly the expected fingerprints" do
      fp = SshHostKeyFixtures.fingerprint(ed25519["key"])

      expect(described_class.clear!(instance: instance, actor: operator, reason: "stale", expect_fingerprints: [ fp ])).to be(true)
      expect(stored).to be_nil
    end

    it "refuses, audits nothing and keeps the key when the recorded set is not the expected one" do
      expect { described_class.clear!(instance: instance, actor: operator, reason: "stale", expect_fingerprints: [ "SHA256:other" ]) }
        .to raise_error(ArgumentError, /no longer the one/)

      expect(stored).not_to be_nil
      expect(::AuditLog.where(action: described_class::CLEARED_ACTION)).to be_empty
    end

    it "refuses an expectation when nothing is recorded any more (already cleared)" do
      instance.update_columns(ssh_host_keys: nil)

      expect { described_class.clear!(instance: instance, actor: operator, reason: "stale", expect_fingerprints: [ "SHA256:x" ]) }
        .to raise_error(ArgumentError, /no longer the one/)
      expect(::AuditLog.where(action: described_class::CLEARED_ACTION)).to be_empty
    end

    it "refuses a non-User actor and leaves the recorded key in place" do
      stub_const("SpecServiceActor", Struct.new(:id))

      expect { described_class.clear!(instance: instance, actor: SpecServiceActor.new("actor-123"), reason: "reprovisioned") }
        .to raise_error(ArgumentError, /User/)
      expect(stored).to be_present
      expect(::AuditLog.where(action: described_class::CLEARED_ACTION)).to be_empty
    end

    it "refuses a nil actor" do
      expect { described_class.clear!(instance: instance, actor: nil, reason: "reprovisioned") }
        .to raise_error(ArgumentError, /User/)
      expect(stored).to be_present
    end

    it "refuses without a reason" do
      expect { described_class.clear!(instance: instance, actor: operator, reason: " ") }
        .to raise_error(ArgumentError)
      expect(stored).to be_present
    end
  end

  describe "malformed input" do
    before { write!([ ed25519 ]) }

    [
      [ "a non-array payload", "ssh-ed25519 AAAA" ],
      [ "a hash payload", { "type" => "ssh-ed25519", "key" => "AAAA" } ],
      [ "an entry with a bad type", [ { "type" => "ssh-dss", "key" => "AAAA" } ] ],
      [ "an entry that is not base64", [ { "type" => "ssh-ed25519", "key" => "not base64!" } ] ],
      [ "an entry that is not a hash", [ "ssh-ed25519 AAAA" ] ]
    ].each do |label, payload|
      it "ignores #{label} without raising and keeps the recorded key" do
        expect { write!(payload) }.not_to raise_error

        expect(stored["keys"].map { |e| e["key"] }).to eq([ ed25519["key"] ])
        expect(audits.count).to eq(1)
      end
    end

    it "ignores an oversized key" do
      big = SshHostKeyFixtures.entry("ssh-rsa", body_bytes: System::SshHostKeys::MAX_KEY_CHARS)

      write!([ big ])

      expect(stored["keys"].map { |e| e["key"] }).to eq([ ed25519["key"] ])
    end

    it "never lets a newline in a key add a second entry" do
      injected = ed25519.merge("key" => "#{ed25519['key']}\n@cert-authority * #{rsa['type']} #{rsa['key']}")

      write!([ injected ])

      expect(stored["keys"].size).to eq(1)
      expect(stored.to_json).not_to include("cert-authority")
    end

    it "stores only the valid entries of a mixed report" do
      write!([ ed25519, { "type" => "ssh-ed25519", "key" => "x\ny" }, rsa ])

      expect(stored["keys"].map { |e| e["type"] }).to eq(%w[ssh-ed25519 ssh-rsa])
    end
  end

  describe "audit atomicity" do
    it "does not store a key whose audit row could not be written" do
      allow(::AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(::AuditLog.new))

      expect { write!([ ed25519 ]) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(stored).to be_nil
    end
  end
end
