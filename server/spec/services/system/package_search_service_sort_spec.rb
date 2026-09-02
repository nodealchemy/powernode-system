# frozen_string_literal: true

require "rails_helper"

# IMP-fdb2ee10ba37 — `sort` was stored (:54) and echoed (:314) but no code path
# ever consumed it: every mode ordered by relevance only, so the documented
# values (relevance | name | updated) other than `relevance` were inert while
# the tool surface advertised them.
RSpec.describe System::PackageSearchService, "sort ordering" do
  let(:account)  { create(:account) }
  let(:apt_repo) { create(:system_package_repository, :synced, account: account, name: "apt-noble", architectures: [ "amd64" ]) }

  def pkg(name, **opts)
    create(:system_package, package_repository: apt_repo, name: name, **opts)
  end

  describe "declared sort values" do
    it "names the accepted set so the tool surface can declare it" do
      expect(described_class::SORTS).to eq(%w[relevance name updated])
      expect(described_class::SORTS).to include(described_class::DEFAULT_SORT)
    end
  end

  describe "sort: name" do
    before do
      pkg("zulu-nginx")
      pkg("nginx")
      pkg("alpha-nginx")
    end

    it "orders lexical results alphabetically instead of by relevance" do
      result = described_class.call(
        account: account,
        params:  { q: "nginx", mode: "lexical", sort: "name" }
      )

      expect(result.packages.map(&:name)).to eq(%w[alpha-nginx nginx zulu-nginx])
    end

    it "orders hybrid results alphabetically instead of by relevance" do
      result = described_class.call(
        account: account,
        params:  { q: "nginx", mode: "hybrid", sort: "name" }
      )

      expect(result.mode).to eq("hybrid")
      expect(result.packages.map(&:name)).to eq(%w[alpha-nginx nginx zulu-nginx])
    end

    it "breaks name ties deterministically by architecture" do
      pkg("tie-pkg", architecture: "arm64")
      pkg("tie-pkg", architecture: "amd64")

      result = described_class.call(
        account: account,
        params:  { q: "tie-pkg", mode: "lexical", sort: "name" }
      )

      expect(result.packages.map(&:architecture)).to eq(%w[amd64 arm64])
    end
  end

  describe "sort: updated" do
    # Equal-length, alphabetically ascending names whose freshness runs the
    # OTHER way, so neither relevance ranking nor name ordering can produce the
    # expected sequence by coincidence.
    before do
      pkg("nginx-aaa")
      pkg("nginx-bbb")
      pkg("nginx-ccc")
      ::System::Package.where(name: "nginx-aaa").update_all(updated_at: 3.days.ago)
      ::System::Package.where(name: "nginx-bbb").update_all(updated_at: 2.days.ago)
      ::System::Package.where(name: "nginx-ccc").update_all(updated_at: 1.hour.ago)
    end

    it "orders lexical results most-recently-updated first" do
      result = described_class.call(
        account: account,
        params:  { q: "nginx", mode: "lexical", sort: "updated" }
      )

      expect(result.packages.map(&:name)).to eq(%w[nginx-ccc nginx-bbb nginx-aaa])
    end

    it "orders filter-only browse results most-recently-updated first" do
      result = described_class.call(account: account, params: { sort: "updated" })

      expect(result.packages.map(&:name)).to eq(%w[nginx-ccc nginx-bbb nginx-aaa])
    end

    it "orders hybrid results most-recently-updated first" do
      result = described_class.call(
        account: account,
        params:  { q: "nginx", mode: "hybrid", sort: "updated" }
      )

      expect(result.mode).to eq("hybrid")
      expect(result.packages.map(&:name)).to eq(%w[nginx-ccc nginx-bbb nginx-aaa])
    end
  end

  describe "sort: relevance (default)" do
    before do
      pkg("zulu-nginx")
      pkg("nginx")
    end

    it "still ranks the exact match first" do
      result = described_class.call(
        account: account,
        params:  { q: "nginx", mode: "lexical" }
      )

      expect(result.packages.map(&:name)).to eq(%w[nginx zulu-nginx])
    end

    # The relevance ORDER BY used to terminate in `system_packages.name ASC`,
    # which is NOT unique (two rows may share a name across architectures).
    # run_lexical paginates that ordering with LIMIT/OFFSET, so a name tie
    # straddling a page boundary could drop or repeat a row.
    it "terminates the relevance ORDER BY in a unique column" do
      service = described_class.new(account: account, params: { q: "nginx", mode: "lexical" })
      sql     = service.send(:apply_lexical_ranking, ::System::Package.all, "nginx").to_sql

      expect(sql).to match(/system_packages\.id ASC/)
    end

    it "paginates a name tie without dropping or repeating a row" do
      pkg("tie-pkg", architecture: "arm64")
      pkg("tie-pkg", architecture: "amd64")

      pages = (1..2).map do |page|
        described_class.call(
          account: account,
          params:  { q: "tie-pkg", mode: "lexical", page: page, per_page: 1 }
        ).packages.map(&:id)
      end

      expect(pages.flatten.uniq.length).to eq(2)
      expect(pages.flatten).to match_array(::System::Package.where(name: "tie-pkg").pluck(:id))
    end
  end

  describe "normalization" do
    before { pkg("nginx") }

    it "falls back to relevance for an unrecognized sort and echoes what actually ran" do
      result = described_class.call(
        account: account,
        params:  { q: "nginx", mode: "lexical", sort: "bogus" }
      )

      expect(result.applied_filters[:sort]).to eq("relevance")
    end

    it "echoes an honoured sort verbatim" do
      result = described_class.call(
        account: account,
        params:  { q: "nginx", mode: "lexical", sort: "name" }
      )

      expect(result.applied_filters[:sort]).to eq("name")
    end
  end
end
