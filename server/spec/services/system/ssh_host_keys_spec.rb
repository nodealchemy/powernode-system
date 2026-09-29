# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

# IMP-190834701b0a — the validator every SSH host key passes through twice:
# on the way IN (heartbeat ingest) and on the way OUT (known_hosts rendering).
# The second pass is why a stored value with an injected newline can never
# become a second known_hosts entry, whatever wrote it to the column.
RSpec.describe System::SshHostKeys do
  describe ".normalize" do
    it "accepts a well-formed key and returns type, key and its SHA256 fingerprint" do
      entry = SshHostKeyFixtures.entry("ssh-ed25519")

      normalized = described_class.normalize(entry)

      expect(normalized).to eq(
        "type" => "ssh-ed25519", "key" => entry["key"],
        "fingerprint" => SshHostKeyFixtures.fingerprint(entry["key"])
      )
    end

    it "accepts symbol keys" do
      entry = SshHostKeyFixtures.entry
      expect(described_class.normalize(type: entry["type"], key: entry["key"])).to be_present
    end

    it "rejects a type outside the allowlist" do
      entry = SshHostKeyFixtures.entry("ssh-dss")
      expect(described_class.normalize(entry)).to be_nil
    end

    it "rejects a blob whose embedded type disagrees with the declared type" do
      entry = SshHostKeyFixtures.entry("ssh-rsa").merge("type" => "ssh-ed25519")
      expect(described_class.normalize(entry)).to be_nil
    end

    it "rejects non-base64 content" do
      expect(described_class.normalize("type" => "ssh-ed25519", "key" => "not base64!")).to be_nil
    end

    it "rejects a key carrying a newline (known_hosts line injection)" do
      entry = SshHostKeyFixtures.entry
      injected = "#{entry['key']}\n@cert-authority * ssh-ed25519 #{SshHostKeyFixtures.key}"

      expect(described_class.normalize(entry.merge("key" => injected))).to be_nil
    end

    it "rejects a type carrying whitespace or a newline" do
      entry = SshHostKeyFixtures.entry
      expect(described_class.normalize(entry.merge("type" => "ssh-ed25519\nx"))).to be_nil
      expect(described_class.normalize(entry.merge("type" => "ssh-ed25519 "))).to be_nil
    end

    it "rejects an oversized key" do
      entry = SshHostKeyFixtures.entry("ssh-rsa", body_bytes: described_class::MAX_KEY_CHARS)
      expect(entry["key"].length).to be > described_class::MAX_KEY_CHARS

      expect(described_class.normalize(entry)).to be_nil
    end

    it "rejects private-key-looking content" do
      armor = "-----BEGIN #{%w[OPENSSH PRIVATE KEY].join(' ')}-----"
      expect(described_class.normalize("type" => "ssh-ed25519", "key" => armor)).to be_nil
    end

    it "rejects non-string and non-hash input without raising" do
      expect(described_class.normalize(nil)).to be_nil
      expect(described_class.normalize("ssh-ed25519 AAAA")).to be_nil
      expect(described_class.normalize("type" => 1, "key" => [ "x" ])).to be_nil
    end
  end

  describe ".normalize_all" do
    it "drops invalid entries, de-duplicates by fingerprint, caps the count and prefers ed25519" do
      rsa = SshHostKeyFixtures.entry("ssh-rsa", body_bytes: 64)
      ed = SshHostKeyFixtures.entry("ssh-ed25519")

      result = described_class.normalize_all([ rsa, { "type" => "ssh-ed25519", "key" => "!!" }, ed, ed ])

      expect(result.map { |e| e["type"] }).to eq(%w[ssh-ed25519 ssh-rsa])
    end

    it "caps the number of keys kept" do
      many = Array.new(described_class::MAX_KEYS + 3) { SshHostKeyFixtures.entry("ssh-rsa", body_bytes: 64) }
      expect(described_class.normalize_all(many).size).to eq(described_class::MAX_KEYS)
    end

    it "returns an empty list for a non-array payload" do
      expect(described_class.normalize_all("ssh-ed25519 AAAA")).to eq([])
      expect(described_class.normalize_all(nil)).to eq([])
    end
  end

  describe ".recorded_for" do
    it "re-validates the stored document and returns only entries that still pass" do
      good = SshHostKeyFixtures.entry
      instance = build(:system_node_instance,
                       ssh_host_keys: { "keys" => [ good, { "type" => "ssh-ed25519", "key" => "x\ny" } ] })

      expect(described_class.recorded_for(instance).map { |e| e["key"] }).to eq([ good["key"] ])
    end

    it "is empty for an instance that never reported a key" do
      expect(described_class.recorded_for(build(:system_node_instance, ssh_host_keys: nil))).to eq([])
    end
  end

  describe ".known_hosts" do
    it "renders one '<alias> <type> <key>' line per entry" do
      a = SshHostKeyFixtures.entry
      b = SshHostKeyFixtures.entry("ecdsa-sha2-nistp256")

      expect(described_class.known_hosts("alias-1", [ a, b ])).to eq(
        "alias-1 ssh-ed25519 #{a['key']}\nalias-1 ecdsa-sha2-nistp256 #{b['key']}\n"
      )
    end

    it "refuses an alias that could inject a pattern or a second field" do
      expect { described_class.known_hosts("a b", [ SshHostKeyFixtures.entry ]) }.to raise_error(ArgumentError)
      expect { described_class.known_hosts("*", [ SshHostKeyFixtures.entry ]) }.to raise_error(ArgumentError)
    end
  end

  # An external oracle for the fingerprint: ssh-keygen computes the same
  # SHA256:<unpadded base64> the audit trail records, so an operator can match
  # an audit row against `ssh-keygen -lf` output on the node itself.
  describe "fingerprint parity with ssh-keygen" do
    it "matches ssh-keygen -l for the same public key" do
      skip "ssh-keygen not installed" unless system("command -v ssh-keygen >/dev/null 2>&1")

      entry = SshHostKeyFixtures.entry
      Dir.mktmpdir do |dir|
        path = File.join(dir, "host.pub")
        File.write(path, "#{entry['type']} #{entry['key']}\n")
        out, _err, status = Open3.capture3("ssh-keygen", "-l", "-E", "sha256", "-f", path)

        expect(status.success?).to be(true)
        expect(out.split[1]).to eq(described_class.normalize(entry)["fingerprint"])
      end
    end
  end
end
