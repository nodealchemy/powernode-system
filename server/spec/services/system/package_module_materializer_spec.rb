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
    create(:system_package, package_repository: repo, name: mid_pkg, depends_on: [bot_pkg])
    create(:system_package, package_repository: repo, name: top_pkg, depends_on: [mid_pkg])
  end

  describe ".call" do
    it "creates the top-level module + transitive dependency modules" do
      result = described_class.call(
        repository:        repo,
        package_name:      top_pkg,
        architectures:     ["amd64"],
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
        repository: repo, package_name: top_pkg, architectures: ["amd64"],
        account: account, requested_by_user: user, dispatch_build: false
      )
      requires_edges = result.dependencies_created.select { |d| d.dependency_type == "requires" }
      expect(requires_edges.size).to be >= 2 # top→mid, mid→bot
    end

    it "is idempotent: re-running produces no net side effects" do
      described_class.call(
        repository: repo, package_name: top_pkg, architectures: ["amd64"],
        account: account, requested_by_user: user, dispatch_build: false
      )
      module_count_before = System::NodeModule.count
      dep_count_before = System::ModuleDependency.count
      link_count_before = System::PackageModuleLink.count

      described_class.call(
        repository: repo, package_name: top_pkg, architectures: ["amd64"],
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
          repository: repo, package_name: top_pkg, architectures: ["amd64"],
          account: account, requested_by_user: user, dispatch_build: false
        )
      }.to raise_error(System::PackageModuleMaterializer::NamingConflictError)
    end

    context "with recommends selection" do
      let(:rec_pkg) { "ssl-cert-#{suffix}" }

      before do
        create(:system_package, package_repository: repo, name: rec_pkg)
        pkg = System::Package.find_by(package_repository: repo, name: top_pkg)
        pkg.update!(recommends: [[{ "name" => rec_pkg, "op" => nil, "version" => nil }]])
      end

      it "persists recommends_chosen on the top-level link only" do
        result = described_class.call(
          repository: repo, package_name: top_pkg, architectures: ["amd64"],
          account: account, requested_by_user: user,
          recommends_selected: [rec_pkg], dispatch_build: false
        )
        link = result.top_level_module.package_module_link.reload
        expect(link.recommends_chosen).to eq([rec_pkg])

        # Transitive deps' links have empty recommends_chosen
        result.dependency_modules.each do |m|
          dep_link = m.package_module_link.reload
          expect(dep_link.recommends_chosen).to eq([])
        end
      end

      it "creates the recommends module + a recommends-type ModuleDependency edge" do
        result = described_class.call(
          repository: repo, package_name: top_pkg, architectures: ["amd64"],
          account: account, requested_by_user: user,
          recommends_selected: [rec_pkg], dispatch_build: false
        )
        all_module_names = result.all_modules.map(&:name)
        expect(all_module_names.any? { |n| n.end_with?("--#{rec_pkg}") }).to be(true)

        recommends_edges = result.dependencies_created.select { |d| d.dependency_type == "recommends" }
        expect(recommends_edges).not_to be_empty
        expect(recommends_edges.first.required).to be(false)
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
          repository: shared_repo, package_name: shared_pkg, architectures: ["amd64"],
          account: account, requested_by_user: user, dispatch_build: false
        )
        result_b = described_class.call(
          repository: shared_repo, package_name: shared_pkg, architectures: ["amd64"],
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
  end
end
