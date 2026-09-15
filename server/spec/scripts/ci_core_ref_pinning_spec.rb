# frozen_string_literal: true

require "spec_helper"
require "yaml"
require "open3"
require "tmpdir"
require "securerandom"

# IMP-ddacfe8bde28: every job that mounts this extension into the parent
# platform checked the parent out with no `ref:`, which means "the parent's
# default branch, as of whenever this job happened to start". The verdict of a
# run therefore depended on push order across two repositories — a master push
# was tested against core develop, a feature branch against whatever develop
# held that minute, and two jobs of the SAME run could see different core
# commits. One job now resolves the core commit once, and every parent checkout
# pins to it.
RSpec.describe "ci.yaml core checkout pinning" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:workflow_yaml)  { YAML.safe_load(File.read(File.join(extension_root, ".gitea", "workflows", "ci.yaml")), aliases: true) }
  let(:jobs)           { workflow_yaml.fetch("jobs") }
  let(:resolver)       { "core-ref" }
  let(:pinned_sha)     { "${{ needs.core-ref.outputs.sha }}" }
  let(:script)         { File.join(extension_root, "scripts", "ci-resolve-core-ref.sh") }

  def parent_checkouts
    jobs.flat_map do |name, job|
      Array(job["steps"]).each_with_index.filter_map do |step, index|
        next unless step.dig("with", "repository") == "powernode/powernode-platform"

        [ name, job, step, index ]
      end
    end
  end

  describe "the workflow" do
    it "finds the parent checkouts, so the guards below cannot pass vacuously" do
      expect(parent_checkouts.map(&:first).uniq.length).to be >= 7
    end

    it "pins every parent checkout to the resolved core commit" do
      unpinned = parent_checkouts.reject { |_, _, step, _| step.dig("with", "ref") == pinned_sha }

      expect(unpinned.map(&:first)).to be_empty,
        "these jobs check the parent out at its default branch HEAD, whatever it holds when " \
        "the job starts: #{unpinned.map(&:first).join(', ')}"
    end

    it "makes every job with a parent checkout need the resolver" do
      missing = parent_checkouts.map { |name, job, _, _| [ name, Array(job["needs"]) ] }
                                .reject { |_, needs| needs.include?(resolver) }

      expect(missing.map(&:first)).to be_empty,
        "needs.#{resolver}.outputs is empty in a job that does not need #{resolver}, and an " \
        "empty ref silently checks out the default branch: #{missing.map(&:first).join(', ')}"
    end

    # provider-specs and worker-specs run `if: always()`, so a failed resolver
    # does not skip them — and an empty `ref:` is not an error to actions/checkout,
    # it is the default branch. Each job must refuse that itself.
    it "refuses an unresolved core commit before each parent checkout" do
      unguarded = parent_checkouts.reject do |_, job, _, index|
        job["steps"].first(index).any? do |step|
          step.dig("env", "CORE_SHA") == pinned_sha && step["run"].to_s.include?('[ -n "$CORE_SHA" ]')
        end
      end

      expect(unguarded.map(&:first)).to be_empty,
        "no empty-CORE_SHA refusal precedes the parent checkout in: #{unguarded.map(&:first).join(', ')}"
    end

    it "resolves the core commit once, from this run's own branch name" do
      job = jobs.fetch(resolver)
      step = job.fetch("steps").find { |s| s["id"] == "resolve" }

      expect(step).not_to be_nil
      expect(job.dig("outputs", "sha")).to eq("${{ steps.resolve.outputs.sha }}")
      expect(step.dig("env", "WANTED")).to eq("${{ github.head_ref || github.ref_name }}")
      expect(step["run"]).to include("scripts/ci-resolve-core-ref.sh")
      expect(step["run"]).to include("GITHUB_OUTPUT")
    end
  end

  describe "scripts/ci-resolve-core-ref.sh" do
    around do |example|
      Dir.mktmpdir("core-ref") do |dir|
        @dir = dir
        example.run
      end
    end

    # Inherited GIT_DIR / GIT_INDEX_FILE (a hook, some worktree shells) would
    # point every git call below at the caller's own checkout.
    def isolated_git_env
      %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS].to_h { |k| [ k, nil ] }
    end

    def git(*args, chdir: @dir)
      out, status = Open3.capture2e(isolated_git_env, "git", "-c", "user.name=ci", "-c", "user.email=ci@example.invalid",
                                    "-c", "commit.gpgsign=false", *args, chdir: chdir)
      raise "git #{args.join(' ')}: #{out}" unless status.success?

      out.strip
    end

    # A bare "core" whose default branch is develop, plus a feature branch.
    let!(:remote) do
      bare = File.join(@dir, "core.git")
      work = File.join(@dir, "work")
      git("init", "--bare", "-b", "develop", bare)
      git("init", "-b", "develop", work)
      git("commit", "--allow-empty", "-m", "develop", chdir: work)
      git("push", bare, "develop", chdir: work)
      git("checkout", "-b", "feature/x", chdir: work)
      git("commit", "--allow-empty", "-m", "feature", chdir: work)
      git("push", bare, "feature/x", chdir: work)
      bare
    end

    let(:develop_sha) { git("rev-parse", "develop", chdir: remote) }
    let(:feature_sha) { git("rev-parse", "feature/x", chdir: remote) }

    def resolve(url, wanted, token: nil)
      out, err, status = Open3.capture3(isolated_git_env.merge("CORE_READ_TOKEN" => token), "bash", script, url, wanted)
      [ out.lines.map(&:strip).reject(&:empty?).to_h { |l| l.split("=", 2) }, err, status, out ]
    end

    it "prefers the core branch named like this run's branch" do
      fields, err, status = resolve(remote, "feature/x")

      expect(status).to be_success, err
      expect(fields).to eq("ref" => "feature/x", "sha" => feature_sha, "source" => "same-name")
    end

    it "falls back to the core default branch when no such branch exists" do
      fields, err, status = resolve(remote, "ci-isolation/probe")

      expect(status).to be_success, err
      expect(fields).to eq("ref" => "develop", "sha" => develop_sha, "source" => "default")
    end

    it "falls back to the default branch when no branch name is given" do
      fields, _, status = resolve(remote, "")

      expect(status).to be_success
      expect(fields["sha"]).to eq(develop_sha)
    end

    # The caller appends stdout to $GITHUB_OUTPUT verbatim, so anything else
    # printed there — a workflow command, a credential — becomes a run output.
    it "prints only the three output fields when a token is configured, and never the token" do
      token = "tok-#{SecureRandom.hex(8)}"
      fields, err, status, out = resolve(remote, "feature/x", token: token)

      expect(status).to be_success, err
      expect(out.lines.map { |l| l.split("=", 2).first }).to eq(%w[ref sha source])
      expect(fields["sha"]).to eq(feature_sha)
      expect(out + err).not_to include(token)
    end

    # ls-remote patterns match on trailing path components, so a bare pattern
    # of "x" would select refs/heads/feature/x.
    it "matches the branch name exactly, not as a path suffix" do
      fields, _, status = resolve(remote, "x")

      expect(status).to be_success
      expect(fields).to include("ref" => "develop", "source" => "default")
    end

    # Both lookups: the same-name one, and the default-branch one it falls to.
    [ "develop", "" ].each do |wanted|
      it "fails, printing no commit, when the core remote cannot be read (wanted #{wanted.inspect})" do
        fields, _, status = resolve(File.join(@dir, "absent.git"), wanted)

        expect(status).not_to be_success
        expect(fields).not_to have_key("sha")
      end
    end
  end
end
