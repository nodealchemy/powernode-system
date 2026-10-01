# frozen_string_literal: true

require "rails_helper"

# A CORE-range plan must never regress an extension-sourced module.
#
# The incident: a dispatch with source_repo powernode/powernode-platform over a
# core-only range planned powernode-extension-system off core's extensions/system
# submodule pointer, which was four commits BEHIND the commit the module's live
# version had been built from. Publishing would have rolled the fleet back by
# those four commits. Nothing compared the commit the plan would build from
# against the commit behind the currently published version.
#
# The guard: when a core range pins an extension-sourced module at a commit that
# is a STRICT ANCESTOR of the commit behind its current published version, that
# module is withheld with a named reason and reported like withheld dependents —
# never dropped silently, never a refusal of the whole batch while siblings
# remain. Ancestry that cannot be established is withheld too (fail-closed):
# the only silent outcome permitted is "nothing to regress".
RSpec.describe System::ModuleBuildPlannerService, "extension source-regression guard" do
  let!(:account) { create(:account) }
  let(:gitea_provider) { create(:git_provider, :gitea, account: account) }
  let!(:gitea_credential) do
    create(:git_provider_credential, :gitea, account: account, provider: gitea_provider)
  end

  let!(:hub_backend) do
    create(:system_node_module, account: account, name: "powernode-hub-backend", manifest_yaml: "schema_version: 1")
  end
  let!(:ext_system) do
    create(:system_node_module, account: account, name: "powernode-extension-system", manifest_yaml: "schema_version: 1")
  end

  let(:core_repo) { "powernode/powernode-platform" }
  let(:ext_repo)  { "powernode/powernode-system" }
  let(:base_sha)  { "a" * 40 }
  let(:head_sha)  { "b" * 40 }
  # The commit core pins extensions/system at head_sha, and the commit the live
  # extension version was built from.
  let(:pinned_sha)    { "c" * 40 }
  let(:published_sha) { "d" * 40 }
  let(:ext_oci_ref)   { "registry.example.com/powernode/powernode-extension-system:dddddd1" }

  let(:fake_client) { instance_double(Devops::Git::GiteaApiClient) }

  before do
    allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
  end

  # The range: one core commit touching the given paths.
  def stub_core_range(paths)
    owner, repo = core_repo.split("/", 2)
    allow(fake_client).to receive(:compare_commits)
      .with(owner, repo, base_sha, head_sha)
      .and_return(commits: [ { sha: head_sha } ])
    allow(fake_client).to receive(:get_commit)
      .with(owner, repo, head_sha)
      .and_return(files: paths.map { |p| { filename: p } })
  end

  # What core pins extensions/system at, as the Gitea contents API reports a
  # gitlink: type "submodule", sha = the pointed-at commit.
  def stub_submodule_pointer(sha, type: "submodule")
    owner, repo = core_repo.split("/", 2)
    allow(fake_client).to receive(:get_file_content)
      .with(owner, repo, "extensions/system", head_sha)
      .and_return(sha.nil? ? nil : { type: type, sha: sha, path: "extensions/system", content: nil })
  end

  # Gitea compare base...head lists the commits in head that base lacks. An
  # ancestor compared forward has commits; compared backward it has none.
  def stub_ancestry(forward:, backward:)
    owner, repo = ext_repo.split("/", 2)
    allow(fake_client).to receive(:compare_commits)
      .with(owner, repo, pinned_sha, published_sha)
      .and_return(commits: Array.new(forward) { |i| { sha: "f#{i}" } })
    allow(fake_client).to receive(:compare_commits)
      .with(owner, repo, published_sha, pinned_sha)
      .and_return(commits: Array.new(backward) { |i| { sha: "g#{i}" } })
  end

  # The live version, and the module-source commit push.sh stamped on its
  # artifact (org.powernode.built_from_sha) — the only record of that commit.
  def publish_current_version!(source_sha, version_number: 132)
    version = create(:system_node_module_version, node_module: ext_system, version_number: version_number,
                                                  artifacts: { "erofs" => { "oci_ref" => ext_oci_ref, "oci_digest" => "sha256:#{'1' * 64}" } })
    ext_system.update_columns(current_version_id: version.id, current_version_number: version_number)
    stub_manifest_annotations(source_sha.nil? ? {} : { "org.powernode.built_from_sha" => source_sha })
    version
  end

  def stub_manifest_annotations(annotations, status: :found)
    manifest = if status == :found
      ::System::OciManifestClient::Manifest.new(manifest_digest: "sha256:#{'2' * 64}",
                                               erofs_layer: { "digest" => "sha256:#{'1' * 64}" },
                                               annotations: annotations)
    end
    allow(::System::OciManifestClient).to receive(:lookup)
      .with(node_module: ext_system, oci_ref: ext_oci_ref)
      .and_return(::System::OciManifestClient::Lookup.new(status: status, manifest: manifest))
  end

  def plan(**opts)
    described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha, source_repo: core_repo, **opts)
  end

  def modules_in(result)
    result.entries.map { |e| e[:module] }
  end

  describe "a core range whose pointer is strictly behind the live version" do
    before do
      stub_core_range([ "server/app/models/a.rb", "extensions/system" ])
      stub_submodule_pointer(pinned_sha)
      publish_current_version!(published_sha)
      stub_ancestry(forward: 4, backward: 0)
    end

    it "withholds the extension module, names why, and still plans its siblings" do
      result = plan

      expect(modules_in(result)).not_to include("powernode-extension-system")
      expect(modules_in(result)).to include("powernode-hub-backend")

      withheld = result.withheld_regressions
      expect(withheld.map { |w| w[:module] }).to eq([ "powernode-extension-system" ])
      entry = withheld.first
      expect(entry[:reason]).to eq(described_class::WITHHELD_SOURCE_REGRESSION)
      expect(entry[:pinned_sha]).to eq(pinned_sha)
      expect(entry[:published_sha]).to eq(published_sha)
      expect(entry[:published_version_number]).to eq(132)
      expect(entry[:detail]).to include("4 commit(s) behind")
      expect(entry[:detail]).to include("v132")
      expect(entry[:detail]).to include("source_repo: #{ext_repo}")
    end

    it "is not double-reported as a withheld dependent" do
      result = plan

      expect(result.withheld_dependents).to eq([])
    end

    it "still withholds it when an explicit allowlist names it" do
      result = plan(module_slugs: %w[powernode-extension-system powernode-hub-backend], expand_dependents: false)

      expect(modules_in(result)).to eq([ "powernode-hub-backend" ])
      expect(result.withheld_regressions.map { |w| w[:module] }).to eq([ "powernode-extension-system" ])
    end

    it "refuses loudly, naming the withheld module, when nothing is left to build" do
      expect { plan(module_slugs: [ "powernode-extension-system" ], expand_dependents: false) }
        .to raise_error(described_class::PlanningError,
                        /planned 0 modules.*powernode-extension-system withheld \(source_regression\)/m)
    end
  end

  describe "a core range that does not regress the extension" do
    before { stub_core_range([ "extensions/system" ]) }

    it "builds it when the pointer IS the published commit, without comparing ancestry" do
      stub_submodule_pointer(published_sha)
      publish_current_version!(published_sha)

      result = plan

      expect(modules_in(result)).to eq([ "powernode-extension-system" ])
      expect(result.withheld_regressions).to eq([])
    end

    it "builds it when the pointer is AHEAD of the published commit" do
      stub_submodule_pointer(pinned_sha)
      publish_current_version!(published_sha)
      stub_ancestry(forward: 0, backward: 3)

      expect(modules_in(plan)).to eq([ "powernode-extension-system" ])
    end

    it "builds it when the two commits have diverged (neither is the other's ancestor)" do
      stub_submodule_pointer(pinned_sha)
      publish_current_version!(published_sha)
      stub_ancestry(forward: 2, backward: 2)

      expect(modules_in(plan)).to eq([ "powernode-extension-system" ])
    end

    it "builds it when the module has no published version — there is nothing to regress" do
      # No pointer read, no registry read, no compare: nothing is stubbed for
      # them and the verifying double would refuse the call.
      result = plan

      expect(modules_in(result)).to eq([ "powernode-extension-system" ])
      expect(result.withheld_regressions).to eq([])
    end
  end

  describe "ancestry that cannot be established is withheld, never silently built" do
    before do
      stub_core_range([ "server/app/models/a.rb", "extensions/system" ])
      publish_current_version!(published_sha)
    end

    def expect_undetermined(result, detail:)
      expect(modules_in(result)).to eq([ "powernode-hub-backend" ])
      entry = result.withheld_regressions.first
      expect(entry[:module]).to eq("powernode-extension-system")
      expect(entry[:reason]).to eq(described_class::WITHHELD_SOURCE_ANCESTRY_UNDETERMINED)
      expect(entry[:detail]).to match(detail)
      expect(entry[:detail]).to include("source_repo: #{ext_repo}")
    end

    it "when the gitlink cannot be read at head_sha" do
      stub_submodule_pointer(nil)

      expect_undetermined(plan, detail: /gitlink.*could not be read/)
    end

    it "when the path at head_sha is not a gitlink" do
      stub_submodule_pointer(pinned_sha, type: "dir")

      expect_undetermined(plan, detail: /not a submodule gitlink/)
    end

    it "when the live artifact carries no built_from_sha annotation" do
      stub_submodule_pointer(pinned_sha)
      stub_manifest_annotations({})

      expect_undetermined(plan, detail: /no org\.powernode\.built_from_sha annotation/)
    end

    it "when the live artifact's manifest cannot be fetched" do
      stub_submodule_pointer(pinned_sha)
      stub_manifest_annotations({}, status: :unavailable)

      expect_undetermined(plan, detail: /manifest.*could not be read/)
    end

    it "when the extension-repo compare fails" do
      stub_submodule_pointer(pinned_sha)
      owner, repo = ext_repo.split("/", 2)
      allow(fake_client).to receive(:compare_commits).with(owner, repo, pinned_sha, published_sha)
        .and_raise(Devops::Git::ApiClient::ApiError.new("boom", 502))

      result = plan

      expect_undetermined(result, detail: /compare.*failed: status 502/)
    end
  end

  describe "scope" do
    it "applies under force_all with a core source_repo" do
      stub_submodule_pointer(pinned_sha)
      publish_current_version!(published_sha)
      stub_ancestry(forward: 4, backward: 0)

      result = plan(force_all: true)

      expect(modules_in(result)).to eq([ "powernode-hub-backend" ])
      expect(result.withheld_regressions.map { |w| w[:module] }).to eq([ "powernode-extension-system" ])
    end

    it "leaves an extension-range plan alone — head_sha IS the commit it builds" do
      owner, repo = ext_repo.split("/", 2)
      allow(fake_client).to receive(:compare_commits).with(owner, repo, base_sha, head_sha)
        .and_return(commits: [ { sha: head_sha } ])
      allow(fake_client).to receive(:get_commit).with(owner, repo, head_sha)
        .and_return(files: [ { filename: "server/app/models/a.rb" } ])
      publish_current_version!(published_sha)

      result = described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha, source_repo: ext_repo)

      expect(modules_in(result)).to eq([ "powernode-extension-system" ])
      expect(result.withheld_regressions).to eq([])
    end
  end
end
