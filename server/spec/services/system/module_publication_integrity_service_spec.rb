# frozen_string_literal: true

require "rails_helper"

# Detects "published but unrecorded": the artifact reached the OCI registry and
# was signed, but no NodeModuleVersion row exists for it.
#
# A module build pushes and cosign-signs BEFORE it notifies the platform, so
# every failure after that point produces exactly this state — and the run goes
# red, which reads as "the build broke" rather than "the build shipped and
# nothing recorded it". On 2026-07-27 the cause was a TLS trust failure in the
# notify preflight, and it masked a second unrelated fault for days.
RSpec.describe System::ModulePublicationIntegrityService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, variety: "subscription") }

  subject(:service) { described_class.new(account: account) }

  before do
    allow(System::DiskImageRegistryConfig).to receive(:registry_host).and_return("git.example.org")
    allow(System::DiskImageRegistryConfig).to receive(:registry_user).and_return(nil)
    allow(System::DiskImageRegistryConfig).to receive(:registry_token).and_return(nil)
  end

  def a_module(name, repo: "powernode/#{name}")
    create(:system_node_module,
           account: account, node_platform: platform, category: category,
           name: name, variety: "subscription", gitea_repo_full_name: repo)
  end

  def a_version(node_module, tag)
    create(:system_node_module_version, node_module: node_module, config: { "git_tag" => tag })
  end

  # oras repo tags → stdout, one tag per line.
  def stub_tags(*tags, status: instance_double(Process::Status, success?: true, exitstatus: 0))
    allow(Open3).to receive(:capture3)
      .with(hash_including("DOCKER_CONFIG"), "oras", "repo", "tags", anything)
      .and_return([ tags.join("\n"), "", status ])
  end

  describe "#check" do
    it "reports a registry tag the platform never recorded" do
      mod = a_module("powernode-system-base")
      a_version(mod, "aaaaaaa")
      stub_tags("aaaaaaa", "bbbbbbb")

      finding = service.check(module_name: "powernode-system-base").first

      expect(finding.unrecorded_tags).to eq([ "bbbbbbb" ])
      expect(finding).not_to be_ok
    end

    it "is clean when every registry tag has a version row" do
      mod = a_module("gitleaks")
      a_version(mod, "aaaaaaa")
      a_version(mod, "bbbbbbb")
      stub_tags("aaaaaaa", "bbbbbbb")

      finding = service.check(module_name: "gitleaks").first

      expect(finding.unrecorded_tags).to be_empty
      expect(finding).to be_ok
    end

    # A module CI has never built is not a failure. Reporting it as one would
    # bury the findings that matter under noise.
    it "treats a repository that does not exist yet as empty, not as an error" do
      a_module("never-built")
      allow(Open3).to receive(:capture3)
        .with(hash_including("DOCKER_CONFIG"), "oras", "repo", "tags", anything)
        .and_return([ "", "Error: repository name not known to registry", instance_double(Process::Status, success?: false, exitstatus: 1) ])

      finding = service.check(module_name: "never-built").first

      expect(finding.error).to be_nil
      expect(finding).to be_ok
      expect(finding.registry_tags).to be_empty
    end

    it "surfaces a genuine registry failure as an error rather than a false clean" do
      a_module("broken")
      allow(Open3).to receive(:capture3)
        .with(hash_including("DOCKER_CONFIG"), "oras", "repo", "tags", anything)
        .and_return([ "", "connection refused", instance_double(Process::Status, success?: false, exitstatus: 1) ])

      finding = service.check(module_name: "broken").first

      expect(finding.error).to match(/connection refused/)
      expect(finding).not_to be_ok
    end

    # THE guard against scope creep. Modules here are built on-demand and
    # event-driven, so a module whose newest build predates its newest source
    # commit is normal. Only registry-vs-platform disagreement is a finding.
    it "does not report a module whose build merely predates its source" do
      mod = a_module("runtime-ruby")
      a_version(mod, "old-tag")
      stub_tags("old-tag")

      finding = service.check(module_name: "runtime-ruby").first

      expect(finding).to be_ok
    end

    it "checks only modules with a repo binding when no module is named" do
      a_module("bound")
      create(:system_node_module,
             account: account, node_platform: platform, category: category,
             name: "unbound", variety: "subscription", gitea_repo_full_name: nil)
      stub_tags

      names = service.check.map(&:module_name)

      expect(names).to include("bound")
      expect(names).not_to include("unbound")
    end
  end
end
