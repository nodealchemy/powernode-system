# frozen_string_literal: true

require "rails_helper"

# IMP-9f69531f042d — PackageDriftSensor#cve_flagged? raised a drift signal to
# :high on the existence of ANY System::CveExposure row for the module: no
# state predicate and no match-evidence predicate. Since IMP-7bba0413c36a a
# keyword-only hit is a `suspected` row (or a `resolved` one, for the rows
# that predate the column) and carries no version evidence, so it must not
# label the drift signal CVE-driven. (Severity is not an approval input: the
# signal routes to system.package_repository.sync, auto_approve at both
# severities — what the boost drives is the operator-facing severity and the
# `cve_flagged` payload flag.) The predicate is now
# `CveExposure.unresolved.version_confirmed`: an open/remediating sbom-matched
# row boosts; suspected, resolved, wont_fix and every keyword-only row do not.
RSpec.describe System::Fleet::Sensors::PackageDriftSensor do
  let(:account)   { create(:account) }
  let(:platform)  { create(:system_node_platform, account: account) }
  let(:category)  { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "openssl-mod")
  end
  let(:node_module_version) do
    create(:system_node_module_version, node_module: node_module, version_number: 1)
  end
  let(:repo) { create(:system_package_repository, account: account) }
  let!(:link) do
    create(:system_package_module_link,
           node_module: node_module,
           package_repository: repo,
           package_name: "openssl",
           package_version: "3.1.3",
           architecture: "amd64",
           last_synced_at: 48.hours.ago)
  end
  let!(:upstream) do
    create(:system_package, package_repository: repo, name: "openssl",
                            architecture: "amd64", version: "3.1.4")
  end
  let(:sensor) { described_class.new(account: account) }

  def exposure(*traits, **attrs)
    create(:system_cve_exposure, *traits, node_module_version: node_module_version,
                                          package_name: "openssl", **attrs)
  end

  def only_signal
    signals = sensor.sense
    expect(signals.size).to eq(1)
    expect(signals.first.kind).to eq("system.package_drift_pressure")
    signals.first
  end

  it "emits a medium, un-flagged signal for drift with no exposure at all" do
    sig = only_signal
    expect(sig.severity).to eq(:medium)
    expect(sig.payload["cve_flagged"]).to be false
  end

  it "boosts to high on an open sbom-matched exposure" do
    exposure(state: "open", match_method: "sbom", package_version: "3.1.3")

    sig = only_signal
    expect(sig.severity).to eq(:high)
    expect(sig.payload["cve_flagged"]).to be true
  end

  it "boosts to high on a remediating sbom-matched exposure" do
    exposure(state: "remediating", match_method: "sbom", package_version: "3.1.3")

    sig = only_signal
    expect(sig.severity).to eq(:high)
    expect(sig.payload["cve_flagged"]).to be true
  end

  it "does not boost on a suspected keyword-only row (no version evidence)" do
    exposure(:suspected)

    sig = only_signal
    expect(sig.severity).to eq(:medium)
    expect(sig.payload["cve_flagged"]).to be false
  end

  it "does not boost on a resolved row" do
    exposure(:resolved, match_method: "sbom", package_version: "3.1.3")

    sig = only_signal
    expect(sig.severity).to eq(:medium)
    expect(sig.payload["cve_flagged"]).to be false
  end

  it "does not boost on a wont_fix row" do
    exposure(state: "wont_fix", match_method: "sbom", package_version: "3.1.3")

    sig = only_signal
    expect(sig.severity).to eq(:medium)
    expect(sig.payload["cve_flagged"]).to be false
  end

  # A keyword row is unconfirmed in EVERY state — the migration resolved the
  # open ones, but a `remediating` keyword row was left for an operator and
  # must still not read as version evidence.
  it "does not boost on a remediating keyword-only row" do
    exposure(state: "remediating", match_method: "keyword", package_version: nil)

    sig = only_signal
    expect(sig.severity).to eq(:medium)
    expect(sig.payload["cve_flagged"]).to be false
  end
end
