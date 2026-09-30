# frozen_string_literal: true

require "rails_helper"

# IMP-1e5db5e6aefb — the endpoint a GitOps SSH remote actually connects to.
# ssh-keyscan needs the host and port, and the known_hosts alias must be the
# same for every sync of one repository, whatever the URL's spelling.
RSpec.describe System::Gitops::SshRemote do
  describe ".parse" do
    it "reads an scp-style remote (git@host:path) as host on port 22" do
      endpoint = described_class.parse("git@git.example.test:powernode/fleet-config.git")

      expect(endpoint).to have_attributes(host: "git.example.test", port: 22, user: "git")
    end

    it "reads an ssh:// remote with no port as port 22" do
      endpoint = described_class.parse("ssh://git.example.test/powernode/fleet-config.git")

      expect(endpoint).to have_attributes(host: "git.example.test", port: 22, user: nil)
    end

    it "reads an explicit port and user off an ssh:// remote" do
      endpoint = described_class.parse("ssh://git@git.example.test:2222/powernode/fleet-config.git")

      expect(endpoint).to have_attributes(host: "git.example.test", port: 2222, user: "git")
    end

    it "reads a bracketed IPv6 literal off an ssh:// remote" do
      endpoint = described_class.parse("ssh://git@[fd00::1]:2222/fleet.git")

      expect(endpoint).to have_attributes(host: "fd00::1", port: 2222)
    end

    it "returns nil for an https remote" do
      expect(described_class.parse("https://git.example.test/fleet.git")).to be_nil
    end

    it "returns nil for an scp-style remote whose host is not a host" do
      expect(described_class.parse("git@-evil:path")).to be_nil
      expect(described_class.parse("git@host name:path")).to be_nil
    end

    it "returns nil for a port outside 1..65535" do
      expect(described_class.parse("ssh://git.example.test:0/fleet.git")).to be_nil
      expect(described_class.parse("ssh://git.example.test:70000/fleet.git")).to be_nil
    end

    it "returns nil for a blank or non-string value" do
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse("")).to be_nil
    end
  end

  describe ".ssh?" do
    it "is true for git@ and ssh:// remotes and false for https" do
      expect(described_class.ssh?("git@git.example.test:fleet.git")).to be(true)
      expect(described_class.ssh?("ssh://git.example.test/fleet.git")).to be(true)
      expect(described_class.ssh?("https://git.example.test/fleet.git")).to be(false)
    end

    # ssh? is "an endpoint this module can pin": the git-builtin ssh schemes
    # are not taught to the parser (no legacy spellings) and an unparseable
    # host is not an ssh remote either, so the sync refuses both instead of
    # handing git a URL it would route to the PATH ssh on its own.
    it "is false for git+ssh://, ssh+git:// and an unparseable ssh host" do
      expect(described_class.ssh?("git+ssh://git.example.test/fleet.git")).to be(false)
      expect(described_class.ssh?("ssh+git://git.example.test/fleet.git")).to be(false)
      expect(described_class.ssh?("git@-evil:fleet.git")).to be(false)
      expect(described_class.ssh?("ssh://git.example.test:0/fleet.git")).to be(false)
    end
  end
end
