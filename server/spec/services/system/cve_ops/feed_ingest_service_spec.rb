# frozen_string_literal: true

require "rails_helper"

# Pagination coverage for the NVD feed ingest. The single-page fetch is
# extracted into #fetch_nvd_page, so the loop is exercised by stubbing that
# seam — no HTTP. Previously fetch_from_feed pulled only the first page,
# silently dropping any CVE backlog beyond it.
RSpec.describe System::CveOps::FeedIngestService do
  let(:service) { described_class.new }

  before do
    allow(service).to receive(:mode).and_return("real")
    allow(service).to receive(:sleep) # skip the inter-page rate-limit delay
  end

  # Minimal NVD v2 page shape that normalize_nvd understands.
  def nvd_page(ids, total:, per_page:)
    {
      "totalResults" => total,
      "resultsPerPage" => per_page,
      "vulnerabilities" => ids.map do |id|
        { "cve" => { "id" => id, "descriptions" => [ { "value" => "desc #{id}" } ],
                     "references" => [], "published" => "2026-01-01T00:00:00.000" } }
      end
    }
  end

  def run
    service.ingest!(source: "nvd", since: nil, fixture_path: nil)
  end

  it "ingests CVEs across ALL NVD pages, not just the first" do
    allow(service).to receive(:fetch_nvd_page).and_return(
      nvd_page(%w[CVE-2026-0001 CVE-2026-0002], total: 3, per_page: 2),
      nvd_page(%w[CVE-2026-0003], total: 3, per_page: 2)
    )

    result = run
    expect(result.ok?).to be true
    expect(result.ingested_count).to eq(3)
    expect(System::Cve.where(cve_id: %w[CVE-2026-0001 CVE-2026-0002 CVE-2026-0003]).count).to eq(3)
  end

  it "fetches exactly one page when totalResults fits in a single page" do
    expect(service).to receive(:fetch_nvd_page).once
      .and_return(nvd_page(%w[CVE-2026-0001 CVE-2026-0002], total: 2, per_page: 2))

    expect(run.ingested_count).to eq(2)
  end

  it "stops paginating when a page fetch fails, keeping earlier pages" do
    allow(service).to receive(:fetch_nvd_page).and_return(
      nvd_page(%w[CVE-2026-0001], total: 10, per_page: 1),
      nil # HTTP error mid-pagination
    )

    expect(run.ingested_count).to eq(1)
  end

  it "honors the NVD_MAX_PAGES safety cap" do
    stub_const("#{described_class}::NVD_MAX_PAGES", 2)
    call_count = 0
    # Every page claims a huge total so the loop would never terminate on its own.
    allow(service).to receive(:fetch_nvd_page) do |params|
      call_count += 1
      idx = params[:startIndex]
      nvd_page([ "CVE-2026-#{format('%04d', idx)}" ], total: 100_000, per_page: 1)
    end

    run
    expect(call_count).to eq(2)
  end
end
