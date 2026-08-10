# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::PackageModuleMaterializer do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:repo) { create(:system_package_repository, account: account) }
  # Unique suffix to avoid collisions with AccountBootstrapService-seeded modules
  # ("nginx", "apache", "chrony", etc. get auto-created when an Account is created).
  let(:suffix) { "mat#{SecureRandom.hex(3)}" }
  let(:top_pkg) { "appz-#{suffix}" }
  let(:mid_pkg) { "libssl-#{suffix}" }
  let(:bot_pkg) { "libfoo-#{suffix}" }

  before do
    create(:system_package, package_repository: repo, name: bot_pkg)
    create(:system_package, package_repository: repo, name: mid_pkg, depends_on: [ bot_pkg ])
    create(:system_package, package_repository: repo, name: top_pkg, depends_on: [ mid_pkg ])
  end

  describe ".call" do
    it "creates the top-level module + transitive dependency modules" do
      result = described_class.call(
        repository:        repo,
        package_name:      top_pkg,
        architectures:     [ "amd64" ],
        account:           account,
        requested_by_user: user,
        dispatch_build:    false
      )
      expect(result.errors).to be_empty
      expect(result).to be_success
      expect(result.top_level_module.name).to eq(top_pkg)
      expect(result.top_level_module.auto_generated).to be(false)
      expect(result.top_level_module.public).to be(true)

      dep_names = result.dependency_modules.map(&:name).sort
      expect(dep_names).to include(a_string_matching(/--#{Regexp.escape(bot_pkg)}\z/))
      expect(dep_names).to include(a_string_matching(/--#{Regexp.escape(mid_pkg)}\z/))
      result.dependency_modules.each do |m|
        expect(m.auto_generated).to be(true)
        expect(m.public).to be(false)
      end
    end

    it "creates ModuleDependency edges of type 'requires' for the closure" do
      result = described_class.call(
        repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
        account: account, requested_by_user: user, dispatch_build: false
      )
      requires_edges = result.dependencies_created.select { |d| d.dependency_type == "requires" }
      expect(requires_edges.size).to be >= 2 # top→mid, mid→bot
    end

    it "is idempotent: re-running produces no net side effects" do
      described_class.call(
        repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
        account: account, requested_by_user: user, dispatch_build: false
      )
      module_count_before = System::NodeModule.count
      dep_count_before = System::ModuleDependency.count
      link_count_before = System::PackageModuleLink.count

      described_class.call(
        repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
        account: account, requested_by_user: user, dispatch_build: false
      )

      expect(System::NodeModule.count).to eq(module_count_before)
      expect(System::ModuleDependency.count).to eq(dep_count_before)
      expect(System::PackageModuleLink.count).to eq(link_count_before)
    end

    it "refuses to overwrite an existing operator-authored module with the same canonical name" do
      # An operator created a transitive-style module manually (auto_generated: false)
      existing = create(:system_node_module, account: account,
                                              name: "#{repo.name.parameterize}--#{bot_pkg}",
                                              auto_generated: false)
      _ = existing

      expect {
        described_class.call(
          repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
          account: account, requested_by_user: user, dispatch_build: false
        )
      }.to raise_error(System::PackageModuleMaterializer::NamingConflictError)
    end

    context "category assignment (campaign 019f6084)" do
      it "defaults every materialized module to the 'Workloads' taxonomy bucket when no category is given" do
        result = described_class.call(
          repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
          account: account, requested_by_user: user, dispatch_build: false
        )
        expect(result.top_level_module.category&.name).to eq("Workloads")
        result.dependency_modules.each do |m|
          expect(m.category&.name).to eq("Workloads")
        end
      end

      it "creates the 'Workloads' triplet on first use if it doesn't exist yet" do
        expect(
          System::NodeModuleCategory.find_by(account: account, name: "Workloads", variety: "subscription")
        ).to be_nil

        described_class.call(
          repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
          account: account, requested_by_user: user, dispatch_build: false
        )

        expect(
          System::NodeModuleCategory.find_by(account: account, name: "Workloads", variety: "subscription")
        ).to be_present
      end

      it "honors an explicit category override instead of the default" do
        custom = create(:system_node_module_category, account: account, variety: "subscription")
        result = described_class.call(
          repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
          account: account, requested_by_user: user, category: custom, dispatch_build: false
        )
        expect(result.top_level_module.category).to eq(custom)
      end
    end

    context "with recommends selection" do
      let(:rec_pkg) { "ssl-cert-#{suffix}" }

      before do
        create(:system_package, package_repository: repo, name: rec_pkg)
        pkg = System::Package.find_by(package_repository: repo, name: top_pkg)
        pkg.update!(recommends: [ [ { "name" => rec_pkg, "op" => nil, "version" => nil } ] ])
      end

      it "persists recommends_chosen on the top-level link only" do
        result = described_class.call(
          repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
          account: account, requested_by_user: user,
          recommends_selected: [ rec_pkg ], dispatch_build: false
        )
        link = result.top_level_module.package_module_link.reload
        expect(link.recommends_chosen).to eq([ rec_pkg ])

        # Transitive deps' links have empty recommends_chosen
        result.dependency_modules.each do |m|
          dep_link = m.package_module_link.reload
          expect(dep_link.recommends_chosen).to eq([])
        end
      end

      it "creates the recommends module + a recommends-type ModuleDependency edge" do
        result = described_class.call(
          repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
          account: account, requested_by_user: user,
          recommends_selected: [ rec_pkg ], dispatch_build: false
        )
        all_module_names = result.all_modules.map(&:name)
        expect(all_module_names.any? { |n| n.end_with?("--#{rec_pkg}") }).to be(true)

        recommends_edges = result.dependencies_created.select { |d| d.dependency_type == "recommends" }
        expect(recommends_edges).not_to be_empty
        expect(recommends_edges.first.required).to be(false)
      end
    end

    # IMP-709545f4f4e3: the in-memory dedupe keyed on (from, to, dep_type)
    # while the row is unique on (from, to) at both the model validation and
    # the DB index — so a pair reachable as BOTH a Depends and a Recommends
    # aborted the whole materialization with RecordInvalid.
    context "when one pair is reachable as both a Depends and a Recommends" do
      let(:dual_pkg) { "libdual-#{suffix}" }

      def materialize(selected)
        described_class.call(
          repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
          account: account, requested_by_user: user,
          recommends_selected: selected, dispatch_build: false
        )
      end

      def edges_between(from_name, to_suffix)
        from = System::NodeModule.find_by(account: account, name: from_name)
        System::ModuleDependency.where(node_module_id: from.id)
                                .includes(:dependency)
                                .select { |d| d.dependency.name.end_with?("--#{to_suffix}") }
      end

      it "collapses to one `requires` edge instead of raising" do
        create(:system_package, package_repository: repo, name: dual_pkg)
        System::Package.find_by(package_repository: repo, name: top_pkg).update!(
          depends:    [ [ { "name" => dual_pkg, "op" => nil, "version" => nil } ] ],
          recommends: [ [ { "name" => dual_pkg, "op" => nil, "version" => nil } ] ]
        )

        result = materialize([ dual_pkg ])
        expect(result.errors).to be_empty

        edges = edges_between(top_pkg, dual_pkg)
        expect(edges.size).to eq(1)
        expect(edges.first.dependency_type).to eq("requires")
        expect(edges.first.required).to be(true)
      end

      it "collapses when the Recommends resolves to the Depends target via Provides" do
        cap = "virtcap-#{suffix}"
        create(:system_package, package_repository: repo, name: dual_pkg, provides_caps: [ cap ])
        System::Package.find_by(package_repository: repo, name: top_pkg).update!(
          depends:    [ [ { "name" => dual_pkg, "op" => nil, "version" => nil } ] ],
          recommends: [ [ { "name" => cap, "op" => nil, "version" => nil } ] ]
        )

        result = materialize([ dual_pkg ])
        expect(result.errors).to be_empty
        expect(edges_between(top_pkg, dual_pkg).map(&:dependency_type)).to eq([ "requires" ])
      end

      it "upgrades a persisted `recommends` row when upstream promotes it to a Depends" do
        create(:system_package, package_repository: repo, name: dual_pkg)
        pkg = System::Package.find_by(package_repository: repo, name: top_pkg)
        pkg.update!(recommends: [ [ { "name" => dual_pkg, "op" => nil, "version" => nil } ] ])
        materialize([ dual_pkg ])
        expect(edges_between(top_pkg, dual_pkg).map(&:dependency_type)).to eq([ "recommends" ])

        pkg.update!(
          depends:    pkg.depends + [ [ { "name" => dual_pkg, "op" => nil, "version" => nil } ] ],
          recommends: []
        )
        result = materialize([ dual_pkg ])
        expect(result.errors).to be_empty

        edges = edges_between(top_pkg, dual_pkg)
        expect(edges.size).to eq(1)
        expect(edges.first.dependency_type).to eq("requires")
        expect(edges.first.required).to be(true)
      end

      it "never downgrades a persisted `requires` row back to `recommends`" do
        create(:system_package, package_repository: repo, name: dual_pkg)
        pkg = System::Package.find_by(package_repository: repo, name: top_pkg)
        pkg.update!(depends: pkg.depends + [ [ { "name" => dual_pkg, "op" => nil, "version" => nil } ] ])
        materialize([])

        pkg.update!(
          depends:    [ [ { "name" => mid_pkg, "op" => nil, "version" => nil } ] ],
          recommends: [ [ { "name" => dual_pkg, "op" => nil, "version" => nil } ] ]
        )
        materialize([ dual_pkg ])

        expect(edges_between(top_pkg, dual_pkg).map(&:dependency_type)).to eq([ "requires" ])
      end

      it "keeps an operator-authored `conflicts` edge and warns rather than clobbering it" do
        create(:system_package, package_repository: repo, name: dual_pkg)
        pkg = System::Package.find_by(package_repository: repo, name: top_pkg)
        pkg.update!(depends: pkg.depends + [ [ { "name" => dual_pkg, "op" => nil, "version" => nil } ] ])

        # First pass creates the modules so the operator edge can be authored
        # against the same rows the second pass will resolve.
        materialize([])
        edge = edges_between(top_pkg, dual_pkg).first
        edge.update_columns(dependency_type: "conflicts", required: false)

        result = materialize([])
        expect(result.errors).to be_empty
        expect(result.warnings).to include(a_string_matching(/Kept the existing `conflicts` edge/))
        expect(edges_between(top_pkg, dual_pkg).map(&:dependency_type)).to eq([ "conflicts" ])
      end
    end

    context "with a shared repository" do
      let(:shared_repo) { create(:system_package_repository, :shared) }
      let!(:other_account_user) { create(:user, account: create(:account)) }
      let(:shared_pkg) { "libcurl-#{suffix}" }

      before do
        create(:system_package, package_repository: shared_repo, name: shared_pkg)
      end

      it "lets two accounts each materialize the same shared-repo package independently" do
        result_a = described_class.call(
          repository: shared_repo, package_name: shared_pkg, architectures: [ "amd64" ],
          account: account, requested_by_user: user, dispatch_build: false
        )
        result_b = described_class.call(
          repository: shared_repo, package_name: shared_pkg, architectures: [ "amd64" ],
          account: other_account_user.account, requested_by_user: other_account_user, dispatch_build: false
        )

        expect(result_a.top_level_module.account_id).to eq(account.id)
        expect(result_b.top_level_module.account_id).to eq(other_account_user.account_id)
        expect(result_a.top_level_module.id).not_to eq(result_b.top_level_module.id)

        # Both link to the same shared repository
        expect(result_a.top_level_module.package_module_link.package_repository_id).to eq(shared_repo.id)
        expect(result_b.top_level_module.package_module_link.package_repository_id).to eq(shared_repo.id)
      end
    end

    # inc2 §4.3.2 legacy build-routing bridge: build_mode: :gitea skips the
    # native PackageClosureBuildBridge and instead fires the old fire-and-forget
    # System::ModuleBuildDispatchService.dispatch_closure path. Pins that
    # legacy_gitea_dispatch actually reaches the dispatch service with the
    # closure it just materialized (repository/architectures/requested_by
    # threaded through, modules = the real created NodeModule rows) — not
    # just that dispatch_closure_build's :gitea branch is selected.
    context "with build_mode: :gitea (legacy dispatch bridge)" do
      it "calls ModuleBuildDispatchService.dispatch_closure with the materialized modules" do
        received = nil
        expect(System::ModuleBuildDispatchService).to receive(:dispatch_closure) do |**kwargs|
          received = kwargs
          []
        end

        result = described_class.call(
          repository: repo, package_name: top_pkg, architectures: [ "amd64" ],
          account: account, requested_by_user: user,
          dispatch_build: true, build_mode: :gitea
        )

        expect(result.errors).to be_empty
        expect(received[:repository]).to eq(repo)
        expect(received[:architectures]).to eq([ "amd64" ])
        expect(received[:requested_by]).to eq(user)
        expect(received[:modules].map(&:name)).to match_array(result.all_modules.map(&:name))
      end
    end
  end
end
