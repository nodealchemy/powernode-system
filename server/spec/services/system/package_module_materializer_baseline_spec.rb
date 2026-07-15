# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc2 §4.3.1 — baseline exclusion. Materializing a package
# closure must NOT spawn per-package modules for packages base-os already
# ships (libc6/coreutils/...); those are replaced by a single synthetic
# `requires: base-os` edge on the top-level module (matching inc1's
# `capability:os.userland` shape), unless include_baseline: true is passed.
RSpec.describe System::PackageModuleMaterializer, "baseline exclusion (§4.3.1)" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }
  let(:repo)    { create(:system_package_repository, account: account) }

  let(:suffix)   { "bl#{SecureRandom.hex(3)}" }
  let(:libc)     { "libc6-#{suffix}" }        # baseline (base-os ships it)
  let(:coreutils){ "coreutils-#{suffix}" }    # baseline (base-os ships it)
  let(:libpcre)  { "libpcre-#{suffix}" }      # NON-baseline transitive dep
  let(:top_pkg)  { "webserver-#{suffix}" }    # user-requested top-level

  before do
    # Package rows in the repo. libc6 is a leaf; the top-level depends on both
    # a baseline package (libc6) and a non-baseline one (libpcre).
    create(:system_package, package_repository: repo, name: libc)
    create(:system_package, package_repository: repo, name: coreutils)
    create(:system_package, package_repository: repo, name: libpcre, depends_on: [ libc ])
    create(:system_package, package_repository: repo, name: top_pkg, depends_on: [ libc, libpcre ])

    # The base-os module whose package_spec closure defines the baseline set.
    # package_spec is a newline String → encoded to the base64 array on save.
    create(:system_node_module,
           account: account,
           name: System::BaseOsBaselineResolver::DEFAULT_BASE_OS_MODULE,
           package_spec: "#{libc}\n#{coreutils}\n")
  end

  def materialize(include_baseline:)
    described_class.call(
      repository:        repo,
      package_name:      top_pkg,
      architectures:     [ "amd64" ],
      account:           account,
      requested_by_user: user,
      dispatch_build:    false,
      include_baseline:  include_baseline
    )
  end

  context "with baseline exclusion (default)" do
    it "skips baseline packages, keeps non-baseline deps, and adds the synthetic base-os requires edge" do
      result = materialize(include_baseline: false)

      expect(result).to be_success
      expect(result.top_level_module.name).to eq(top_pkg)

      # libc6 (baseline) got NO per-package module...
      dep_names = result.dependency_modules.map(&:name)
      expect(dep_names).not_to include(a_string_matching(/--#{Regexp.escape(libc)}\z/))
      expect(result.baseline_excluded).to include(libc)

      # ...but the non-baseline libpcre still did, with its edge.
      expect(dep_names).to include(a_string_matching(/--#{Regexp.escape(libpcre)}\z/))
      libpcre_mod = result.dependency_modules.detect { |m| m.name.end_with?("--#{libpcre}") }
      expect(libpcre_mod).to be_present
      expect(
        System::ModuleDependency.requires.exists?(
          node_module_id: result.top_level_module.id, dependency_id: libpcre_mod.id
        )
      ).to be(true)

      # The synthetic top-level `requires base-os` edge exists (inc1's shape).
      base_os = System::NodeModule.find_by(account: account,
                                           name: System::BaseOsBaselineResolver::DEFAULT_BASE_OS_MODULE)
      expect(result.base_os_requires).to be_present
      expect(result.base_os_requires.dependency_type).to eq("requires")
      expect(result.base_os_requires.required).to be(true)
      edge = System::ModuleDependency.find_by(
        node_module_id: result.top_level_module.id, dependency_id: base_os.id, dependency_type: "requires"
      )
      expect(edge).to be_present

      # No NodeModule was ever created for the excluded baseline package.
      expect(
        System::NodeModule.where(account: account).where("name LIKE ?", "%--#{libc}").exists?
      ).to be(false)
    end

    it "is idempotent — re-running adds no duplicate synthetic edge or modules" do
      materialize(include_baseline: false)
      mods_before = System::NodeModule.count
      deps_before = System::ModuleDependency.count

      materialize(include_baseline: false)

      expect(System::NodeModule.count).to eq(mods_before)
      expect(System::ModuleDependency.count).to eq(deps_before)
    end
  end

  context "with include_baseline: true (escape hatch)" do
    it "keeps the full closure — baseline packages get their own modules and no synthetic edge is added" do
      result = materialize(include_baseline: true)

      expect(result).to be_success
      expect(result.baseline_excluded).to eq([])
      expect(result.base_os_requires).to be_nil

      dep_names = result.dependency_modules.map(&:name)
      expect(dep_names).to include(a_string_matching(/--#{Regexp.escape(libc)}\z/))
      expect(dep_names).to include(a_string_matching(/--#{Regexp.escape(libpcre)}\z/))

      base_os = System::NodeModule.find_by(account: account,
                                           name: System::BaseOsBaselineResolver::DEFAULT_BASE_OS_MODULE)
      expect(
        System::ModuleDependency.exists?(node_module_id: result.top_level_module.id, dependency_id: base_os.id)
      ).to be(false)
    end
  end

  context "when no base-os module exists (pre-inc2 fallback)" do
    it "materializes the full closure with no exclusion and no synthetic edge" do
      System::NodeModule.where(account: account,
                               name: System::BaseOsBaselineResolver::DEFAULT_BASE_OS_MODULE).destroy_all

      result = materialize(include_baseline: false)

      expect(result).to be_success
      expect(result.baseline_excluded).to eq([])
      expect(result.base_os_requires).to be_nil
      expect(result.dependency_modules.map(&:name)).to include(a_string_matching(/--#{Regexp.escape(libc)}\z/))
    end
  end
end
