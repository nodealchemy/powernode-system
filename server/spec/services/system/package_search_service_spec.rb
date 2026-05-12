# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::PackageSearchService do
  let(:account)        { create(:account) }
  let(:apt_repo)       { create(:system_package_repository, :synced, account: account, name: "apt-noble", architectures: ["amd64"]) }
  let(:rpm_repo)       { create(:system_package_repository, :rpm, :synced, account: account, name: "rpm-f40", architectures: ["amd64"]) }
  let(:shared_apt_repo) { create(:system_package_repository, :shared, :synced, name: "apt-shared", architectures: ["amd64", "arm64"]) }

  def pkg(repo, name, **opts)
    create(:system_package, package_repository: repo, name: name, **opts)
  end

  describe ".call" do
    context "with no q (filter-only browse)" do
      before do
        pkg(apt_repo, "nginx",   section_or_group: "httpd",  license: "BSD-2-Clause")
        pkg(apt_repo, "apache2", section_or_group: "httpd",  license: "Apache-2.0")
        pkg(apt_repo, "vim",     section_or_group: "editors")
      end

      it "returns all packages in name order by default" do
        result = described_class.call(account: account, params: {})
        expect(result.packages.map(&:name)).to eq(%w[apache2 nginx vim])
        expect(result.total).to eq(3)
        expect(result.mode).to eq("lexical")  # blank q forces lexical
      end

      it "filters by license" do
        result = described_class.call(account: account, params: { license: "BSD-2-Clause" })
        expect(result.packages.map(&:name)).to eq(["nginx"])
      end

      it "filters by sections (multi)" do
        result = described_class.call(account: account, params: { sections: ["httpd"] })
        expect(result.packages.map(&:name)).to match_array(%w[apache2 nginx])
      end

      it "back-compat: accepts singular `section`" do
        result = described_class.call(account: account, params: { section: "httpd" })
        expect(result.packages.map(&:name)).to match_array(%w[apache2 nginx])
      end
    end

    context "filtering by `provides` capability" do
      before do
        pkg(apt_repo, "postfix", provides_caps: ["mail-transport-agent"])
        pkg(apt_repo, "exim4",   provides_caps: ["mail-transport-agent", "smtp-server"])
        pkg(apt_repo, "nginx") # no provides
      end

      it "matches packages whose `provides` JSONB contains the capability" do
        result = described_class.call(account: account, params: { provides: "mail-transport-agent" })
        expect(result.packages.map(&:name)).to match_array(%w[postfix exim4])
      end

      it "also matches packages whose name equals the capability" do
        pkg(apt_repo, "mail-transport-agent")
        result = described_class.call(account: account, params: { provides: "mail-transport-agent" })
        expect(result.packages.map(&:name)).to match_array(%w[postfix exim4 mail-transport-agent])
      end
    end

    context "architecture canonicalization (cross-kind)" do
      before do
        # Canonical "amd64" is "amd64" on apt and "x86_64" on rpm. Filter
        # input is canonical; query must match BOTH kind-specific values.
        pkg(apt_repo, "nginx",   architecture: "amd64")
        pkg(rpm_repo, "nginx",   architecture: "x86_64")
        pkg(rpm_repo, "httpd",   architecture: "x86_64")
        pkg(apt_repo, "nginx",   architecture: "arm64") # different arch, should be excluded
      end

      it "expands canonical `amd64` to include both apt and rpm name variants" do
        result = described_class.call(account: account, params: { architectures: ["amd64"] })
        names_archs = result.packages.map { |p| [p.name, p.architecture] }
        expect(names_archs).to match_array([
          ["nginx", "amd64"],
          ["nginx", "x86_64"],
          ["httpd", "x86_64"]
        ])
      end

      it "back-compat: accepts singular `architecture`" do
        result = described_class.call(account: account, params: { architecture: "amd64" })
        expect(result.packages.map(&:architecture).uniq).to match_array(%w[amd64 x86_64])
      end
    end

    context "kind filter" do
      before do
        pkg(apt_repo, "nginx-apt")
        pkg(rpm_repo, "nginx-rpm")
      end

      it "scopes to repos of the given kind" do
        result = described_class.call(account: account, params: { kind: "rpm" })
        expect(result.packages.map(&:name)).to eq(["nginx-rpm"])
      end
    end

    context "repository_ids filter" do
      before do
        pkg(apt_repo, "a")
        pkg(rpm_repo, "b")
      end

      it "scopes to the provided repositories (array form)" do
        result = described_class.call(account: account, params: { repository_ids: [apt_repo.id] })
        expect(result.packages.map(&:name)).to eq(["a"])
      end

      it "back-compat: accepts singular `repository_id`" do
        result = described_class.call(account: account, params: { repository_id: rpm_repo.id })
        expect(result.packages.map(&:name)).to eq(["b"])
      end
    end

    context "lexical mode" do
      before do
        pkg(apt_repo, "nginx")
        pkg(apt_repo, "nginx-extras")
        pkg(apt_repo, "libnginx-mod-http-image-filter")
        pkg(apt_repo, "unrelated-tool", description: "an unrelated description")
      end

      it "matches name + description and orders exact > prefix > similarity" do
        result = described_class.call(account: account, params: { q: "nginx", mode: "lexical" })
        # First two should be exact ("nginx") then prefix ("nginx-extras"),
        # followed by trigram-similar ones.
        expect(result.packages.first.name).to eq("nginx")
        expect(result.packages.map(&:name)).to include("nginx", "nginx-extras")
        expect(result.packages.map(&:name)).not_to include("unrelated-tool")
        expect(result.mode).to eq("lexical")
        expect(result.total).to be_present
      end

      it "echoes applied_filters" do
        result = described_class.call(account: account, params: { q: "nginx", mode: "lexical" })
        expect(result.applied_filters).to include(q: "nginx", mode: "lexical")
      end
    end

    context "semantic mode" do
      before do
        pkg(apt_repo, "nginx",  summary: "reverse proxy")
        pkg(apt_repo, "apache", summary: "httpd")
      end

      it "degrades to lexical when q is blank" do
        result = described_class.call(account: account, params: { mode: "semantic" })
        expect(result.mode).to eq("lexical") # blank q → degrade
      end

      it "degrades to lexical when embedding generation fails" do
        allow_any_instance_of(::Ai::Memory::EmbeddingService).to receive(:generate).and_return(nil)
        result = described_class.call(account: account, params: { q: "reverse proxy", mode: "semantic" })
        # Service silently degrades — we still get *some* result rather than crashing.
        # Since no embeddings are stored in test rows, semantic returns nothing;
        # the degradation path runs lexical with `q=reverse proxy` which won't
        # match either name. End result: empty `packages` but `mode: "lexical"`.
        expect(result.mode).to eq("lexical")
      end

      it "queries nearest_neighbors when embedding is generated and rows have vectors" do
        allow_any_instance_of(::Ai::Memory::EmbeddingService)
          .to receive(:generate).and_return(Array.new(1536, 0.1))
        ::System::Package.where(name: "nginx").update_all(embedding: Array.new(1536, 0.1))
        ::System::Package.where(name: "apache").update_all(embedding: Array.new(1536, -0.1))

        result = described_class.call(account: account, params: { q: "reverse proxy", mode: "semantic" })
        # With a matching vector on nginx and a near-opposite vector on apache,
        # nginx should rank first.
        expect(result.packages.first.name).to eq("nginx")
        expect(result.mode).to eq("semantic")
        expect(result.total).to be_nil  # exact COUNT skipped under semantic
      end
    end

    context "hybrid mode (default)" do
      before do
        pkg(apt_repo, "nginx", summary: "reverse proxy server")
      end

      it "is the default when no mode is supplied and q is present" do
        result = described_class.call(account: account, params: { q: "nginx" })
        expect(result.mode).to eq("hybrid")
      end

      it "falls back to lexical when q is blank" do
        result = described_class.call(account: account, params: {})
        expect(result.mode).to eq("lexical")
      end
    end

    context "accessibility scoping" do
      let(:other_account) { create(:account) }

      it "excludes packages from inaccessible private repos" do
        other_repo = create(:system_package_repository, account: other_account, name: "other-repo")
        pkg(other_repo, "secret-tool")
        pkg(apt_repo,   "public-tool")

        result = described_class.call(account: account, params: {})
        expect(result.packages.map(&:name)).to eq(["public-tool"])
      end

      it "includes packages from shared repos" do
        pkg(shared_apt_repo, "shared-tool")
        pkg(apt_repo,        "owned-tool")

        result = described_class.call(account: account, params: {})
        expect(result.packages.map(&:name)).to match_array(%w[owned-tool shared-tool])
      end
    end

    context "pagination" do
      before do
        12.times { |i| pkg(apt_repo, "pkg-#{i.to_s.rjust(2, '0')}") }
      end

      it "returns at most per_page packages" do
        result = described_class.call(account: account, params: { per_page: 5 })
        expect(result.packages.size).to eq(5)
        expect(result.total).to eq(12)
      end

      it "supports page=2" do
        page1 = described_class.call(account: account, params: { per_page: 5, page: 1 }).packages.map(&:name)
        page2 = described_class.call(account: account, params: { per_page: 5, page: 2 }).packages.map(&:name)
        expect((page1 + page2).uniq.size).to eq(10)
      end

      it "clamps per_page to MAX_PER_PAGE" do
        result = described_class.call(account: account, params: { per_page: 10_000 })
        expect(result.applied_filters[:per_page]).to eq(described_class::MAX_PER_PAGE)
      end
    end

    context "obsoleted packages" do
      before do
        pkg(apt_repo, "current")
        pkg(apt_repo, "old", obsoleted_at: 1.day.ago)
      end

      it "excludes obsoleted rows" do
        result = described_class.call(account: account, params: {})
        expect(result.packages.map(&:name)).to eq(["current"])
      end
    end
  end
end
