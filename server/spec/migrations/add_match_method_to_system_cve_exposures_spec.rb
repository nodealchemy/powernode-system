# frozen_string_literal: true

require "rails_helper"
require Rails.root.join(
  "../extensions/system/server/db/migrate/20260903150000_add_match_method_to_system_cve_exposures.rb"
)

# IMP-7bba0413c36a — the residue the calculator fix cannot reach.
#
# Before this migration a CveExposure did not record HOW it was matched, and
# the keyword fallback minted `open` rows with no version evidence: on the
# 2026-09-03 control plane every open critical exposure was one (4 critical +
# 561 unknown, all with package_version = ''). The calculator now stamps
# `match_method` and mints keyword hits as `suspected`; this migration makes
# the rows already on disk read truthfully — blank package_version is the
# keyword fallback's signature, a version is the SBOM matcher's — and resolves
# the keyword-only OPEN rows as the false positives they are. Rows already
# resolved (including the four the operator resolved by hand) are untouched.
RSpec.describe AddMatchMethodToSystemCveExposures do
  subject(:migration) { described_class.new }

  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node_module) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "qemu-guest-agent")
  end
  let(:version) { create(:system_node_module_version, node_module: node_module, version_number: 1) }
  let(:cve)     { create(:system_cve, :critical, cve_id: "CVE-2009-3616") }

  # Raw rows, written the way the pre-migration platform wrote them: the
  # model's own match_method inference must not be what the migration is
  # judged against, so every row is stamped through update_columns.
  def raw_row(package_name:, package_version:, state:, match_method:, note: nil, resolved_at: nil)
    row = System::CveExposure.create!(
      cve: cve, node_module_version: version, package_name: package_name,
      package_version: package_version, state: state, match_method: match_method,
      resolution_note: note, resolved_at: resolved_at, detected_at: 2.days.ago
    )
    row.update_columns(match_method: match_method)
    row
  end

  describe "#backfill_match_method!" do
    it "reads a blank package_version as keyword and a version as sbom" do
      blank = raw_row(package_name: "qemu", package_version: "", state: "open", match_method: "sbom")
      nil_v = raw_row(package_name: "qemu-ga", package_version: nil, state: "open", match_method: "sbom")
      versioned = raw_row(package_name: "openssl", package_version: "3.1.3", state: "open", match_method: "keyword")

      migration.suppress_messages { migration.backfill_match_method! }

      expect(blank.reload.match_method).to eq("keyword")
      expect(nil_v.reload.match_method).to eq("keyword")
      expect(versioned.reload.match_method).to eq("sbom")
    end
  end

  describe "#resolve_keyword_false_positives!" do
    it "resolves a keyword-only OPEN row with the false-positive note" do
      row = raw_row(package_name: "qemu", package_version: "", state: "open", match_method: "keyword")

      migration.suppress_messages { migration.resolve_keyword_false_positives! }

      row.reload
      expect(row.state).to eq("resolved")
      expect(row.resolution_note).to eq("keyword-fallback false positive (no version evidence)")
      expect(row.resolved_at).to be_present
    end

    it "leaves an sbom-matched open row open — it has version evidence" do
      row = raw_row(package_name: "openssl", package_version: "3.1.3", state: "open", match_method: "sbom")

      migration.suppress_messages { migration.resolve_keyword_false_positives! }

      expect(row.reload.state).to eq("open")
    end

    it "leaves an already-resolved row untouched, note and timestamp included" do
      resolved_at = 3.days.ago.change(usec: 0)
      row = raw_row(package_name: "qemu", package_version: "", state: "resolved", match_method: "keyword",
                    note: "IMP-7bba0413c36a: resolved by hand on ops-hub", resolved_at: resolved_at)

      migration.suppress_messages { migration.resolve_keyword_false_positives! }

      row.reload
      expect(row.state).to eq("resolved")
      expect(row.resolution_note).to eq("IMP-7bba0413c36a: resolved by hand on ops-hub")
      expect(row.resolved_at).to eq(resolved_at)
    end

    it "leaves a remediating keyword row alone — only OPEN rows are swept" do
      row = raw_row(package_name: "qemu", package_version: "", state: "remediating", match_method: "keyword")

      migration.suppress_messages { migration.resolve_keyword_false_positives! }

      expect(row.reload.state).to eq("remediating")
    end

    it "is idempotent" do
      row = raw_row(package_name: "qemu", package_version: "", state: "open", match_method: "keyword")
      migration.suppress_messages { migration.resolve_keyword_false_positives! }
      first = row.reload.updated_at

      migration.suppress_messages { migration.resolve_keyword_false_positives! }

      expect(row.reload.updated_at).to eq(first)
    end
  end

  # The real DDL, both directions, inside the example's transaction: down
  # drops the column and restores the four-state constraint; up adds it back,
  # backfills from package_version and sweeps the keyword-only open rows.
  describe "#up after #down (round trip)" do
    it "backfills match_method from package_version, admits `suspected`, and resolves the keyword-only open rows" do
      keyword_open = raw_row(package_name: "qemu", package_version: "", state: "open", match_method: "keyword")
      sbom_open    = raw_row(package_name: "openssl", package_version: "3.1.3", state: "open", match_method: "sbom")
      hand_resolved = raw_row(package_name: "qemu-ga", package_version: nil, state: "resolved", match_method: "keyword",
                              note: "resolved by hand", resolved_at: 1.day.ago)

      migration.suppress_messages { migration.down }
      System::CveExposure.reset_column_information
      expect(System::CveExposure.column_names).not_to include("match_method")

      migration.suppress_messages { migration.up }
      System::CveExposure.reset_column_information
      expect(System::CveExposure.column_names).to include("match_method")

      expect(keyword_open.reload.match_method).to eq("keyword")
      expect(keyword_open.state).to eq("resolved")
      expect(keyword_open.resolution_note).to eq("keyword-fallback false positive (no version evidence)")

      expect(sbom_open.reload.match_method).to eq("sbom")
      expect(sbom_open.state).to eq("open")

      expect(hand_resolved.reload.match_method).to eq("keyword")
      expect(hand_resolved.resolution_note).to eq("resolved by hand")

      # The state constraint now admits the new state.
      expect {
        System::CveExposure.create!(cve: cve, node_module_version: version, package_name: "nginx",
                                    package_version: nil, match_method: "keyword", state: "suspected")
      }.not_to raise_error
    end
  end
end
