# frozen_string_literal: true

require "rails_helper"

# Covers the `providing` scope on NodeModule, which answers
# "what modules provide capability X?" without hand-crafted joins.
RSpec.describe System::NodeModule, ".providing" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:repo)     { create(:system_package_repository, account: account) }

  def make_module(name:)
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription",
           name: "prov-spec-#{name}-#{SecureRandom.hex(3)}")
  end

  it "returns the empty scope when called with blank capability" do
    expect(described_class.providing(nil)).to be_a(ActiveRecord::Relation)
    # blank capability should be a no-op (returns all)
    target = make_module(name: "anywhere")
    expect(described_class.providing("").pluck(:id)).to include(target.id)
  end

  it "finds a module via its package's name match" do
    mod = make_module(name: "py3")
    pkg = create(:system_package, package_repository: repo, name: "python3",
                 architecture: "amd64", version: "3.11.0", provides: [])
    create(:system_package_module_link, node_module: mod, package_repository: repo,
           package_name: pkg.name, package_version: pkg.version, architecture: "amd64")

    expect(described_class.providing("python3").pluck(:id)).to include(mod.id)
  end

  it "finds a module via the package's provides JSONB" do
    mod = make_module(name: "py-alt")
    pkg = create(:system_package, package_repository: repo, name: "python-3.11-minimal",
                 architecture: "amd64", version: "3.11.0",
                 provides: [ [ { "name" => "python3", "op" => nil, "version" => nil } ] ])
    create(:system_package_module_link, node_module: mod, package_repository: repo,
           package_name: pkg.name, package_version: pkg.version, architecture: "amd64")

    expect(described_class.providing("python3").pluck(:id)).to include(mod.id)
  end

  it "excludes modules whose package does not provide the capability" do
    other = make_module(name: "perl-noise")
    pkg = create(:system_package, package_repository: repo, name: "perl",
                 architecture: "amd64", version: "5.36.0", provides: [])
    create(:system_package_module_link, node_module: other, package_repository: repo,
           package_name: pkg.name, package_version: pkg.version, architecture: "amd64")

    expect(described_class.providing("python3").pluck(:id)).not_to include(other.id)
  end

  it "excludes operator-authored modules (no PackageModuleLink)" do
    operator_mod = make_module(name: "hand-rolled")
    # No PackageModuleLink — should never appear in providing()

    expect(described_class.providing("python3").pluck(:id)).not_to include(operator_mod.id)
  end

  it "is distinct — a module with multiple matching provides entries appears once" do
    mod = make_module(name: "multi-provides")
    pkg = create(:system_package, package_repository: repo, name: "py-meta",
                 architecture: "amd64", version: "1.0.0",
                 provides: [
                   [ { "name" => "python", "op" => nil, "version" => nil } ],
                   [ { "name" => "python3", "op" => nil, "version" => nil } ]
                 ])
    create(:system_package_module_link, node_module: mod, package_repository: repo,
           package_name: pkg.name, package_version: pkg.version, architecture: "amd64")

    expect(described_class.providing("python").pluck(:id).count(mod.id)).to eq(1)
  end
end
