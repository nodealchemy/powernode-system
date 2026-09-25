# frozen_string_literal: true

require "rails_helper"

# NARROW-DISPATCH — an explicit module allowlist for a native build batch.
#
# Reverse-dependency expansion turns one agent/ edit into a build of nearly the
# whole catalog (system-base is required by base-os, which nearly everything
# requires), and publishing auto-promotes, so every closure member that builds
# is a fleet-wide deploy. The allowlist lets a caller build exactly the modules
# a change touched, with expansion switched off, while everything the range
# does not name stays refused: an allowlisted slug must be in the diff's own
# dirty set, full stop.
RSpec.describe System::ModuleBuildPlannerService, "module allowlist" do
  let!(:account) { create(:account) }
  let(:gitea_provider) { create(:git_provider, :gitea, account: account) }
  let!(:gitea_credential) do
    create(:git_provider_credential, :gitea, account: account, provider: gitea_provider)
  end

  #   powernode-system-base (provides the agent)
  #     `-- base-os (requires system-base)
  #           |-- redis (requires base-os)
  #           `-- hub-backend (requires base-os, redis)
  let!(:system_base) { create(:system_node_module, account: account, name: "powernode-system-base", manifest_yaml: "schema_version: 1") }
  let!(:base_os)     { create(:system_node_module, account: account, name: "base-os", manifest_yaml: "schema_version: 1") }
  let!(:redis)       { create(:system_node_module, account: account, name: "redis", manifest_yaml: "schema_version: 1") }
  let!(:hub_backend) { create(:system_node_module, account: account, name: "hub-backend", manifest_yaml: "schema_version: 1") }

  before do
    create(:system_module_dependency, node_module: base_os, dependency: system_base)
    create(:system_module_dependency, node_module: redis, dependency: base_os)
    create(:system_module_dependency, node_module: hub_backend, dependency: base_os)
    create(:system_module_dependency, node_module: hub_backend, dependency: redis)
  end

  let(:base_sha) { "a" * 40 }
  let(:head_sha) { "b" * 40 }

  def stub_changed_paths(paths)
    fake_client = instance_double(Devops::Git::GiteaApiClient)
    allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
    allow(fake_client).to receive(:compare_commits)
      .with("powernode", "powernode-system", base_sha, head_sha)
      .and_return(commits: [ { sha: head_sha } ])
    allow(fake_client).to receive(:get_commit)
      .with("powernode", "powernode-system", head_sha)
      .and_return(files: paths.map { |p| { filename: p } })
  end

  def plan(**opts)
    described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha, **opts)
  end

  def modules_in(result)
    result.entries.map { |e| e[:module] }
  end

  describe "default mode (no allowlist)" do
    it "still expands an agent/ change to system-base and its whole closure" do
      stub_changed_paths([ "agent/internal/runtime/reconcile.go" ])

      result = plan

      expect(modules_in(result)).to contain_exactly("powernode-system-base", "base-os", "redis", "hub-backend")
      expect(result.withheld_dependents).to eq([])
    end
  end

  describe "module_slugs with expand_dependents: false" do
    it "builds exactly the allowlist and reports the closure it withheld" do
      stub_changed_paths([ "agent/internal/runtime/reconcile.go" ])

      result = plan(module_slugs: [ "powernode-system-base" ], expand_dependents: false)

      expect(modules_in(result)).to eq([ "powernode-system-base" ])
      expect(result.entries.first[:oci_ref]).to eq(head_sha[0, 7])
      expect(result.withheld_dependents).to eq(%w[base-os hub-backend redis])
    end

    it "refuses a slug the diff did not touch, naming it" do
      stub_changed_paths([ "agent/internal/runtime/reconcile.go" ])

      expect { plan(module_slugs: %w[powernode-system-base redis], expand_dependents: false) }
        .to raise_error(described_class::PlanningError, /not changed by #{base_sha[0, 12]}\.\.#{head_sha[0, 12]}: redis —/)
    end

    it "refuses a closure member the diff reaches only through expansion" do
      # base-os is in the closure of an agent/ change but its own tree did not
      # change: allowlisting it would build unchanged source.
      stub_changed_paths([ "agent/internal/runtime/reconcile.go" ])

      expect { plan(module_slugs: [ "base-os" ], expand_dependents: false) }
        .to raise_error(described_class::PlanningError, /base-os/)
    end

    it "refuses an unknown slug, naming every offender" do
      stub_changed_paths([ "agent/internal/runtime/reconcile.go" ])

      expect { plan(module_slugs: %w[powernode-system-base no-such-module also-missing], expand_dependents: false) }
        .to raise_error(described_class::PlanningError, /also-missing.*no-such-module|no-such-module.*also-missing/m)
    end

    it "refuses a package-origin slug as not buildable by this planner" do
      pkg = create(:system_node_module, account: account, name: "pkg-thing", manifest_yaml: nil)
      create(:system_package_module_link, node_module: pkg)
      stub_changed_paths([ "agent/internal/runtime/reconcile.go" ])

      expect { plan(module_slugs: %w[powernode-system-base pkg-thing], expand_dependents: false) }
        .to raise_error(described_class::PlanningError, /pkg-thing \(package_origin\)/)
    end

    it "refuses an empty allowlist" do
      stub_changed_paths([ "agent/internal/runtime/reconcile.go" ])

      expect { plan(module_slugs: [], expand_dependents: false) }
        .to raise_error(described_class::PlanningError, /module_slugs/)
    end
  end

  describe "module_slugs with expand_dependents: true" do
    it "seeds the closure from the allowlist only" do
      stub_changed_paths([ "modules/redis/manifest.yaml", "modules/base-os/manifest.yaml" ])

      result = plan(module_slugs: [ "redis" ], expand_dependents: true)

      expect(modules_in(result)).to contain_exactly("redis", "hub-backend")
      expect(result.withheld_dependents).to eq([])
    end
  end

  describe "argument combinations" do
    it "refuses expand_dependents: false without an allowlist" do
      expect { plan(expand_dependents: false) }
        .to raise_error(described_class::PlanningError, /expand_dependents.*module_slugs/)
    end

    it "refuses an allowlist together with force_all" do
      expect { plan(module_slugs: [ "redis" ], force_all: true) }
        .to raise_error(described_class::PlanningError, /force_all/)
    end
  end
end
