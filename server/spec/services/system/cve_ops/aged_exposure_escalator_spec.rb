# frozen_string_literal: true

require "rails_helper"

# IMP-60717919d4a0 — the alarm for an unremediated critical/high exposure used
# to EXPIRE: CvePublishedSensor selects `detected_at > lookback.ago`, and
# `detected_at` is written once (CveExposure#record_match) and refreshed only
# when an sbom match confirms a row that had no version evidence
# (IMP-7bba0413c36a), never by an ordinary re-match — so an exposure left
# `open` fell out of the sensor's view a day after first detection and was
# never mentioned again.
#
# This is the surface that keeps it reachable: one durable, broadcast
# FleetEvent per CVE per window (`cve_responder.exposure_aged_out`), correlated
# to the CVE signal's own chain (`cve_pub:<cve_id>`) so system_inspect_correlation
# and system_recent_signals show it next to the decisions that failed to clear it.
RSpec.describe System::CveOps::AgedExposureEscalator do
  let(:account)   { create(:account) }
  let(:platform)  { create(:system_node_platform, account: account) }
  let(:category)  { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "openssl-base")
  end
  let(:node_module_version) do
    create(:system_node_module_version, node_module: node_module, version_number: 1)
  end
  let(:lookback)  { 24.hours }
  let(:escalator) { described_class.new(account: account, lookback: lookback) }

  def make_cve(cve_id:, severity: "critical")
    ::System::Cve.create!(
      cve_id: cve_id, severity: severity,
      affected_packages: [ { "name" => "openssl", "version" => "<3.1.4" } ],
      summary: "Test CVE #{cve_id}", feed_source: "TEST", published_at: Time.current
    )
  end

  def make_exposure(cve:, version: node_module_version, state: "open", detected_at: 48.hours.ago, package_name: "openssl")
    ::System::CveExposure.create!(
      cve: cve, node_module_version: version, package_name: package_name,
      package_version: "3.1.3", state: state, detected_at: detected_at
    )
  end

  def aged_out_events
    ::System::FleetEvent.where(account_id: account.id, kind: "cve_responder.exposure_aged_out")
  end

  it "surfaces an open exposure older than the detection window as a durable FleetEvent" do
    cve = make_cve(cve_id: "CVE-2026-91001")
    exposure = make_exposure(cve: cve, detected_at: 48.hours.ago)

    expect(escalator.escalate!).to eq(1)

    event = aged_out_events.first
    expect(event).to be_present, "expected an aged-out exposure to leave an operator-visible record"
    expect(event.severity).to eq("critical")
    expect(event.source).to eq("cve_responder")
    expect(event.correlation_id).to eq("cve_pub:CVE-2026-91001")
    expect(event.cve_id).to eq(cve.id)
    expect(event.payload["cve_id"]).to eq("CVE-2026-91001")
    expect(event.payload["cve_severity"]).to eq("critical")
    expect(event.payload["exposure_ids"]).to eq([ exposure.id ])
    expect(event.payload["affected_module_ids"]).to eq([ node_module.id ])
    expect(event.payload["affected_packages"]).to eq([ "openssl" ])
    expect(event.payload["exposure_count"]).to eq(1)
    expect(event.payload["detection_lookback_hours"]).to eq(24)
    expect(event.payload["open_for_hours"]).to be >= 48
    expect(event.payload["reason"]).to eq("open_beyond_detection_lookback")
  end

  it "mirrors a high-severity CVE as a high event" do
    cve = make_cve(cve_id: "CVE-2026-91002", severity: "high")
    make_exposure(cve: cve)
    escalator.escalate!
    expect(aged_out_events.first.severity).to eq("high")
  end

  it "emits once per CVE per window rather than every tick" do
    cve = make_cve(cve_id: "CVE-2026-91003")
    make_exposure(cve: cve)

    expect(escalator.escalate!).to eq(1)
    expect(escalator.escalate!).to eq(0)
    expect(aged_out_events.count).to eq(1)
  end

  it "re-emits once the previous record is itself older than the window" do
    cve = make_cve(cve_id: "CVE-2026-91004")
    make_exposure(cve: cve)
    ::System::FleetEvent.create!(
      account: account, kind: "cve_responder.exposure_aged_out", severity: "critical",
      source: "cve_responder", correlation_id: "cve_pub:CVE-2026-91004",
      emitted_at: 25.hours.ago, payload: {}
    )

    expect(escalator.escalate!).to eq(1)
    expect(aged_out_events.count).to eq(2)
  end

  it "ignores exposures still inside the detection window (the sensor owns those)" do
    cve = make_cve(cve_id: "CVE-2026-91005")
    make_exposure(cve: cve, detected_at: 1.hour.ago)
    expect(escalator.escalate!).to eq(0)
    expect(aged_out_events).to be_empty
  end

  it "ignores exposures that are no longer open" do
    cve = make_cve(cve_id: "CVE-2026-91006")
    make_exposure(cve: cve, state: "remediating")
    make_exposure(cve: cve, state: "resolved", package_name: "openssl-libs")
    expect(escalator.escalate!).to eq(0)
  end

  # IMP-7bba0413c36a — a keyword-only match has no version evidence and is
  # minted `suspected`; it is not an open exposure, so it never ages out.
  it "ignores suspected (keyword-only) exposures however old" do
    cve = make_cve(cve_id: "CVE-2009-3616")
    ::System::CveExposure.create!(
      cve: cve, node_module_version: node_module_version, package_name: "qemu",
      package_version: nil, match_method: "keyword", state: "suspected", detected_at: 30.days.ago
    )
    expect(escalator.escalate!).to eq(0)
    expect(aged_out_events).to be_empty
  end

  it "ignores low/medium severity CVEs" do
    cve = make_cve(cve_id: "CVE-2026-91007", severity: "medium")
    make_exposure(cve: cve)
    expect(escalator.escalate!).to eq(0)
  end

  it "scopes to the account" do
    other_account = create(:account)
    other_platform = create(:system_node_platform, account: other_account)
    other_cat = create(:system_node_module_category, account: other_account)
    other_mod = create(:system_node_module, account: other_account, node_platform: other_platform,
                       category: other_cat, variety: "subscription", name: "other-mod")
    other_ver = create(:system_node_module_version, node_module: other_mod)
    cve = make_cve(cve_id: "CVE-2026-91008")
    make_exposure(cve: cve, version: other_ver)

    expect(escalator.escalate!).to eq(0)
    expect(aged_out_events).to be_empty
  end

  it "groups every aged exposure of one CVE into one event" do
    cve = make_cve(cve_id: "CVE-2026-91009")
    make_exposure(cve: cve, package_name: "openssl")
    make_exposure(cve: cve, package_name: "openssl-dev")

    expect(escalator.escalate!).to eq(1)
    expect(aged_out_events.first.payload["exposure_count"]).to eq(2)
    expect(aged_out_events.first.payload["affected_packages"]).to match_array(%w[openssl openssl-dev])
  end
  # IMP-60717919d4a0 (review) — the aged set is the COMPLEMENT of the sensor's
  # fresh set: it grows monotonically, because an exposure nobody remediates
  # only gets older. In steady state almost every tick is a no-op pass, so the
  # dedup that makes it a no-op has to run BEFORE the rows are loaded, and one
  # account's backlog must not be able to own the tick.
  describe "per-tick bounds" do
    def exposure_row_selects
      queries = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql].to_s
      end
      yield
      queries.grep(/SELECT\s+"system_cve_exposures"\.\*/)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    it "loads no exposure rows on a pass where every aged CVE is already escalated" do
      cve = make_cve(cve_id: "CVE-2026-91020")
      make_exposure(cve: cve)
      ::System::FleetEvent.create!(
        account: account, kind: "cve_responder.exposure_aged_out", severity: "critical",
        source: "cve_responder", correlation_id: "cve_pub:CVE-2026-91020",
        emitted_at: 1.minute.ago, payload: {}
      )

      loads = nil
      expect { loads = exposure_row_selects { expect(escalator.escalate!).to eq(0) } }.not_to raise_error
      expect(loads).to be_empty, "expected the window dedup to run before the rows were loaded, got: #{loads.inspect}"
    end

    it "caps the CVEs escalated in one tick at the configured maximum" do
      ::SiteSetting.set(described_class::MAX_CVES_SETTING_KEY, 1, setting_type: "integer")
      make_exposure(cve: make_cve(cve_id: "CVE-2026-91021"))
      make_exposure(cve: make_cve(cve_id: "CVE-2026-91022"), package_name: "openssl-dev")

      expect(escalator.escalate!).to eq(1)
      # The one it skipped is not lost: nothing marks it escalated, so the next
      # tick picks it up.
      expect(escalator.escalate!).to eq(1)
      expect(aged_out_events.count).to eq(2)
    end

    it "defaults the cap to its constant and lets an account override it" do
      expect(described_class::DEFAULT_MAX_CVES_PER_TICK).to be_positive
      account.update!(settings: { described_class::ACCOUNT_MAX_CVES_KEY => 1 })
      make_exposure(cve: make_cve(cve_id: "CVE-2026-91023"))
      make_exposure(cve: make_cve(cve_id: "CVE-2026-91024"), package_name: "openssl-dev")

      expect(escalator.escalate!).to eq(1)
    end
  end
end
