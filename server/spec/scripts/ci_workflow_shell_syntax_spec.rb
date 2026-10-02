# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "yaml"

# 2026-09-17 -> 2026-09-28 (IMP-4909ae43473d): 52a5e06c put an apostrophe
# ("composer's") inside the single-quoted `docker exec bash -c '...'` block of
# both UKI build steps. Bash failed each step with "syntax error near unexpected
# token `)'" before any image was built, so every disk-image build failed for 11
# days. Nothing in CI parsed workflow shell: ruby-syntax checks .rb only, and
# the tests/module-build/*.sh suites are not wired into ci.yaml.
#
# scripts/ci-lint-workflow-shell.rb extracts every `run:` block, neutralises
# ${{ }} expressions and runs `bash -n` on each.
RSpec.describe "CI workflow shell syntax lint" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:script)         { File.join(extension_root, "scripts/ci-lint-workflow-shell.rb") }

  def lint(*paths)
    Open3.capture3(RbConfig.ruby, script, *paths)
  end

  def with_workflow(yaml)
    Dir.mktmpdir("wf-lint") do |dir|
      path = File.join(dir, "wf.yaml")
      File.write(path, yaml)
      yield dir, path
    end
  end

  # The exact shape of the historical break: a single-quoted bash -c script that
  # contains an apostrophe in an echo string.
  let(:stray_apostrophe) do
    <<~'YAML'
      name: build
      jobs:
        build-arm64:
          runs-on: ubuntu-24.04
          steps:
            - name: Build UKI
              run: |
                docker exec c bash -c '
                  for t in sfdisk fsverity; do command -v "$t" >/dev/null || { echo "FATAL: $t missing (fsverity for the boot composer's module check)"; exit 1; }; done
                  cd /work && ./build.sh --arch arm64
                '
    YAML
  end

  it "FAILS on the historical stray-apostrophe text and names the step" do
    with_workflow(stray_apostrophe) do |_dir, path|
      out, err, status = lint(path)

      expect(status.exitstatus).to eq(1)
      expect(out + err).to include("build-arm64")
      expect(out + err).to include("Build UKI")
      expect(out + err).to match(/syntax error/)
    end
  end

  it "PASSES the fixed text (apostrophe removed)" do
    with_workflow(stray_apostrophe.sub("composer's", "composer")) do |_dir, path|
      _out, _err, status = lint(path)
      expect(status.exitstatus).to eq(0)
    end
  end

  it "neutralises ${{ }} expressions, including ones with quotes and spaces, rather than tripping on them" do
    yaml = <<~'YAML'
      jobs:
        j:
          steps:
            - run: |
                echo "${{ github.ref_name }}" "${{ format('{0}-{1}', 'a', github.sha) }}"
                if [ "${{ matrix.arch }}" = "amd64" ]; then echo ok; fi
    YAML
    with_workflow(yaml) do |_dir, path|
      _out, err, status = lint(path)
      expect(status.exitstatus).to eq(0), err
    end
  end

  it "skips steps that declare a non-bash shell, and says so" do
    yaml = <<~'YAML'
      jobs:
        j:
          steps:
            - shell: python
              run: |
                print("it's fine"
    YAML
    with_workflow(yaml) do |_dir, path|
      out, err, status = lint(path)
      expect(status.exitstatus).to eq(0), err
      expect(out).to match(/1 skipped/)
    end
  end

  it "ignores steps with no run: block (uses:)" do
    with_workflow("jobs:\n  j:\n    steps:\n      - uses: actions/checkout@v4\n      - run: echo ok\n") do |_dir, path|
      _out, _err, status = lint(path)
      expect(status.exitstatus).to eq(0)
    end
  end

  it "accepts a directory and reports every broken file, not just the first" do
    Dir.mktmpdir("wf-lint") do |dir|
      File.write(File.join(dir, "a.yaml"), stray_apostrophe)
      File.write(File.join(dir, "b.yml"), stray_apostrophe.sub("build-arm64", "build-amd64"))
      out, err, status = lint(dir)

      expect(status.exitstatus).to eq(1)
      expect(out + err).to include("a.yaml").and include("b.yml")
    end
  end

  it "FAILS on a heredoc with no terminator (bash -n only warns)" do
    yaml = "jobs:\n  j:\n    steps:\n      - run: |\n          cat <<EOF2\n          body\n"
    with_workflow(yaml) do |_dir, path|
      _out, err, status = lint(path)
      expect(status.exitstatus).to eq(1)
      expect(err).to match(/here-document/)
    end
  end

  it "honours a workflow-level defaults.run.shell and an absolute-path shell" do
    yaml = <<~'YAML'
      defaults:
        run:
          shell: python
      jobs:
        j:
          steps:
            - run: print("it's fine"
            - shell: /bin/bash
              run: echo "ok"
    YAML
    with_workflow(yaml) do |_dir, path|
      out, err, status = lint(path)
      expect(status.exitstatus).to eq(0), err
      expect(out).to match(/1 run block\(s\) checked, 1 skipped/)
    end
  end

  it "does not read a file with no jobs mapping as clean" do
    with_workflow("name: oops\njob:\n  x: 1\n") do |_dir, path|
      _out, _err, status = lint(path)
      expect(status.exitstatus).to eq(2)
    end
  end

  it "exits non-zero (not green) when a workflow is not parseable YAML" do
    with_workflow("jobs: [unclosed\n") do |_dir, path|
      _out, _err, status = lint(path)
      expect(status.exitstatus).to eq(2)
    end
  end

  it "exits non-zero when given no workflow files at all (an empty glob must not read as clean)" do
    Dir.mktmpdir("wf-lint") do |dir|
      _out, _err, status = lint(dir)
      expect(status.exitstatus).to eq(2)
    end
  end

  it "is wired into ci.yaml's ruby-syntax job, so deleting the step is a red spec" do
    ci = YAML.safe_load(File.read(File.join(extension_root, ".gitea/workflows/ci.yaml")), aliases: true)
    steps = Array(ci.dig("jobs", "ruby-syntax", "steps")).select { |st| st["run"].to_s.include?("scripts/ci-lint-workflow-shell.rb") }

    expect(steps.size).to eq(1)
    expect(steps.first["run"].strip).to eq("ruby scripts/ci-lint-workflow-shell.rb .gitea/workflows")
    expect(steps.first).not_to include("continue-on-error")
  end

  # The other half of the proof: the real tree is clean TODAY.
  it "passes on every workflow in this extension's .gitea/workflows" do
    out, err, status = lint(File.join(extension_root, ".gitea/workflows"))
    expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
  end
end
