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
    it "writes nothing and audits nothing" do
      write!([ ed25519 ])
      before_doc = stored

      expect(write!([ ed25519 ], boot_id: "boot-2")).to eq(:unchanged)

      expect(stored).to eq(before_doc)
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

    it "emits a high-severity changed event so an operator sees it" do
      write!([ replacement ], boot_id: "boot-2")

      event = System::FleetEvent.find_by!(kind: described_class::CHANGED_EVENT_KIND, node_instance_id: instance.id)
      expect(event.severity).to eq("high")
      expect(event.payload["previous_fingerprints"]).to eq([ SshHostKeyFixtures.fingerprint(ed25519["key"]) ])
      expect(event.payload.to_json).not_to include(replacement["key"])
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
