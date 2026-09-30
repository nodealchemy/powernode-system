# frozen_string_literal: true

require "rails_helper"
require "open3"

# IMP-1e5db5e6aefb — the host PUBLIC key a GitOps repository's SSH remote is
# verified against. Every key reaches the column through
# System::SshHostKeys.normalize, whether an operator typed it or ssh-keyscan
# printed it; raw text never becomes a known_hosts line.
RSpec.describe System::Gitops::RepositoryHostKey do
  let(:account) { create(:account) }
  let(:entry) { SshHostKeyFixtures.entry("ssh-ed25519") }
  let(:repository) do
    create(:system_gitops_repository, account: account,
                                      repo_url: "ssh://git@git.example.test:2222/powernode/fleet.git")
  end

  describe ".parse_explicit" do
    it "accepts a '<type> <key>' line and returns the normalized entry" do
      entries = described_class.parse_explicit("#{entry['type']} #{entry['key']}")

      expect(entries).to eq([ entry.merge("fingerprint" => SshHostKeyFixtures.fingerprint(entry["key"])) ])
    end

    it "accepts a trailing comment and a known_hosts-style leading host field" do
      expect(described_class.parse_explicit("#{entry['type']} #{entry['key']} git.example.test").size).to eq(1)
      expect(described_class.parse_explicit("git.example.test #{entry['type']} #{entry['key']}").size).to eq(1)
    end

    it "accepts several lines, one key each, as ssh-keyscan prints them" do
      rsa = SshHostKeyFixtures.entry("ssh-rsa", body_bytes: 64)
      text = "#{entry['type']} #{entry['key']}\n#{rsa['type']} #{rsa['key']}\n"

      expect(described_class.parse_explicit(text).map { |e| e["type"] }).to eq(%w[ssh-ed25519 ssh-rsa])
    end

    it "refuses a value carrying a known_hosts marker line (newline injection)" do
      injected = "#{entry['type']} #{entry['key']}\n@cert-authority * ssh-ed25519 #{SshHostKeyFixtures.key}"

      expect { described_class.parse_explicit(injected) }
        .to raise_error(described_class::InvalidHostKey)
    end

    it "refuses a private-key-shaped value and never echoes it" do
      pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nc2VudGluZWwtbm90LWEta2V5\n-----END OPENSSH PRIVATE KEY-----"

      expect { described_class.parse_explicit(pem) }.to raise_error(described_class::InvalidHostKey) { |e|
        expect(e.message).not_to include("c2VudGluZWw", "PRIVATE")
      }
    end

    it "refuses a blank value, a bare key with no type, and a disallowed type" do
      expect { described_class.parse_explicit("   ") }.to raise_error(described_class::InvalidHostKey)
      expect { described_class.parse_explicit(entry["key"]) }.to raise_error(described_class::InvalidHostKey)
      expect { described_class.parse_explicit("ssh-dss #{SshHostKeyFixtures.key('ssh-dss')}") }
        .to raise_error(described_class::InvalidHostKey)
    end

    it "refuses a non-string" do
      expect { described_class.parse_explicit(entry) }.to raise_error(described_class::InvalidHostKey)
    end
  end

  describe ".scan" do
    let(:scans) { [] }
    let(:stdout) { "" }
    let(:status) { instance_double(Process::Status, success?: true, exitstatus: 0) }

    before do
      allow(Open3).to receive(:capture3) do |*argv|
        scans << argv.map(&:to_s)
        [ stdout, "# git.example.test:2222 SSH-2.0-OpenSSH_9.6\n", status ]
      end
    end

    context "with keyscan output" do
      let(:stdout) { "[git.example.test]:2222 #{entry['type']} #{entry['key']}\n" }

      it "runs ssh-keyscan against the host and port with a bounded timeout, array form" do
        described_class.scan(host: "git.example.test", port: 2222)

        expect(scans).to eq([ [ "ssh-keyscan", "-T", described_class::KEYSCAN_TIMEOUT_SECONDS.to_s,
                                "-p", "2222", "git.example.test" ] ])
      end

      it "returns the normalized entries with fingerprints" do
        entries = described_class.scan(host: "git.example.test", port: 2222)

        expect(entries).to eq([ entry.merge("fingerprint" => SshHostKeyFixtures.fingerprint(entry["key"])) ])
      end
    end

    context "with hostile stdout" do
      let(:stdout) do
        "[git.example.test]:2222 ssh-dss #{SshHostKeyFixtures.key('ssh-dss')}\n" \
          "@cert-authority * ssh-ed25519 #{SshHostKeyFixtures.key}\n" \
          "garbage\n"
      end

      it "returns nothing rather than trusting raw text" do
        expect(described_class.scan(host: "git.example.test", port: 2222)).to eq([])
      end
    end

    context "when ssh-keyscan fails" do
      let(:status) { instance_double(Process::Status, success?: false, exitstatus: 1) }

      it "returns nothing" do
        expect(described_class.scan(host: "git.example.test", port: 22)).to eq([])
      end
    end

    # A missing binary is a hub deploy defect, distinct from a host that
    # answered with nothing; the sync names it (F2).
    it "raises ScannerUnavailable, naming the binary, when it is not installed" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, "ssh-keyscan")

      expect { described_class.scan(host: "git.example.test", port: 22) }
        .to raise_error(described_class::ScannerUnavailable, /ssh-keyscan.*(not installed|not found|missing)/i)
    end

    it "returns nothing and never raises on any other failure" do
      allow(Open3).to receive(:capture3).and_raise(IOError, "pipe closed")

      expect(described_class.scan(host: "git.example.test", port: 22)).to eq([])
    end
  end

  describe ".recorded?" do
    it "is false with no document and true once a document holds an entry" do
      expect(described_class.recorded?(repository)).to be(false)

      described_class.record!(repository, [ entry ], source: "explicit")

      expect(described_class.recorded?(repository)).to be(true)
    end

    # The distinction TOFU is keyed on: a present record that no longer
    # VALIDATES is still a record (recorded_for is [] but recorded? is true).
    it "is true for a present document whose entries do not validate" do
      repository.update_columns(ssh_host_keys: { "keys" => [ { "type" => "ssh-ed25519", "key" => "!!" } ],
                                                 "recorded_at" => Time.current.utc.iso8601, "source" => "explicit" })

      expect(described_class.recorded?(repository)).to be(true)
      expect(described_class.recorded_for(repository)).to eq([])
    end

    it "is false for a document with no entries" do
      repository.update_columns(ssh_host_keys: { "keys" => [], "source" => "explicit" })

      expect(described_class.recorded?(repository)).to be(false)
    end
  end

  describe ".record! / .recorded_for" do
    it "stores the entries with the source and reads them back re-validated" do
      described_class.record!(repository, [ entry ], source: "explicit")

      recorded = described_class.recorded_for(repository.reload)
      expect(recorded.map { |e| e["fingerprint"] }).to eq([ SshHostKeyFixtures.fingerprint(entry["key"]) ])
      expect(repository.ssh_host_keys["source"]).to eq("explicit")
      expect(repository.ssh_host_keys["recorded_at"]).to be_present
    end

    it "refuses an unknown source" do
      expect { described_class.record!(repository, [ entry ], source: "guess") }.to raise_error(ArgumentError)
    end
  end

  describe ".alias_for" do
    it "is the repository id under the gitops prefix, and a valid known_hosts host field" do
      host_alias = described_class.alias_for(repository)

      expect(host_alias).to eq("#{described_class::HOST_KEY_ALIAS_PREFIX}#{repository.id}")
      expect(host_alias).to match(System::SshHostKeys::ALIAS_FORMAT)
    end
  end
end
