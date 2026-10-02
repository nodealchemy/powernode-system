# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

# IMP-fdc3b6a53d77 — Acme::LegoClient shells out to the powernode-acme Go binary, but nothing
# shipped it: agent/Makefile builds dist/powernode-acme-linux-* locally only, the extension-system
# module MASKS agent/dist, and stage15 never staged it, so on every built hub the binary was
# absent and Acme::LegoClient#binary_path raised IntegrationError. Live paths DO reach it (the
# acme provision/renew MCP tools, the renewal sweep, the REST certificates controller).
#
# It now ships beside the agent in powernode-system-base (/usr/sbin/powernode-acme, which every
# node unions), stage15 builds it from the same pinned Go toolchain, and a fail-loud presence
# check (scripts/module-build/verify-acme-binary.sh) refuses a build that did not produce a real,
# runnable binary — the same "hollow erofs" class the agent build already guards against.
RSpec.describe "powernode-acme shipping" do
  let(:ext_root) { File.expand_path("../../..", __dir__) }
  let(:stage15) { File.read(File.join(ext_root, "scripts", "module-build", "stage15.sh")) }
  let(:manifest) { YAML.safe_load_file(File.join(ext_root, "modules", "powernode-system-base", "manifest.yaml")) }
  let(:verifier) { File.join(ext_root, "scripts", "module-build", "verify-acme-binary.sh") }

  describe "the system-base module" do
    it "ships /usr/sbin/powernode-acme in its file_spec" do
      expect(manifest.fetch("file_spec")).to include("/usr/sbin/powernode-acme")
    end

    it "protects it from overlay, like the agent (it receives the DNS provider token)" do
      expect(manifest.fetch("protected_spec")).to include("/usr/sbin/powernode-acme")
    end
  end

  describe "stage15.sh's system-base arm" do
    let(:arm) { stage15[/^\s*powernode-system-base\)(.*?)^\s*base-os-ubuntu-noble\)/m, 1].to_s }

    it "has the arm under test" do
      expect(arm).to include("powernode-agent")
    end

    it "builds powernode-acme from the same pinned toolchain, statically" do
      build = arm[/\( cd agent && \\\n[^)]*\.\/cmd\/powernode-acme \)/m].to_s
      expect(build).to include("CGO_ENABLED=0 GOOS=linux GOARCH=amd64").and include("/usr/local/go/bin/go build -trimpath")
      expect(build).to include("-o /tmp/powernode-acme ./cmd/powernode-acme")
    end

    it "installs it beside the agent and refuses the build unless the shipped file verifies" do
      expect(arm).to include("install -m 0755 /tmp/powernode-acme /tmp/fat/usr/sbin/powernode-acme")
      expect(arm).to match(%r{verify-acme-binary\.sh"?\s+/tmp/fat/usr/sbin/powernode-acme})
    end
  end

  describe "verify-acme-binary.sh (the fail-loud presence check)" do
    let(:dir) { Dir.mktmpdir("acme-verify") }
    let(:binary) { File.join(dir, "powernode-acme") }

    after { FileUtils.remove_entry(dir) }

    def fake(body, mode: 0o755)
      File.write(binary, "#!/bin/sh\n#{body}\n")
      File.chmod(mode, binary)
    end

    def verify(path = binary, *args)
      Open3.capture3("bash", verifier, path, "--min-bytes", "10", *args)
    end

    it "exists as an executable script" do
      expect(File.executable?(verifier)).to be true
    end

    it "accepts a real, executable binary whose `version` subcommand answers JSON" do
      fake(%(echo '{"version":"2026-10-02-abc","git_commit":"abc","build_date":"x"}'))

      _out, err, status = verify

      expect(status.exitstatus).to eq(0), err
    end

    it "refuses a missing file, naming it" do
      _out, err, status = verify(File.join(dir, "absent"))

      expect(status.exitstatus).not_to eq(0)
      expect(err).to include("FATAL").and include("absent")
    end

    it "refuses a symlink (the usrmerge clobber class)" do
      fake(%(echo '{"version":"1"}'))
      link = File.join(dir, "linked")
      File.symlink(binary, link)

      _out, err, status = verify(link)

      expect(status.exitstatus).not_to eq(0)
      expect(err).to include("FATAL").and match(/symlink|regular file/)
    end

    it "refuses a file below the size floor (a hollow build)" do
      fake(%(echo '{"version":"1"}'))

      _out, err, status = Open3.capture3("bash", verifier, binary, "--min-bytes", "1000000")

      expect(status.exitstatus).not_to eq(0)
      expect(err).to include("FATAL").and match(/bytes/)
    end

    it "refuses a file that is not executable" do
      fake(%(echo '{"version":"1"}'), mode: 0o644)

      _out, err, status = verify

      expect(status.exitstatus).not_to eq(0)
      expect(err).to include("FATAL").and include("executable")
    end

    it "refuses a binary whose `version` exits non-zero" do
      fake("exit 3")

      _out, err, status = verify

      expect(status.exitstatus).not_to eq(0)
      expect(err).to include("FATAL").and include("version")
    end

    it "refuses a binary whose `version` prints no JSON version field" do
      fake("echo hello")

      _out, err, status = verify

      expect(status.exitstatus).not_to eq(0)
      expect(err).to include("FATAL").and include("version")
    end

    it "judges stdout only: a stderr line carrying \"version\" does not satisfy the check" do
      fake(%(echo '"version"' >&2\necho hello))

      _out, err, status = verify

      expect(status.exitstatus).not_to eq(0)
      expect(err).to include("FATAL")
    end

    it "runs `version` as the subcommand (the binary has no --version flag)" do
      fake(%(test "$1" = version || exit 9\necho '{"version":"v"}'))

      _out, err, status = verify

      expect(status.exitstatus).to eq(0), err
    end
  end
end
