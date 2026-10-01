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
  # needs-parent-modules.sh (IMP-c19b10a942d7) is fetched beside stage15.sh; nil
  # is "absent at that ref", which the fixtures above (no shared block) allow.
  def stub_range(paths, base_script: base_stage15, head_script: base_stage15, base_list: nil, head_list: nil)
    fake_client = instance_double(Devops::Git::GiteaApiClient)
    allow(Devops::Git::ApiClient).to receive(:for).with(gitea_credential).and_return(fake_client)
    allow(fake_client).to receive(:compare_commits).and_return(commits: [ { sha: head_sha } ])
    allow(fake_client).to receive(:get_commit).and_return(files: paths.map { |p| { filename: p } })
    allow(fake_client).to receive(:get_file_content).with("powernode", "powernode-system", stage15_path, base_sha)
                                                    .and_return(base_script && { content: base_script })
    allow(fake_client).to receive(:get_file_content).with("powernode", "powernode-system", stage15_path, head_sha)
                                                    .and_return(head_script && { content: head_script })
    allow(fake_client).to receive(:get_file_content).with("powernode", "powernode-system", needs_parent_path, base_sha)
                                                    .and_return(base_list && { content: base_list })
    allow(fake_client).to receive(:get_file_content).with("powernode", "powernode-system", needs_parent_path, head_sha)
                                                    .and_return(head_list && { content: head_list })
    fake_client
  end

  let(:needs_parent_path) { "scripts/module-build/needs-parent-modules.sh" }
  let(:needs_parent_list) { "#!/usr/bin/env bash\nNEEDS_PARENT_MODULES=\"\nhub-backend\nhub-worker\n\"\n" }
  let(:shared_block) do
    "# --- BEGIN needs-parent shared block ---\n" \
      "if [ \"$needs_parent\" = \"1\" ]; then\n  git clone --depth 1 \"$clone_url\" /tmp/parent\nfi\n" \
      "# --- END needs-parent shared block ---\n"
  end

  # IMP-c19b10a942d7: the parent-clone block outside every arm is an input of the
  # modules needs-parent-modules.sh lists — hub-frontend has an arm but is not
  # listed, so it stays out of the plan.
  it "a change inside the needs-parent shared block targets the listed modules plus module-forge" do
    base = shared_block + base_stage15
    head = base.sub("git clone --depth 1 ", "git clone --depth 1 --no-tags ")
    stub_range([ stage15_path ], base_script: base, head_script: head,
                                 base_list: needs_parent_list, head_list: needs_parent_list)

    expect(plan_names).to eq(%w[hub-backend hub-worker module-forge])
  end

  it "a stage15.sh with the shared block but no readable needs-parent list warns and plans module-forge only" do
    base = shared_block + base_stage15
    head = base.sub("git clone --depth 1 ", "git clone --depth 1 --no-tags ")
    stub_range([ stage15_path ], base_script: base, head_script: head)
    allow(Rails.logger).to receive(:warn).and_call_original

    expect(plan_names).to eq(%w[module-forge])
    expect(Rails.logger).to have_received(:warn).with(/build-script attribution failed.*shared block/)
  end

  # The fallback must be visible to the caller, not only to the log: a dispatch
  # that succeeded having dropped modules reads as a clean dispatch otherwise.
  it "carries the attribution fallback on the PlanResult, and nil when attribution held" do
    base = shared_block + base_stage15
    head = base.sub("git clone --depth 1 ", "git clone --depth 1 --no-tags ")
    stub_range([ stage15_path ], base_script: base, head_script: head)
    allow(Rails.logger).to receive(:warn).and_call_original

    fallen = described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha)
    expect(fallen.attribution_fallback).to match(/shared block/)
    expect(fallen.attribution_fallback).to include("module-forge")

    stub_range([ stage15_path ], base_script: base, head_script: head,
                                 base_list: needs_parent_list, head_list: needs_parent_list)
    expect(described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha).attribution_fallback).to be_nil
  end

  # A range whose base predates the list: needs-parent-modules.sh is PRESENT at
  # the base in its old case-statement shape (not absent), and the base
  # stage15.sh has no block. That is the shape of the first dispatch after the
  # list lands, and it must keep every attribution the old reader made.
  it "a range whose base predates the list still targets an arm edit and the block's arrival" do
    pre_list = "#!/usr/bin/env bash\nmodule_needs_parent() {\n  case \"${1:-}\" in\n    hub-backend|hub-worker) return 0 ;;\n    *) return 1 ;;\n  esac\n}\n"
    head = (shared_block + base_stage15).sub("apt-get install -y redis-server", "apt-get install -y redis-server redis-tools")
    stub_range([ stage15_path, needs_parent_path ], base_script: base_stage15, head_script: head,
                                                    base_list: pre_list, head_list: needs_parent_list)

    expect(plan_names).to eq(%w[hub-backend hub-worker module-forge redis])
    expect(described_class.plan_with_diagnostics(base_sha: base_sha, head_sha: head_sha).attribution_fallback).to be_nil
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

  # F5: a catch-all already plans every module, so reading stage15.sh is wasted work.
  it "does not read stage15.sh once a catch-all trigger has fired" do
    fake_client = stub_range([ ".gitea/workflows/build-platform-modules.yaml", "scripts/module-build/push.sh" ])

    expect(plan_names).to eq(%w[hub-backend hub-frontend hub-worker module-forge redis])
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
