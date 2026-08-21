# frozen_string_literal: true

require "rails_helper"

# System::CoreMirrorPreflight — the DISPATCH-time half of the core-provenance
# protection. System::CoreProvenanceGate catches a stale-mirror build at
# PROMOTE, after a full Class-B build has already burned; this reads the
# mirror's HEAD before any builder is leased and refuses the dispatch instead.
#
# The design point under test is that this has THREE outcomes, not two:
# agreed / diverged / undetermined. "Could not read the mirror" is NOT MEASURED
# — neither healthy nor faulty — and must never refuse, or a network blip
# bricks every Class-B build fleet-wide.
RSpec.describe System::CoreMirrorPreflight do
  let(:expected) { "409c706ecd758a04f2237fdb8f2a1092106b903d" }
  let(:stale)    { "b3bc6908e9f9078797488f7e48e61970b78718b0" }

  # A real smart-HTTP ref advertisement, pkt-line framed exactly as
  # github.com answers `git clone` — the 4-hex length prefix runs straight
  # into the sha with no separator, which is the parsing trap.
  def advertisement(head_sha:, extra_refs: true)
    body = +"001e# service=git-upload-pack\n0000"
    body << "0155#{head_sha} HEAD\0multi_ack thin-pack side-band-64k " \
            "symref=HEAD:refs/heads/develop object-format=sha1 agent=git/2.43.0\n"
    if extra_refs
      body << "003f#{head_sha} refs/heads/develop\n"
      body << "003f#{stale} refs/heads/master\n"
    end
    body << "0000"
    body
  end

  def stub_mirror(status: 200, body: advertisement(head_sha: expected))
    stub_request(:get, "https://github.com/nodealchemy/powernode-platform.git/info/refs")
      .with(query: { "service" => "git-upload-pack" })
      .to_return(status: status, body: body)
  end

  describe ".resolve_mirror_tip" do
    # The builder clones with a bare `git clone --depth 1 <url>` and NO ref, so
    # it lands on the remote's HEAD. HEAD is therefore the only tip worth
    # comparing — a branch-name lookup would answer a question nobody asked.
    it "reads the sha the mirror advertises for HEAD" do
      stub_mirror

      expect(described_class.resolve_mirror_tip).to eq(expected)
    end

    it "asks the same URL the builder's clone would, so it cannot check a different repo" do
      req = stub_mirror

      described_class.resolve_mirror_tip

      expect(req).to have_been_requested
    end

    it "follows the operator's mirror override rather than the compiled-in default" do
      SiteSetting.set("ci_core_mirror_host", "mirror.example.com", setting_type: "string")
      SiteSetting.set("ci_core_mirror_path", "someone/powernode-platform", setting_type: "string")
      req = stub_request(:get, "https://mirror.example.com/someone/powernode-platform.git/info/refs")
            .with(query: { "service" => "git-upload-pack" })
            .to_return(status: 200, body: advertisement(head_sha: expected))

      expect(described_class.resolve_mirror_tip).to eq(expected)
      expect(req).to have_been_requested
    end

    # Every one of these is NOT MEASURED, and every one of them must come back
    # nil rather than raise — the caller is a synchronous dispatch path.
    it "returns nil (never raises) on a non-200" do
      stub_mirror(status: 503, body: "upstream unavailable")

      expect(described_class.resolve_mirror_tip).to be_nil
    end

    it "returns nil when the advertisement carries no HEAD" do
      stub_mirror(body: "001e# service=git-upload-pack\n00000000")

      expect(described_class.resolve_mirror_tip).to be_nil
    end

    it "returns nil on an empty body" do
      stub_mirror(body: "")

      expect(described_class.resolve_mirror_tip).to be_nil
    end

    it "returns nil on a connection timeout" do
      stub_request(:get, %r{github\.com/nodealchemy/powernode-platform}).to_timeout

      expect(described_class.resolve_mirror_tip).to be_nil
    end

    it "returns nil on a socket-level failure" do
      stub_request(:get, %r{github\.com/nodealchemy/powernode-platform})
        .to_raise(SocketError.new("getaddrinfo: Name or service not known"))

      expect(described_class.resolve_mirror_tip).to be_nil
    end

    it "returns nil rather than calling out at all when the mirror repo is unconfigured" do
      allow(described_class).to receive(:mirror_path).and_return("")

      expect(described_class.resolve_mirror_tip).to be_nil
      expect(a_request(:get, %r{info/refs})).not_to have_been_made
    end

    # The real protocol-v1 advertisement separates the ref name from the
    # capability list with a NUL, not a space — the one parsing detail most
    # likely to break, and invisible in a space-separated fixture.
    it "parses the NUL-framed advertisement a real git remote sends" do
      stub_mirror(body: "001e# service=git-upload-pack\n0000" \
                        "0155#{expected} HEAD\u0000multi_ack symref=HEAD:refs/heads/develop agent=git/2.43.0\n" \
                        "003f#{stale} refs/heads/master\n0000")

      expect(described_class.resolve_mirror_tip).to eq(expected)
    end

    it "refuses to pull in a body far larger than a ref advertisement" do
      stub_request(:get, "https://github.com/nodealchemy/powernode-platform.git/info/refs")
        .with(query: { "service" => "git-upload-pack" })
        .to_return(status: 200, body: advertisement(head_sha: expected),
                   headers: { "Content-Length" => (described_class::MAX_ADVERTISEMENT_BYTES + 1).to_s })

      expect(described_class.resolve_mirror_tip).to be_nil
    end

    # dispatch! runs synchronously from the MCP tool AND from
    # CiRunnerLeaseSweepService's sweep loop. An unbounded call here would
    # stall lease sweeping fleet-wide the moment github.com is slow — which,
    # on a default-deny-egress host, is the NORMAL case.
    it "bounds the call with explicit short timeouts" do
      expect(described_class::OPEN_TIMEOUT).to be <= 5
      expect(described_class::READ_TIMEOUT).to be <= 10
    end
  end

  describe ".check — the three states" do
    it "AGREES, without refusing, when the mirror is at the expected core commit" do
      stub_mirror(body: advertisement(head_sha: expected))

      v = described_class.check(expected_sha: expected, expected_repo: "powernode/powernode-platform")

      expect(v.state).to eq("agreed")
      expect(v.refuse?).to be false
      expect(v.mirror_sha).to eq(expected)
    end

    it "DIVERGES, and refuses, when the mirror's HEAD is a different commit" do
      stub_mirror(body: advertisement(head_sha: stale))

      v = described_class.check(expected_sha: expected, expected_repo: "powernode/powernode-platform")

      expect(v.state).to eq("diverged")
      expect(v.refuse?).to be true
    end

    # The 2026-08-15 incident was the RIGHT branch name on the WRONG host, so
    # a sha alone reads as entirely plausible. A refusal an operator cannot act
    # on is a refusal they will switch off.
    it "names BOTH remotes and BOTH shas in a divergence refusal" do
      stub_mirror(body: advertisement(head_sha: stale))

      v = described_class.check(expected_sha: expected, expected_repo: "powernode/powernode-platform")

      expect(v.reason).to include("github.com/nodealchemy/powernode-platform")
      expect(v.reason).to include("powernode/powernode-platform")
      expect(v.reason).to include(stale[0, 7])
      expect(v.reason).to include(expected[0, 7])
    end

    # THE design point. Absence of an observation is not the negation of one.
    it "is UNDETERMINED, and does NOT refuse, when the mirror cannot be read" do
      stub_request(:get, %r{github\.com/nodealchemy/powernode-platform}).to_timeout

      v = described_class.check(expected_sha: expected, expected_repo: "powernode/powernode-platform")

      expect(v.state).to eq("undetermined")
      expect(v.refuse?).to be false
      expect(v.mirror_sha).to be_nil
    end

    it "says out loud that an undetermined check was NOT PERFORMED" do
      stub_request(:get, %r{github\.com/nodealchemy/powernode-platform}).to_timeout

      v = described_class.check(expected_sha: expected, expected_repo: "powernode/powernode-platform")

      expect(v.reason).to match(/not performed|not measured/i)
    end

    # A branch name, or a prefix too short to be an identity, says NOTHING
    # about the mirror. CoreProvenanceGate#same_commit? answers false for both,
    # and reading that false as "diverged" would refuse a build over operator
    # input — head_sha is validated for presence only, and the MCP dispatch
    # tool takes it as a free string.
    it "does not refuse an expectation that is not a comparable commit identity" do
      stub_mirror(body: advertisement(head_sha: stale))

      v = described_class.check(expected_sha: expected[0, 7], expected_repo: "powernode/powernode-platform")

      expect(v.state).to eq("unusable_expectation")
      expect(v.refuse?).to be false
    end

    it "does not refuse a branch name recorded where a sha was expected" do
      stub_mirror(body: advertisement(head_sha: stale))

      v = described_class.check(expected_sha: "develop", expected_repo: "powernode/powernode-platform")

      expect(v.state).to eq("unusable_expectation")
      expect(v.refuse?).to be false
    end

    it "makes no network call for an expectation it cannot compare" do
      described_class.check(expected_sha: "develop", expected_repo: "powernode/powernode-platform")

      expect(a_request(:get, %r{info/refs})).not_to have_been_made
    end

    it "does not refuse when there is no expectation to compare against" do
      v = described_class.check(expected_sha: nil, expected_repo: "powernode/powernode-platform")

      expect(v.state).to eq("no_expectation")
      expect(v.refuse?).to be false
    end

    it "makes no network call at all when there is no expectation" do
      described_class.check(expected_sha: "  ", expected_repo: "powernode/powernode-platform")

      expect(a_request(:get, %r{info/refs})).not_to have_been_made
    end

    # Two full shas from two git remotes are the normal case, but either side
    # may legitimately arrive abbreviated. Refusing a build because one side
    # was short is a false positive, and a gate that cries wolf gets turned off.
    it "treats a long-enough abbreviation of the same commit as agreement" do
      stub_mirror(body: advertisement(head_sha: expected))

      v = described_class.check(expected_sha: expected[0, 12], expected_repo: "powernode/powernode-platform")

      expect(v.state).to eq("agreed")
    end
  end

  describe "operator kill switch" do
    it "is enabled when the setting was never written" do
      expect(described_class.enabled?).to be true
    end

    it "passes a divergence through when disabled, without refusing" do
      SiteSetting.set(described_class::ENABLED_SETTING, "false", setting_type: "string")
      stub_mirror(body: advertisement(head_sha: stale))

      v = described_class.check(expected_sha: expected, expected_repo: "powernode/powernode-platform")

      expect(v.state).to eq("disabled")
      expect(v.refuse?).to be false
    end

    it "makes no network call when disabled" do
      SiteSetting.set(described_class::ENABLED_SETTING, "false", setting_type: "string")

      described_class.check(expected_sha: expected, expected_repo: "powernode/powernode-platform")

      expect(a_request(:get, %r{info/refs})).not_to have_been_made
    end

    # SiteSetting returns a real Integer for setting_type "integer", and 0 is
    # TRUTHY in Ruby — an operator writing 0 to mean "off" must not get a
    # switch that silently does nothing.
    it "treats an integer 0 as off" do
      SiteSetting.set(described_class::ENABLED_SETTING, "0", setting_type: "integer")

      expect(described_class.enabled?).to be false
    end

    it "treats a boolean false as off" do
      allow(SiteSetting).to receive(:get).with(described_class::ENABLED_SETTING).and_return(false)

      expect(described_class.enabled?).to be false
    end

    it "stays enabled when the SiteSetting lookup itself raises" do
      allow(SiteSetting).to receive(:get).and_raise(StandardError, "settings table gone")

      expect(described_class.enabled?).to be true
    end
  end
end
