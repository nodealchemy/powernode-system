# frozen_string_literal: true

require "rails_helper"

# IMP-3855ff9908f2 — ingest for the agent's `verify:` probe observation.
#
# The claim this file pins hardest is where clause 2 of the settled design
# stops being aspirational and becomes enforceable:
#
#   A PROBE IS PASSING ONLY WHEN THE REPORT COVERS BOTH SHELLS.
#
# The roll-up is computed HERE, from the agent's per-shell facts, and never
# read from the wire. If it arrived pre-computed, an agent that only ran a
# login shell would report "pass" and the platform would have reproduced the
# VM-9000 bug inside the lane built to catch it.
RSpec.describe System::ModuleVerifyStateWriter do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, node: node, status: "running") }

  def shell(name, status:, resolved: "", message: "")
    { "shell" => name, "status" => status, "resolved" => resolved, "message" => message }
  end

  def probe(shells:, name: "gh-binary", command: "gh", expected: "/usr/local/bin/gh")
    { "name" => name, "command" => command, "expected" => expected, "shells" => shells }
  end

  def module_entry(probes:, module_id: "mod-a", module_name: "gh", declared_count: nil)
    {
      "module_id" => module_id, "module_name" => module_name,
      "declared_count" => declared_count || probes.size,
      "observed_at" => Time.current.utc.iso8601,
      "probes" => probes
    }
  end

  def write!(payload)
    described_class.write!(instance: instance, payload: payload)
  end

  def stored
    instance.reload.config[described_class::CONFIG_KEY]
  end

  describe "absence" do
    it "writes NOTHING when the heartbeat carried no block" do
      expect(write!(nil)).to be_nil
      expect(stored).to be_nil
    end

    it "records an EMPTY module list as its own fact, not as absence" do
      write!([])
      expect(stored["modules"]).to eq([])
      expect(stored["observed_at"]).to be_present
    end
  end

  describe "the roll-up" do
    let(:both_pass) do
      [ shell("login", status: "pass", resolved: "/usr/local/bin/gh"),
        shell("non_login", status: "pass", resolved: "/usr/local/bin/gh") ]
    end

    it "is pass only when BOTH shells are present and both pass" do
      write!([ module_entry(probes: [ probe(shells: both_pass) ]) ])
      p = stored.dig("modules", 0, "probes", 0)
      expect(p["status"]).to eq("pass")
      expect(p["shells_covered"]).to be(true)
    end

    # THE enforcement point. A one-shell report has not tested the thing that
    # broke on VM-9000, so it cannot be a pass.
    it "is UNKNOWN — never pass — when only the login shell reported" do
      write!([ module_entry(probes: [
        probe(shells: [ shell("login", status: "pass", resolved: "/usr/local/bin/gh") ])
      ]) ])
      p = stored.dig("modules", 0, "probes", 0)
      expect(p["status"]).to eq("unknown")
      expect(p["shells_covered"]).to be(false)
    end

    it "is UNKNOWN — never pass — when only the non-login shell reported" do
      write!([ module_entry(probes: [
        probe(shells: [ shell("non_login", status: "pass", resolved: "/usr/local/bin/gh") ])
      ]) ])
      expect(stored.dig("modules", 0, "probes", 0, "status")).to eq("unknown")
    end

    it "is UNKNOWN when no shell reported at all" do
      write!([ module_entry(probes: [ probe(shells: []) ]) ])
      expect(stored.dig("modules", 0, "probes", 0, "status")).to eq("unknown")
    end

    # The shadowed-binary shape: the name resolved in both shells, but the
    # login one resolved to the wrong file.
    it "is FAIL when either shell disagrees, and keeps the resolved path" do
      write!([ module_entry(probes: [ probe(shells: [
        shell("login", status: "fail", resolved: "/usr/bin/gh", message: "resolved to /usr/bin/gh"),
        shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
      ]) ]) ])
      p = stored.dig("modules", 0, "probes", 0)
      expect(p["status"]).to eq("fail")
      expect(p["shells"].find { |s| s["shell"] == "login" }["resolved"]).to eq("/usr/bin/gh")
    end

    it "ignores an agent-supplied status field entirely" do
      payload = [ module_entry(probes: [ probe(shells: [
        shell("login", status: "fail", resolved: "/usr/bin/gh")
      ]).merge("status" => "pass", "shells_covered" => true) ]) ]
      write!(payload)
      p = stored.dig("modules", 0, "probes", 0)
      expect(p["status"]).to eq("fail")
      expect(p["shells_covered"]).to be(false)
    end
  end

  describe "hostile / malformed input" do
    it "coerces an unrecognized shell status to error, never to pass" do
      write!([ module_entry(probes: [ probe(shells: [
        shell("login", status: "green"), shell("non_login", status: "green")
      ]) ]) ])
      p = stored.dig("modules", 0, "probes", 0)
      expect(p["shells"].map { |s| s["status"] }).to eq(%w[error error])
      expect(p["status"]).to eq("unknown")
    end

    it "drops a shell name it does not recognize" do
      write!([ module_entry(probes: [ probe(shells: [
        shell("login", status: "pass", resolved: "/usr/local/bin/gh"),
        shell("non_login", status: "pass", resolved: "/usr/local/bin/gh"),
        shell("interactive", status: "pass", resolved: "/usr/local/bin/gh")
      ]) ]) ])
      expect(stored.dig("modules", 0, "probes", 0, "shells").map { |s| s["shell"] })
        .to eq(%w[login non_login])
    end

    # A duplicate entry for one shell is a producer bug. Letting a later PASS
    # overwrite an earlier FAIL is the one direction that hides a fault.
    it "keeps the FIRST report per shell so a later pass cannot mask a fail" do
      write!([ module_entry(probes: [ probe(shells: [
        shell("login", status: "fail", resolved: "/usr/bin/gh"),
        shell("login", status: "pass", resolved: "/usr/local/bin/gh"),
        shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
      ]) ]) ])
      p = stored.dig("modules", 0, "probes", 0)
      expect(p["shells"].find { |s| s["shell"] == "login" }["status"]).to eq("fail")
      expect(p["status"]).to eq("fail")
    end

    # Robustness against a producer that TRIMS the failing half is not
    # robustness against one that LIES about it. Both `resolved` and
    # `expected` are already on the wire, so a self-contradicting PASS is
    # detectable here and must be.
    it "downgrades a claimed PASS whose resolved path is not the declared one" do
      write!([ module_entry(probes: [ probe(shells: [
        shell("login", status: "pass", resolved: "/usr/bin/gh"),
        shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
      ]) ]) ])
      p = stored.dig("modules", 0, "probes", 0)
      expect(p["shells"].find { |sh| sh["shell"] == "login" }["status"]).to eq("fail")
      expect(p["status"]).to eq("fail")
    end

    # An older producer that omits `resolved` is unmeasured territory, not a
    # liar — and the roll-up's both-shells rule already refuses to call an
    # incomplete report a pass, so this must not be turned into a failure.
    it "leaves a claimed PASS alone when the producer reported no resolved path" do
      write!([ module_entry(probes: [ probe(shells: [
        shell("login", status: "pass"), shell("non_login", status: "pass")
      ]) ]) ])
      expect(stored.dig("modules", 0, "probes", 0, "status")).to eq("pass")
    end

    # Truncating before filtering would let junk shell names evict the two
    # real ones, flipping shells_covered to false and DOWNGRADING a genuine
    # failure into a medium not-measured aggregate.
    it "does not let unrecognized shell names evict the real ones" do
      junk = Array.new(described_class::MAX_SHELLS_PER_PROBE) do |i|
        shell("bogus-#{i}", status: "pass", resolved: "/usr/local/bin/gh")
      end
      write!([ module_entry(probes: [ probe(shells: junk + [
        shell("login", status: "fail", resolved: "/usr/bin/gh"),
        shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
      ]) ]) ])
      p = stored.dig("modules", 0, "probes", 0)
      expect(p["shells"].map { |sh| sh["shell"] }).to eq(%w[login non_login])
      expect(p["shells_covered"]).to be(true)
      expect(p["status"]).to eq("fail")
    end

    it "keeps a nameless probe under a name that says so" do
      write!([ module_entry(probes: [ probe(shells: [], name: "") ]) ])
      expect(stored.dig("modules", 0, "probes", 0, "name")).to eq("unnamed")
    end

    it "records reported_count so dropped probes cannot vanish silently" do
      write!([ module_entry(probes: [ probe(shells: []) ], declared_count: 3) ])
      m = stored["modules"].first
      expect(m["declared_count"]).to eq(3)
      expect(m["reported_count"]).to eq(1)
    end

    it "caps modules, probes, shells, and string lengths" do
      big = Array.new(described_class::MAX_MODULES + 5) do |i|
        module_entry(module_id: "mod-#{i}", probes: [ probe(shells: []) ])
      end
      write!(big)
      expect(stored["modules"].size).to eq(described_class::MAX_MODULES)

      write!([ module_entry(probes: [ probe(shells: [
        shell("login", status: "fail", resolved: "/x" * 400, message: "m" * 900)
      ]) ]) ])
      s = stored.dig("modules", 0, "probes", 0, "shells", 0)
      expect(s["resolved"].length).to be <= described_class::MAX_PATH_CHARS
      expect(s["message"].length).to be <= described_class::MAX_MESSAGE_CHARS
    end
  end

  describe "isolation" do
    it "touches only its own config key" do
      instance.update!(config: instance.config.merge("sdwan_state" => { "keep" => "me" }))
      write!([ module_entry(probes: [ probe(shells: []) ]) ])
      expect(instance.reload.config["sdwan_state"]).to eq({ "keep" => "me" })
    end
  end
end
