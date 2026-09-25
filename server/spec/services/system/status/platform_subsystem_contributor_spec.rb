# frozen_string_literal: true

require "rails_helper"

# Campaign 01a08c9b increment B1 (design §4.4/§4.5) — the control plane's own
# components as status rows.
RSpec.describe System::Status::Contributors::PlatformSubsystemContributor do
  let(:account)     { create(:account) }
  let(:contributor) { described_class.new }
  let(:probe)       { System::Platform::CompositeHealthProbe }
  let(:keys)        { probe::SUBSYSTEMS.map(&:to_s) }

  def snapshot!(subsystems:, captured_at: Time.current, overall: "ok")
    System::PlatformHealthSnapshot.create!(
      account: account, overall: overall, subsystems: subsystems,
      captured_at: captured_at, source: "spec"
    )
  end

  def all_ok_subsystems(extra = {})
    keys.index_with { |_key| { "status" => "ok", "observed_via" => "spec" } }.merge(extra)
  end

  def components
    [].tap { |acc| contributor.each_component(account) { |record| acc << record } }
  end

  def condition(record, type)
    contributor.conditions_for(record).find { |c| c["type"] == type }
  end

  def verdict(record)
    Platform::Status::Condition.verdict_for_set(contributor.conditions_for(record))
  end

  describe "the component set" do
    it "is exactly the probe's declared subsystems, derived not restated" do
      expect(components.map(&:key)).to eq(keys)
      expect(components.size).to eq(probe::SUBSYSTEMS.size)
    end

    it "emits a subsystem the probe adds, with no edit to the contributor" do
      # The whole point of deriving from SUBSYSTEMS. Both arms: the invented
      # key appears, and it disappears again when the constant no longer
      # carries it.
      baseline = probe::SUBSYSTEMS.size
      stub_const("#{probe}::SUBSYSTEMS", (probe::SUBSYSTEMS + [ :quantum_link ]).freeze)

      expect(components.map(&:key)).to include("quantum_link")
      expect(components.size).to eq(baseline + 1)
    end

    it "uses the subsystem key as the ref, stable across sweeps" do
      snapshot!(subsystems: all_ok_subsystems)
      first = components.map { |r| contributor.ref_for(r) }
      second = components.map { |r| contributor.ref_for(r) }

      expect(first).to eq(keys)
      expect(second).to eq(first)
    end
  end

  describe "a fresh snapshot" do
    before { snapshot!(subsystems: all_ok_subsystems(mixed_entries)) }

    let(:mixed_entries) do
      {
        "postgres" => { "status" => "down", "error" => "Errno::ECONNREFUSED: refused",
                        "observed_via" => "SELECT 1" },
        "sdwan" => { "status" => "degraded", "observed_via" => "BGP session state",
                     "bgp" => { "total" => 3, "established" => 1 } },
        "mcp_endpoint" => { "status" => "not_measured", "reason" => "no health endpoint configured",
                            "configure_with" => "system.platform_health.mcp_health_url" }
      }
    end

    it "gives each subsystem the verdict its probe status argues for" do
      by_key = components.index_by(&:key)

      expect(verdict(by_key["rails"])).to eq(Platform::ComponentStatus::OK)
      expect(verdict(by_key["postgres"])).to eq(Platform::ComponentStatus::DOWN)
      expect(verdict(by_key["sdwan"])).to eq(Platform::ComponentStatus::DEGRADED)
      expect(verdict(by_key["mcp_endpoint"])).to eq(Platform::ComponentStatus::NOT_MEASURED)
    end

    it "marks every component Fresh" do
      components.each do |record|
        fresh = condition(record, "Fresh")
        expect(fresh["status"]).to be(true), "#{record.key} was not fresh"
        expect(fresh["reason"]).to eq("SnapshotFresh")
      end
    end

    it "carries the probe's own prose and evidence through rather than summarising it" do
      postgres = condition(components.find { |r| r.key == "postgres" }, "Healthy")

      expect(postgres["reason"]).to eq("Down")
      expect(postgres["severity"]).to eq("down")
      expect(postgres["message"]).to include("Errno::ECONNREFUSED")
      expect(postgres["evidence"]).to include("observed_via" => "SELECT 1")
      # `status` is the condition's own field; duplicating it into evidence
      # would give a reader two places to disagree.
      expect(postgres["evidence"]).not_to have_key("status")
    end

    it "reserves the down severity for down, so degraded cannot silently escalate" do
      sdwan = condition(components.find { |r| r.key == "sdwan" }, "Healthy")

      expect(sdwan["status"]).to be(false)
      expect(sdwan["reason"]).to eq("Degraded")
      expect(sdwan["severity"]).to be_nil
    end

    it "reports the snapshot's captured_at as observed_at, not the sweep time" do
      captured = 3.minutes.ago.change(usec: 0)
      System::PlatformHealthSnapshot.delete_all
      snapshot!(subsystems: all_ok_subsystems, captured_at: captured)

      expect(contributor.observed_at_for(components.first)).to be_within(1.second).of(captured)
    end
  end

  describe "a stale snapshot" do
    let(:interval) { System::Platform::ScheduledHealthCheckService::DEFAULT_INTERVAL_MINUTES }

    before { snapshot!(subsystems: all_ok_subsystems, captured_at: (interval * 3).minutes.ago) }

    it "goes Fresh=false with reason SnapshotStale" do
      fresh = condition(components.first, "Fresh")

      expect(fresh["status"]).to be(false)
      expect(fresh["reason"]).to eq("SnapshotStale")
      expect(fresh["evidence"]).to include("stale_after_seconds" => interval * 2 * 60)
    end

    it "degrades a component whose stored reading was ok" do
      # DECIDED, and stated: staleness ALONE degrades. Every stored entry says
      # ok, so the only thing arguing for anything else is the Fresh condition
      # — and a status plane serving a stale ok is the lie this plane exists to
      # end.
      record = components.first
      expect(condition(record, "Healthy")["status"]).to be(true)
      expect(verdict(record)).to eq(Platform::ComponentStatus::DEGRADED)
    end

    it "follows the configured interval rather than a hardcoded window" do
      SiteSetting.set(System::Platform::ScheduledHealthCheckService::INTERVAL_SETTING,
                      (interval * 4).to_s, setting_type: "integer")

      # The same snapshot, now inside 2x a much wider interval.
      expect(condition(components.first, "Fresh")["status"]).to be(true)
    end
  end

  describe "an account with no snapshot" do
    # The two cases have different fixes and only one resolves itself, so the
    # contributor RESOLVES which applies rather than asserting the common one.
    # Each arm is pinned on the reason token and the evidence cause — the
    # FACTS — not on the prose.
    def stub_bound_clone(returns: nil, raises: nil)
      scheduler = instance_double(System::Platform::ScheduledHealthCheckService)
      allow(System::Platform::ScheduledHealthCheckService)
        .to receive(:new).with(account: account).and_return(scheduler)
      if raises
        allow(scheduler).to receive(:send).with(:bound_agent_clone).and_raise(raises)
      else
        allow(scheduler).to receive(:send).with(:bound_agent_clone).and_return(returns)
      end
    end

    it "emits one not_measured row per known subsystem, never zero rows" do
      expect(components.size).to eq(probe::SUBSYSTEMS.size)

      components.each do |record|
        expect(verdict(record)).to eq(Platform::ComponentStatus::NOT_MEASURED)
      end
    end

    it "reports NoBoundAgentClone when the scheduler will never run for this account" do
      stub_bound_clone(returns: nil)

      healthy = condition(components.first, "Healthy")

      expect(healthy["reason"]).to eq("NoBoundAgentClone")
      expect(healthy["evidence"]).to include("cause" => "no_bound_agent_clone")
      expect(healthy["message"]).to include("none will be")
    end

    it "reports NoSnapshot when the clone exists and the check simply has not run" do
      stub_bound_clone(returns: create(:ai_agent, account: account))

      healthy = condition(components.first, "Healthy")
      fresh = condition(components.first, "Fresh")

      # The distinction is the whole fix: an install in its first fifteen
      # minutes must not read as a structurally broken account.
      expect(healthy["reason"]).to eq("NoSnapshot")
      expect(healthy["evidence"]).to include("cause" => "not_yet_run")
      expect(fresh["reason"]).to eq("NoSnapshot")
    end

    it "does not claim either cause when the lookup itself failed" do
      stub_bound_clone(raises: RuntimeError.new("bindings unavailable"))

      healthy = condition(components.first, "Healthy")

      expect(healthy["reason"]).to eq("NoSnapshot")
      expect(healthy["evidence"]).to include("cause" => "unresolved")
      expect(healthy["evidence"]["error"]).to include("bindings unavailable")
    end

    it "resolves the cause once per sweep, not once per subsystem" do
      scheduler = instance_double(System::Platform::ScheduledHealthCheckService)
      allow(System::Platform::ScheduledHealthCheckService)
        .to receive(:new).with(account: account).and_return(scheduler)
      allow(scheduler).to receive(:send).with(:bound_agent_clone).and_return(nil)

      components

      expect(scheduler).to have_received(:send).with(:bound_agent_clone).once
    end

    it "leaves observed_at to the sweep, since the absence was learned now" do
      expect(contributor.observed_at_for(components.first)).to be_nil
    end
  end

  describe "a snapshot missing a subsystem the probe now declares" do
    before do
      snapshot!(subsystems: all_ok_subsystems.except("federation"))
    end

    it "reports SubsystemAbsent, distinct from NoSnapshot and from NotObserved" do
      federation = condition(components.find { |r| r.key == "federation" }, "Healthy")

      expect(federation["status"]).to eq("unknown")
      expect(federation["reason"]).to eq("SubsystemAbsent")
      expect(verdict(components.find { |r| r.key == "federation" }))
        .to eq(Platform::ComponentStatus::NOT_MEASURED)
    end

    it "still reports the rest of the snapshot normally" do
      rails = components.find { |r| r.key == "rails" }

      expect(condition(rails, "Healthy")["reason"]).to eq("Ok")
      expect(verdict(rails)).to eq(Platform::ComponentStatus::OK)
    end
  end

  describe "presentation contract" do
    it "declares the kind, account scoping and a string icon" do
      expect(contributor.kind).to eq("platform_subsystem")
      expect(described_class::KIND).to eq("platform_subsystem")
      expect(contributor.account_scoped?).to be(true)
      expect(contributor.presentation["icon"]).to be_a(String)
      expect(contributor.presentation["group_order"]).to eq(10)
    end

    # fc-47: the Platform › Health sub-tab was deleted (its rows are on
    # /app/status itself), so the link goes to the Platform page.
    it "links to the Platform page" do
      expect(contributor.links_for(nil))
        .to eq([ { "label" => "Platform", "path" => "/app/system/compute/platform" } ])
    end

    # fc-47 review M4: its probe already reports postgres, redis and sidekiq,
    # so core's core_service contributor must not add a second row for each.
    it "claims the core services its probe already reports" do
      expect(contributor.reports_core_services).to eq(%w[database redis sidekiq])
    end

    it "makes core_service leave those services out while registered" do
      Platform::Status::Registry.register(described_class::KIND, contributor)

      expect(Platform::Status::Contributors::CoreService.new.services_to_measure).to eq(%i[disk memory cpu])
    end

    it "offers no actions, because platform_subsystem is not_actuatable by default" do
      expect(contributor.actions_for(nil)).to eq([])
    end

    it "declares no dependencies, because the probe declares no edges" do
      expect(contributor.dependencies_for(nil)).to eq([])
    end

    it "humanizes a subsystem it has no display name for" do
      stub_const("#{probe}::SUBSYSTEMS", (probe::SUBSYSTEMS + [ :quantum_link ]).freeze)
      record = components.find { |r| r.key == "quantum_link" }

      expect(contributor.display_name_for(record)).to eq("Quantum link")
      expect(contributor.display_name_for(components.find { |r| r.key == "mcp_endpoint" }))
        .to eq("MCP endpoint")
    end
  end
end
