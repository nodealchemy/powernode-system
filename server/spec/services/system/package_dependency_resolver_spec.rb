# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::PackageDependencyResolver do
  let(:account) { create(:account) }
  let(:repo) { create(:system_package_repository, account: account) }

  # Helper: build a Package with `depends_on:`, `recommends_packages:`,
  # `provides_caps:` (factory transient attributes that produce the
  # AND-of-OR shape).
  def pkg(name, **opts)
    create(:system_package, package_repository: repo, name: name, **opts)
  end

  subject(:resolver) do
    described_class.new(repositories: [repo], architecture: "amd64")
  end

  describe "#preview" do
    context "with a linear chain (nginx → libc6 → )" do
      before do
        pkg("libc6")
        pkg("nginx", depends_on: ["libc6"])
      end

      it "returns the required closure without writes" do
        preview = resolver.preview(root_package_name: "nginx")
        names = preview.required_packages.map(&:name).sort
        expect(names).to eq(%w[libc6 nginx])
        expect(preview.required_edges.size).to eq(1)
        expect(preview.required_edges.first.from_package.name).to eq("nginx")
        expect(preview.required_edges.first.to_package.name).to eq("libc6")
      end

      it "creates no DB rows beyond the Packages it walked over" do
        expect { resolver.preview(root_package_name: "nginx") }
          .not_to change { System::NodeModule.count }
        expect { resolver.preview(root_package_name: "nginx") }
          .not_to change { System::ModuleDependency.count }
      end
    end

    context "with a diamond graph (A → B → D, A → C → D)" do
      before do
        pkg("d")
        pkg("b", depends_on: ["d"])
        pkg("c", depends_on: ["d"])
        pkg("a", depends_on: %w[b c])
      end

      it "visits D exactly once" do
        preview = resolver.preview(root_package_name: "a")
        d_count = preview.required_packages.count { |p| p.name == "d" }
        expect(d_count).to eq(1)
        expect(preview.required_packages.map(&:name).sort).to eq(%w[a b c d])
      end
    end

    context "with a cycle (A → B → A)" do
      before do
        a = pkg("a")
        b = pkg("b", depends_on: ["a"])
        a.update!(depends: [[{ "name" => "b", "op" => nil, "version" => nil }]])
        _ = b
      end

      it "breaks the cycle and emits a warning" do
        preview = resolver.preview(root_package_name: "a")
        expect(preview.warnings).to include(a_string_matching(/Cycle broken/))
        expect(preview.required_packages.map(&:name).sort).to eq(%w[a b])
      end
    end

    context "with `a | b` alternatives" do
      before do
        pkg("foo")
        # bar deliberately not synced — first alt should be picked
        pkg("alt-target",
            depends: [[
              { "name" => "foo", "op" => nil, "version" => nil },
              { "name" => "bar", "op" => nil, "version" => nil }
            ]])
      end

      it "picks the first available alternative" do
        preview = resolver.preview(root_package_name: "alt-target")
        expect(preview.required_packages.map(&:name)).to include("foo")
        expect(preview.required_packages.map(&:name)).not_to include("bar")
      end
    end

    context "with virtual packages via Provides" do
      before do
        pkg("mta-impl", provides_caps: ["mail-transport-agent"])
        pkg("needs-mta", depends_on: ["mail-transport-agent"])
      end

      it "resolves the virtual capability to the providing package" do
        preview = resolver.preview(root_package_name: "needs-mta")
        names = preview.required_packages.map(&:name).sort
        expect(names).to include("mta-impl")
        expect(names).to include("needs-mta")
      end
    end

    context "with recommends candidates" do
      before do
        pkg("ssl-cert")
        pkg("iproute2")
        pkg("nginx",
            depends_on: [],
            recommends_packages: %w[ssl-cert iproute2])
      end

      it "surfaces recommends as candidates without including them in required_packages" do
        preview = resolver.preview(root_package_name: "nginx")
        expect(preview.required_packages.map(&:name)).to eq(["nginx"])
        candidate_names = preview.recommends_candidates.map { |c| c.to_package.name }.sort
        expect(candidate_names).to eq(%w[iproute2 ssl-cert])
      end
    end
  end

  describe "#resolve with recommends_selected" do
    before do
      pkg("ssl-cert")
      pkg("iproute2")
      pkg("nginx", recommends_packages: %w[ssl-cert iproute2])
    end

    it "includes only the selected recommends in the closure" do
      result = resolver.resolve(root_package_name: "nginx", recommends_selected: ["ssl-cert"])
      names = result.packages.map(&:name).sort
      expect(names).to eq(%w[nginx ssl-cert])
      recommends_edges = result.edges.select { |e| e.dep_type == "recommends" }
      expect(recommends_edges.size).to eq(1)
      expect(recommends_edges.first.to_package.name).to eq("ssl-cert")
    end

    it "records recommends_chosen for replay" do
      result = resolver.resolve(root_package_name: "nginx", recommends_selected: %w[ssl-cert iproute2])
      expect(result.recommends_chosen.sort).to eq(%w[iproute2 ssl-cert])
    end

    it "produces an empty recommends set when none selected" do
      result = resolver.resolve(root_package_name: "nginx", recommends_selected: [])
      expect(result.packages.map(&:name)).to eq(["nginx"])
      expect(result.edges.select { |e| e.dep_type == "recommends" }).to eq([])
    end
  end
end
