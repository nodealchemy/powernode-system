# frozen_string_literal: true

require "rails_helper"

# IMP-7bba0413c36a — a CveExposure now records HOW it was matched.
#
#   sbom    — an ecosystem-aware version-range match against an ingested SBOM
#             (VersionMatcher): version evidence, state `open`.
#   keyword — the v0 fallback, a package NAME found in the module's name/repo
#             with no version at all: a suspicion, state `suspected`, which
#             every autonomy lane and every exposure count leaves out until an
#             SBOM match confirms it.
RSpec.describe System::CveExposure do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "openssl-base")
  end
  let(:version) { create(:system_node_module_version, node_module: node_module, version_number: 1) }
  let(:cve)     { create(:system_cve, :critical) }

  def build_row(**attrs)
    described_class.new({ cve: cve, node_module_version: version, package_name: "openssl" }.merge(attrs))
  end

  it "declares suspected as a state and the two match methods" do
    expect(described_class::STATES).to include("suspected")
    expect(described_class::MATCH_METHODS).to contain_exactly("sbom", "keyword")
  end

  describe "#record_match" do
    it "mints a keyword match as suspected with no version evidence" do
      row = build_row
      row.record_match(match_method: "keyword", package_version: nil)
      row.save!

      expect(row.state).to eq("suspected")
      expect(row.match_method).to eq("keyword")
      expect(row.package_version).to be_nil
      expect(row.detected_at).to be_present
    end

    it "mints an sbom match as open" do
      row = build_row
      row.record_match(match_method: "sbom", package_version: "3.1.3")
      row.save!

      expect(row.state).to eq("open")
      expect(row.match_method).to eq("sbom")
      expect(row.package_version).to eq("3.1.3")
    end

    it "flips suspected to open with match_method sbom on confirmation and re-stamps detected_at" do
      row = build_row(state: "suspected", match_method: "keyword", package_version: nil, detected_at: 3.days.ago)
      row.save!

      row.record_match(match_method: "sbom", package_version: "3.1.3")
      row.save!

      expect(row.state).to eq("open")
      expect(row.match_method).to eq("sbom")
      expect(row.package_version).to eq("3.1.3")
      # The confirmation IS the detection as far as the fresh-detection lane
      # (CvePublishedSensor's window) is concerned.
      expect(row.detected_at).to be > 1.minute.ago
    end

    it "leaves a resolved row resolved on a keyword re-match" do
      row = build_row(state: "resolved", match_method: "keyword", package_version: nil,
                      resolved_at: 1.day.ago, resolution_note: "keyword-fallback false positive (no version evidence)")
      row.save!

      row.record_match(match_method: "keyword", package_version: nil)

      expect(row.changed?).to be false
      expect(row.state).to eq("resolved")
    end

    # IMP-7bba0413c36a (review) — part 4 of this task RESOLVES every
    # keyword-only open row for lack of version evidence. That resolution is a
    # SUPPRESSION, not an operator decision: once an SBOM supplies the evidence
    # the row was resolved for lacking, it must come back. Without this the
    # migration permanently hides a real, version-confirmed exposure.
    it "re-opens a row resolved as a keyword false positive once an SBOM confirms it" do
      row = build_row(state: "resolved", match_method: "keyword", package_version: nil,
                      detected_at: 30.days.ago, resolved_at: 1.day.ago,
                      resolution_note: described_class::KEYWORD_FALSE_POSITIVE_NOTE)
      row.save!

      row.record_match(match_method: "sbom", package_version: "3.1.3")
      row.save!

      expect(row.state).to eq("open")
      expect(row.match_method).to eq("sbom")
      expect(row.package_version).to eq("3.1.3")
      expect(row.resolved_at).to be_nil
      expect(row.resolution_note).to be_nil
      expect(row.detected_at).to be > 1.minute.ago
    end

    it "leaves a row an OPERATOR resolved resolved when an SBOM matches, recording the evidence only" do
      row = build_row(state: "resolved", match_method: "keyword", package_version: nil,
                      resolved_at: 1.day.ago, resolution_note: "Upgraded to fixed version")
      row.save!

      row.record_match(match_method: "sbom", package_version: "3.1.3")
      row.save!

      expect(row.state).to eq("resolved")
      expect(row.resolution_note).to eq("Upgraded to fixed version")
      expect(row.match_method).to eq("sbom")
    end

    it "leaves a remediating row remediating on an sbom re-match" do
      row = build_row(state: "remediating", match_method: "sbom", package_version: "3.1.3")
      row.save!

      row.record_match(match_method: "sbom", package_version: "3.1.3")

      expect(row.state).to eq("remediating")
    end

    it "never downgrades an sbom row to keyword — version evidence does not expire" do
      row = build_row(state: "open", match_method: "sbom", package_version: "3.1.3")
      row.save!

      row.record_match(match_method: "keyword", package_version: nil)

      expect(row.changed?).to be false
      expect(row.match_method).to eq("sbom")
      expect(row.package_version).to eq("3.1.3")
    end
  end

  describe "match_method inference on create" do
    it "reads a row created with version evidence and no explicit method as sbom" do
      row = build_row(package_version: "3.1.3", state: "open")
      row.save!
      expect(row.reload.match_method).to eq("sbom")
    end

    it "reads a row created without version evidence and no explicit method as keyword" do
      row = build_row(package_version: nil, state: "open")
      row.save!
      expect(row.reload.match_method).to eq("keyword")
    end

    it "keeps an explicit match_method" do
      row = build_row(package_version: "3.1.3", match_method: "keyword", state: "open")
      row.save!
      expect(row.reload.match_method).to eq("keyword")
    end
  end

  it "rejects suspected on an sbom-matched row" do
    row = build_row(state: "suspected", match_method: "sbom", package_version: "3.1.3")
    expect(row).not_to be_valid
    expect(row.errors[:state].join).to include("keyword")
  end

  it "rejects an unknown match_method" do
    row = build_row(match_method: "guess")
    expect(row).not_to be_valid
  end

  # The exclusion the autonomy lanes and the exposure counts key on is
  # EVIDENCE, not state: a keyword row carries none in ANY state.
  it "partitions rows by version evidence, not by state" do
    sbom_row     = create(:system_cve_exposure, cve: cve, node_module_version: version, package_name: "openssl")
    suspected    = create(:system_cve_exposure, :suspected, cve: cve, node_module_version: version)
    false_pos    = create(:system_cve_exposure, :keyword_false_positive, cve: cve, node_module_version: version)

    expect(described_class.version_confirmed.where(cve: cve)).to contain_exactly(sbom_row)
    expect(described_class.unconfirmed.where(cve: cve)).to contain_exactly(suspected, false_pos)
  end

  it "keeps suspected rows out of open and unresolved, and in suspected" do
    suspected = create(:system_cve_exposure, :suspected, cve: cve, node_module_version: version)
    open_row  = create(:system_cve_exposure, cve: cve, node_module_version: version, package_name: "libssl")

    expect(described_class.open.where(cve: cve)).to contain_exactly(open_row)
    expect(described_class.unresolved.where(cve: cve)).to contain_exactly(open_row)
    expect(described_class.suspected.where(cve: cve)).to contain_exactly(suspected)
  end
end
