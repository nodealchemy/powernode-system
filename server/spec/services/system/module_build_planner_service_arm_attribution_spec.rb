# frozen_string_literal: true

require "rails_helper"

# IMP-24d473c6f448 — a scripts/module-build/* change used to map to module-forge
# ONLY, so a change confined to one module's stage15 build arm (or to a helper
# that arm calls) could not target that module. The planner now derives the
# attribution from the scripts' own case arms (System::ModuleBuildScriptAttribution).
#
# Motivating case IMP-094d900f9093: it changed only the hub-backend arm plus a
# new assertion script that arm calls; the range planned [module-forge] alone.
RSpec.describe System::ModuleBuildPlannerService, "build-script attribution" do
  let!(:account) { create(:account) }
  let(:gitea_provider) { create(:git_provider, :gitea, account: account) }
  let!(:gitea_credential) do
    create(:git_provider_credential, :gitea, account: account, provider: gitea_provider)
  end

  let!(:module_forge)  { create(:system_node_module, account: account, name: "module-forge", manifest_yaml: "schema_version: 1") }
  let!(:hub_backend)   { create(:system_node_module, account: account, name: "hub-backend", manifest_yaml: "schema_version: 1") }
  let!(:hub_worker)    { create(:system_node_module, account: account, name: "hub-worker", manifest_yaml: "schema_version: 1") }
  let!(:hub_frontend)  { create(:system_node_module, account: account, name: "hub-frontend", manifest_yaml: "schema_version: 1") }
  let!(:redis)         { create(:system_node_module, account: account, name: "redis", manifest_yaml: "schema_version: 1") }

  let(:base_sha) { "a" * 40 }
  let(:head_sha) { "b" * 40 }
  let(:stage15_path) { "scripts/module-build/stage15.sh" }

  let(:base_stage15) do
    <<~'SH'
      #!/usr/bin/env bash
      case "$MODULE" in
        redis)
          apt-get install -y redis-server
          ;;
        hub-backend)
          rsync -a /tmp/parent/server/ /tmp/fat/server/
          bash "$SCRIPT_DIR/assert-lock.sh" --workspace "$ws"
          ;;
        hub-worker|hub-frontend)
          bash "$SCRIPT_DIR/stage-files.sh" --workspace "$ws"
          ;;
        *)
          echo "no arm for $MODULE"
          ;;
      esac
      echo done
    SH
  end

  def edited(from, to)
    base_stage15.sub(from, to).tap { |t| raise "fixture edit missed: #{from}" if t == base_stage15 }
  end

  # The live Gitea shape: the compare API lists commits only, each commit's own
  # detail lists the changed files (filename/status, no patch), and the two
  # stage15.sh copies come from the contents API at the range's two ends.
  def stub_range(paths, base_script: base_stage15, head_script: base_stage15)
    fake_client = instance_double(Devops::Git::GiteaApiClient)
    allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
    allow(fake_client).to receive(:compare_commits).and_return(commits: [ { sha: head_sha } ])
    allow(fake_client).to receive(:get_commit).and_return(files: paths.map { |p| { filename: p } })
    allow(fake_client).to receive(:get_file_content).with("powernode", "powernode-system", stage15_path, base_sha)
                                                    .and_return(base_script && { content: base_script })
    allow(fake_client).to receive(:get_file_content).with("powernode", "powernode-system", stage15_path, head_sha)
                                                    .and_return(head_script && { content: head_script })
    fake_client
  end

  def plan_names(**opts)
    described_class.plan(base_sha: base_sha, head_sha: head_sha, **opts).map { |e| e[:module] }.sort
  end

  it "a change inside the hub-backend arm targets hub-backend" do
    head = edited("rsync -a /tmp/parent/server/", "rsync -aH /tmp/parent/server/")
    stub_range([ stage15_path ], head_script: head)

    expect(plan_names).to eq(%w[hub-backend module-forge])
  end

  it "the motivating range (arm change + the new assertion script it calls) can be narrow-dispatched to hub-backend" do
    head = edited("rsync -a /tmp/parent/server/", "rsync -aH /tmp/parent/server/")
    stub_range([ stage15_path, "scripts/module-build/assert-lock.sh", "scripts/module-build/should-skip-build.sh" ],
               head_script: head)

    result = described_class.plan_with_diagnostics(
      base_sha: base_sha, head_sha: head_sha, module_slugs: [ "hub-backend" ], expand_dependents: false
    )
    expect(result.entries.map { |e| e[:module] }).to eq(%w[hub-backend])
  end

  it "a change to a shared helper targets module-forge plus every module whose arm calls it" do
    stub_range([ "scripts/module-build/stage-files.sh" ])

    expect(plan_names).to eq(%w[hub-frontend hub-worker module-forge])
  end

  it "a change to a helper that only one arm calls targets module-forge plus that module" do
    stub_range([ "scripts/module-build/assert-lock.sh" ])

    expect(plan_names).to eq(%w[hub-backend module-forge])
  end

  it "an unrelated script change targets module-forge only" do
    stub_range([ "scripts/module-build/should-skip-build.sh" ])

    expect(plan_names).to eq(%w[module-forge])
  end

  it "a stage15.sh change outside every arm targets module-forge only" do
    stub_range([ stage15_path ], head_script: edited("echo done", "echo finished"))

    expect(plan_names).to eq(%w[module-forge])
  end

  it "a change inside the wildcard arm counts as shared" do
    stub_range([ stage15_path ], head_script: edited("echo \"no arm for $MODULE\"", "echo \"unknown $MODULE\""))

    expect(plan_names).to eq(%w[module-forge])
  end

  it "attributes a change inside a multi-slug arm to all of its slugs" do
    head = edited("stage-files.sh\" --workspace \"$ws\"", "stage-files.sh\" --workspace \"$ws\" --fast")
    stub_range([ stage15_path ], head_script: head)

    expect(plan_names).to eq(%w[hub-frontend hub-worker module-forge])
  end

  it "keeps reverse-dependency expansion unchanged for an attributed module" do
    create(:system_module_dependency, node_module: redis, dependency: hub_backend)
    stub_range([ stage15_path ], head_script: edited("rsync -a /tmp/parent/server/", "rsync -aH /tmp/parent/server/"))

    expect(plan_names).to eq(%w[hub-backend module-forge redis])
  end

  it "does not consult the scripts at all for a range that touches no build script" do
    fake_client = stub_range([ "modules/redis/rootfs/marker" ])

    expect(plan_names).to eq(%w[redis])
    expect(fake_client).not_to have_received(:get_file_content)
  end

  describe "fallback to module-forge only" do
    before { allow(Rails.logger).to receive(:warn) }

    it "when stage15.sh cannot be parsed, warns and plans module-forge only" do
      stub_range([ stage15_path ], head_script: "#!/bin/bash\necho no dispatch here\n")

      expect(plan_names).to eq(%w[module-forge])
      expect(Rails.logger).to have_received(:warn).with(/ModuleBuildPlannerService.*build-script attribution/)
    end

    it "when a copy of stage15.sh cannot be fetched, warns and plans module-forge only" do
      stub_range([ stage15_path ], base_script: nil)

      expect(plan_names).to eq(%w[module-forge])
      expect(Rails.logger).to have_received(:warn).with(/ModuleBuildPlannerService.*build-script attribution/)
    end

    it "when the contents fetch raises, warns and plans module-forge only" do
      fake_client = stub_range([ "scripts/module-build/assert-lock.sh" ])
      allow(fake_client).to receive(:get_file_content).and_raise(Devops::Git::ApiClient::ApiError.new("boom", status: 500))

      expect(plan_names).to eq(%w[module-forge])
      expect(Rails.logger).to have_received(:warn).with(/ModuleBuildPlannerService.*build-script attribution/)
    end

    it "when a copy is implausibly large, warns and plans module-forge only" do
      stub_range([ "scripts/module-build/assert-lock.sh" ],
                 head_script: base_stage15 + ("#" * (described_class::BUILD_SCRIPT_MAX_BYTES + 1)))

      expect(plan_names).to eq(%w[module-forge])
    end
  end

  it "does not attribute scripts in the CORE repo (its own scripts/ rule stands)" do
    fake_client = instance_double(Devops::Git::GiteaApiClient)
    allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
    allow(fake_client).to receive(:compare_commits).and_return(commits: [ { sha: head_sha } ])
    allow(fake_client).to receive(:get_commit).and_return(files: [ { filename: "scripts/module-build/stage15.sh" } ])
    create(:system_node_module, account: account, name: "powernode-hub-backend", manifest_yaml: "schema_version: 1")

    names = described_class.plan(base_sha: base_sha, head_sha: head_sha, source_repo: "powernode/powernode-platform")
                           .map { |e| e[:module] }
    expect(names).to eq(%w[powernode-hub-backend])
  end
end
