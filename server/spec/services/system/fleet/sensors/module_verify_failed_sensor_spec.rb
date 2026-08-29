# frozen_string_literal: true

require "rails_helper"

# IMP-3855ff9908f2 — the CONSUMER half of the `verify:` probe oracle.
#
# Three claims this file pins hardest:
#
#   1. A SHADOWED BINARY IS CAUGHT. The incident this feature exists to
#      prevent is a name that resolved — so every existence check passed —
#      to the wrong file. The sensor must raise it, name the shell, and name
#      what the node actually resolved.
#   2. ABSENCE IS NOT HEALTH. A node assigned a probe-declaring module with
#      no usable verdict is NOT MEASURED, and no path renders it as verified.
#      A one-shell report is such an absence, not a weaker pass.
#   3. The lane REACHES A PERSON. A producer with no consumer is the half-lane
#      shape this whole campaign exists to stop, so the wiring block below is
#      as load-bearing as the sensing.
RSpec.describe System::Fleet::Sensors::ModuleVerifyFailedSensor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }

  subject(:signals) { described_class.new(account: account).sense }

  def kinds = signals.map { |s| s[:kind] }
  def failures = signals.select { |s| s[:kind] == "system.module_verify_failed" }
  def not_measured = signals.find { |s| s[:kind] == "system.module_verify_not_measured" }

  # A module whose manifest declares a probe, attached to `node`.
  #
  # ATTACHED THE WAY PRODUCTION ATTACHES IT: a base module reaches a node
  # through an enabled System::NodeModuleAssignment row. NodeModule#node_id is
  # the DEPENDANT-CHILD column (see NodeModule's `for_node` note and
  # NodeApi::ModulesController#node_modules) and ManifestImportService never
  # writes it, so a fixture that set it directly would make this whole file
  # green against a shape the fleet never produces.
  def probe_module(name: "gh", command: "gh", resolves_to: "/usr/local/bin/gh",
                   declared: true, attach_to: node)
    config = declared ? { "verify" => { "probes" => [
      { "name" => "#{name}-binary", "command" => command, "resolves_to" => resolves_to }
    ] } } : {}
    mod = create(:system_node_module, account: account, node_platform: platform,
                 category: category, variety: "subscription", name: name, config: config)
    create(:system_node_module_assignment, node: attach_to, node_module: mod) if attach_to
    mod
  end

  # The OTHER production pathway: a config/instance-variety child created by
  # NodeModuleAssignment#create_dependant!, which carries node_id directly and
  # has NO assignment row. The agent's own resolver honours both, so this
  # sensor must too.
  def dependant_probe_module(parent:, name: "gh-config", resolves_to: "/usr/local/bin/gh")
    create(:system_node_module, account: account, node: node, node_platform: platform,
           category: category, variety: "config", name: name,
           parent_module: parent,
           config: { "verify" => { "probes" => [
             { "name" => "#{name}-binary", "command" => "gh", "resolves_to" => resolves_to }
           ] } })
  end

  def instance!(heartbeat_at: 1.minute.ago)
    create(:system_node_instance, node: node, status: "running", last_heartbeat_at: heartbeat_at)
  end

  def shell(name, status:, resolved: "", message: "")
    { "shell" => name, "status" => status, "resolved" => resolved, "message" => message }
  end

  def record!(instance, modules:, observed_at: Time.current)
    instance.update!(config: instance.config.merge(
      System::ModuleVerifyStateWriter::CONFIG_KEY => {
        "observed_at" => observed_at.utc.iso8601, "modules" => modules
      }
    ))
  end

  def module_report(mod, probes:, observed_at: Time.current, declared_count: nil)
    {
      "module_id" => mod.id, "module_name" => mod.name,
      "declared_count" => declared_count || probes.size,
      "reported_count" => probes.size,
      "observed_at" => observed_at.utc.iso8601,
      "probes" => probes
    }
  end

  def probe_result(status:, shells:, covered: true, name: "gh-binary",
                   command: "gh", expected: "/usr/local/bin/gh")
    { "name" => name, "command" => command, "expected" => expected,
      "status" => status, "shells_covered" => covered, "shells" => shells }
  end

  describe "nothing to verify" do
    it "is silent when no module on the account declares a probe" do
      probe_module(declared: false)
      instance!
      expect(signals).to eq([])
    end

    it "is silent for a node that is not heartbeating (InstanceStatusSensor's alarm)" do
      probe_module
      instance!(heartbeat_at: 2.hours.ago)
      expect(signals).to eq([])
    end
  end

  describe "a shadowed binary" do
    let!(:mod) { probe_module }
    let!(:instance) { instance! }

    before do
      record!(instance, modules: [ module_report(mod, probes: [
        probe_result(status: "fail", shells: [
          shell("login", status: "fail", resolved: "/usr/bin/gh",
                message: "resolved to /usr/bin/gh, manifest declares /usr/local/bin/gh"),
          shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
        ])
      ]) ])
    end

    it "raises system.module_verify_failed at high severity" do
      expect(kinds).to include("system.module_verify_failed")
      expect(failures.first[:severity]).to eq(:high)
    end

    # The finding, verbatim. An operator cannot act on "a probe failed"; they
    # can act on "login shell resolved /usr/bin/gh, manifest says
    # /usr/local/bin/gh".
    it "names the shell, the expected path, and what the node actually resolved" do
      payload = failures.first[:payload]
      expect(payload["expected_path"]).to eq("/usr/local/bin/gh")
      expect(payload["failing_shells"]).to contain_exactly(
        hash_including("shell" => "login", "resolved" => "/usr/bin/gh")
      )
      expect(payload["shadowed"]).to be(true)
      expect(payload["summary"]).to include("/usr/bin/gh").and include("/usr/local/bin/gh")
    end

    it "carries no remediation action — re-serving the same module fixes nothing" do
      expect(failures.first[:payload]["remediation_action"]).to be_nil
    end

    it "fingerprints per (instance, module, probe) so a standing failure dedups" do
      expect(failures.first[:fingerprint])
        .to eq("module_verify_failed:#{instance.id}:#{mod.id}:gh-binary")
    end
  end

  describe "a binary that is simply gone" do
    it "raises a failure that is NOT flagged as shadowed" do
      mod = probe_module(name: "gitleaks", command: "gitleaks",
                         resolves_to: "/usr/local/bin/gitleaks")
      instance = instance!
      record!(instance, modules: [ module_report(mod, probes: [
        probe_result(status: "fail", name: "gitleaks-binary", command: "gitleaks",
                     expected: "/usr/local/bin/gitleaks", shells: [
                       shell("login", status: "fail", message: "command did not resolve on PATH"),
                       shell("non_login", status: "fail", message: "command did not resolve on PATH")
                     ])
      ]) ])
      expect(failures.first[:payload]["shadowed"]).to be(false)
      expect(failures.first[:payload]["summary"]).to include("does not resolve at all")
    end
  end

  describe "absence is not health" do
    let!(:mod) { probe_module }

    it "raises not_measured when the node has never reported" do
      instance!
      expect(kinds).to include("system.module_verify_not_measured")
      expect(not_measured[:payload]["reasons"]).to eq({ "never_reported" => 1 })
      expect(failures).to be_empty
    end

    it "raises not_measured when the report is stale" do
      instance = instance!
      record!(instance, observed_at: 3.hours.ago, modules: [])
      expect(not_measured[:payload]["reasons"]).to eq({ "stale_report" => 1 })
    end

    it "raises not_measured when the report omits this module" do
      instance = instance!
      record!(instance, modules: [])
      expect(not_measured[:payload]["reasons"]).to eq({ "no_module_report" => 1 })
    end

    # The agent's OWN clock. A wedged probe loop keeps re-shipping a frozen
    # snapshot that the server would otherwise re-stamp as fresh every tick.
    it "raises not_measured when the module's own probe timestamp is stale" do
      instance = instance!
      record!(instance, modules: [ module_report(mod, observed_at: 3.hours.ago, probes: [
        probe_result(status: "pass", shells: [
          shell("login", status: "pass", resolved: "/usr/local/bin/gh"),
          shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
        ])
      ]) ])
      expect(not_measured[:payload]["reasons"]).to eq({ "stale_probe" => 1 })
      expect(failures).to be_empty
    end

    # THE clause-2 consumer assertion. A probe that ran one shell has not
    # tested the divergence that broke VM-9000, and must never read as a pass.
    it "raises not_measured for a probe whose report covers only one shell" do
      instance = instance!
      record!(instance, modules: [ module_report(mod, probes: [
        probe_result(status: "unknown", covered: false, shells: [
          shell("login", status: "pass", resolved: "/usr/local/bin/gh")
        ])
      ]) ])
      expect(not_measured[:payload]["reasons"]).to eq({ "shells_not_covered" => 1 })
      expect(failures).to be_empty
    end

    it "raises not_measured when the agent ran fewer probes than declared" do
      instance = instance!
      record!(instance, modules: [ module_report(mod, declared_count: 3, probes: [
        probe_result(status: "pass", shells: [
          shell("login", status: "pass", resolved: "/usr/local/bin/gh"),
          shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
        ])
      ]) ])
      expect(not_measured[:payload]["reasons"]).to eq({ "partial_report" => 1 })
    end

    # A module report carrying no probes at all must not read as clean. It is
    # the shape a producer-side type drift produces (declared_count arriving
    # as something integer_or_nil rejects makes nil.to_i == 0, silently
    # disabling the partial_report guard), and it would otherwise emit
    # neither a failure nor an absence.
    it "raises not_measured when a module report carries no probes" do
      instance = instance!
      record!(instance, modules: [ module_report(mod, probes: []).merge("declared_count" => nil) ])
      expect(not_measured[:payload]["reasons"]).to eq({ "no_probes_reported" => 1 })
      expect(failures).to be_empty
    end

    it "aggregates to ONE signal per account so a rollout is not a storm" do
      3.times { instance! }
      expect(signals.count { |s| s[:kind] == "system.module_verify_not_measured" }).to eq(1)
      expect(not_measured[:payload]["observation_count"]).to eq(3)
      expect(not_measured[:fingerprint]).to eq("module_verify_not_measured:#{account.id}")
    end
  end

  describe "a clean node" do
    it "is silent when both shells agree with the manifest" do
      mod = probe_module
      instance = instance!
      record!(instance, modules: [ module_report(mod, probes: [
        probe_result(status: "pass", shells: [
          shell("login", status: "pass", resolved: "/usr/local/bin/gh"),
          shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
        ])
      ]) ])
      expect(signals).to eq([])
    end
  end

  describe "account isolation" do
    # A second account with the SAME shape — a probe-declaring module and a
    # live instance that has never reported. Without scoping, its instance
    # would appear in this account's not_measured payload.
    it "never reads another account's instances" do
      probe_module
      ours = instance!

      other          = create(:account)
      other_platform = create(:system_node_platform, account: other)
      other_category = create(:system_node_module_category, account: other)
      other_template = create(:system_node_template, account: other)
      other_node     = create(:system_node, account: other, node_template: other_template)
      other_mod = create(:system_node_module, account: other,
             node_platform: other_platform, category: other_category,
             variety: "subscription", name: "gh-other",
             config: { "verify" => { "probes" => [
               { "name" => "gh-binary", "command" => "gh", "resolves_to" => "/usr/local/bin/gh" }
             ] } })
      create(:system_node_module_assignment, node: other_node, node_module: other_mod)
      theirs = create(:system_node_instance, node: other_node, status: "running",
                      last_heartbeat_at: 1.minute.ago)

      reported = not_measured[:payload]["instances"].map { |i| i["instance_id"] }
      expect(reported).to eq([ ours.id ])
      expect(reported).not_to include(theirs.id)
    end
  end

  # THE ATTACH PATHWAY, asserted directly. This is the link the first version
  # of this sensor got wrong: it read System::NodeModule#node_id, which for a
  # manifest-imported base module is NULL, so the sweep matched no instance and
  # the whole lane was inert in production while every spec was green. Both
  # production pathways are pinned here so a future refactor cannot quietly
  # re-break one of them.
  describe "attach pathways" do
    it "sees a base module attached by an enabled assignment row" do
      mod = probe_module
      instance = instance!
      record!(instance, modules: [ module_report(mod, probes: [
        probe_result(status: "fail", shells: [ shell("login", status: "fail", resolved: "/usr/bin/gh") ])
      ]) ])
      expect(failures.map { |f| f[:payload]["module_id"] }).to eq([ mod.id ])
    end

    it "sees a dependant child, which carries node_id and has no assignment row" do
      parent = probe_module(declared: false)
      child  = dependant_probe_module(parent: parent)
      instance = instance!
      record!(instance, modules: [ module_report(child, probes: [
        probe_result(status: "fail", name: "gh-config-binary",
                     shells: [ shell("login", status: "fail", resolved: "/usr/bin/gh") ])
      ]) ])
      expect(failures.map { |f| f[:payload]["module_id"] }).to include(child.id)
    end

    it "ignores a module whose assignment is disabled" do
      mod = probe_module(attach_to: nil)
      create(:system_node_module_assignment, node: node, node_module: mod, enabled: false)
      instance!
      expect(signals).to eq([])
    end
  end

  describe "wiring" do
    it "is registered in the fleet sense pass" do
      expect(System::Fleet::FleetAutonomyService::SENSORS).to include(described_class)
    end

    it "routes both kinds to the notify-level investigate category" do
      bindings = System::Fleet::DecisionEngine::SIGNAL_BINDINGS
      %w[system.module_verify_failed system.module_verify_not_measured].each do |kind|
        expect(bindings).to have_key(kind)
        expect(bindings[kind][:action_category]).to eq("system.module_verify_investigate")
        expect(bindings[kind][:skill]).to be_nil
      end
    end

    # NOT system.observation: the fleet seed maps that category to
    # auto_approve, which files the signal for dashboards without ever
    # reaching an operator.
    it "seeds the gate policy on the agent that runs the sense pass" do
      # Read the DECLARATION, not the seed text. These policy sets moved out
      # of fleet_autonomy_agent.rb into System::Governance::PolicyDeclarations
      # so the boot reconciler can assert them against a RUNNING database;
      # the seed now consumes that constant. Grepping the seed file for a
      # literal tested a string that no longer lives there, while the
      # property it cares about moved with the constant.
      expect(System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES)
        .to include("system.module_verify_investigate" => "notify_and_proceed")
    end

    # Membership is DECLARED, never inferred. Without it the standing
    # fingerprint of a permanently broken node scores ineffective every settle
    # window until F3-11 manufactures a false fleet.remediation_stuck
    # escalation on a lane that never actuated anything.
    it "is declared non-remediating so it stays out of the validate arc" do
      expect(System::Fleet::RemediationValidator::NON_REMEDIATING_ACTION_CATEGORIES)
        .to include("system.module_verify_investigate")
    end

    it "registers the category so an operator can retune it" do
      expect(Ai::InterventionPolicy.category_registered?("system.module_verify_investigate")).to be(true)
    end

    # The metric.* FleetEvent -> Slo::TelemetryAdapter -> ScoreEvaluator lane
    # is DORMANT by operator decision. This sensor is an ordinary Signal on
    # the live transport and must stay out of it.
    it "stays out of the dormant SLO telemetry lane" do
      mod = probe_module
      instance = instance!
      record!(instance, modules: [ module_report(mod, probes: [
        probe_result(status: "fail", shells: [ shell("login", status: "fail", resolved: "/usr/bin/gh") ])
      ]) ])
      expect(kinds.grep(/\Ametric\./)).to be_empty
      expect(kinds).to all(start_with("system."))
    end
  end

  describe "thresholds are DB-driven" do
    it "honours a per-account freshness override" do
      mod = probe_module
      instance = instance!
      record!(instance, modules: [ module_report(mod, observed_at: 20.minutes.ago, probes: [
        probe_result(status: "pass", shells: [
          shell("login", status: "pass", resolved: "/usr/local/bin/gh"),
          shell("non_login", status: "pass", resolved: "/usr/local/bin/gh")
        ])
      ]) ])
      # Default window (15m) marks the 20-minute-old probe stale...
      expect(not_measured[:payload]["reasons"]).to eq({ "stale_probe" => 1 })

      account.update!(settings: (account.settings || {}).merge(
        "module_verify_report_fresh_seconds" => 3600
      ))
      expect(described_class.new(account: account.reload).sense).to eq([])
    end
  end
end
