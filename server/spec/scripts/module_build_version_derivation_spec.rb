# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# Versions come from release tags, never from a VERSION file. stage15.sh's
# parent clone is --depth 1, so the version is derived from the ls-remote refs
# it already fetches (exact tag => X.Y.Z; otherwise the max X.Y.Z tag with
# minor+1 and -dev.N+sha; release/X.Y.Z or hotfix/X.Y.Z => X.Y.Z-rc.N+sha) and
# N is counted by deepening the shallow clone to the tag. The release verdict
# stays "exact tag AND master tip".
#
# Like module_build_core_provenance_spec, these examples run the REAL
# marker-delimited block lifted from the shipped file with /tmp/parent*
# redirected into a sandbox.
RSpec.describe "stage15.sh build-identity version derivation" do
  ext_root = File.expand_path("../../..", __dir__)
  let(:stage15_script) { File.join(ext_root, "scripts/module-build/stage15.sh") }

  def extract_block(path, name)
    src = File.read(path)
    re = /^[ \t]*# --- BEGIN #{Regexp.escape(name)} ---[ \t]*$\n(.*?)^[ \t]*# --- END #{Regexp.escape(name)} ---[ \t]*$/m
    m = src.match(re)
    raise "no '#{name}' marker block found in #{path}" unless m

    m[1]
  end

  def git(dir, *args)
    out = IO.popen([ "git", "-C", dir, *args ], err: [ :child, :out ], &:read)
    raise "git #{args.join(' ')} failed: #{out}" unless $?.success?

    out.strip
  end

  # Builds a bare origin and runs the shipped block against a --depth 1 clone
  # of `checkout` (a branch name). `setup` receives a work tree to commit into.
  # Returns [status, parsed BUILD_INFO hash, output].
  def run_derivation(root, branch:, filter: true, break_origin: false)
    origin = File.join(root, "origin.git")
    work   = File.join(root, "work")
    system("git", "init", "-q", "--bare", "-b", "master", origin)
    git(origin, "config", "uploadpack.allowFilter", "true") if filter
    git(origin, "config", "uploadpack.allowAnySHA1InWant", "true")
    system("git", "init", "-q", "-b", "master", work)
    git(work, "config", "user.email", "spec@example.invalid")
    git(work, "config", "user.name", "spec")
    git(work, "remote", "add", "origin", origin)
    yield work
    git(work, "push", "-q", "origin", "--all")
    git(work, "push", "-q", "origin", "--tags")

    parent = File.join(root, "parent")
    system("git", "clone", "-q", "--depth", "1", "--branch", branch, "file://#{origin}", parent,
           out: File::NULL, err: File::NULL)
    sha = git(parent, "rev-parse", "HEAD")
    git(parent, "remote", "set-url", "origin", "file://#{root}/gone.git") if break_origin

    block = extract_block(stage15_script, "build identity (BUILD_INFO.json)")
              .gsub("/tmp/parent", File.join(root, "parent"))
    harness = <<~SH
      set -euo pipefail
      core_source_sha='#{sha}'
      #{block}
    SH
    out = IO.popen({ "PATH" => ENV.fetch("PATH") }, [ "bash", "-c", harness ],
                   err: [ :child, :out ], unsetenv_others: true, &:read)
    status = $?
    info_path = File.join(root, "parent-build-info.json")
    [ status, (JSON.parse(File.read(info_path)) if File.exist?(info_path)), out, sha ]
  end

  def commit(work, msg)
    File.write(File.join(work, "f"), "#{msg}\n#{rand}")
    git(work, "add", "-A")
    git(work, "commit", "-q", "-m", msg)
    git(work, "rev-parse", "HEAD")
  end

  it "never reads a VERSION file" do
    expect(File.read(stage15_script)).not_to match(%r{/tmp/parent/VERSION})
  end

  it "reports the plain tag and release=true on an exact tag at master's tip" do
    Dir.mktmpdir("s15v") do |root|
      status, info, out, sha = run_derivation(root, branch: "master") do |w|
        commit(w, "c1")
        git(w, "tag", "0.2.0")
      end
      expect(status).to be_success, out
      expect(info).to include("version" => "0.2.0", "tag" => "0.2.0", "release" => true, "sha" => sha)
    end
  end

  it "guesses the next minor with -dev.N+sha past the latest tag on develop" do
    Dir.mktmpdir("s15v") do |root|
      status, info, out, sha = run_derivation(root, branch: "develop") do |w|
        commit(w, "c1")
        git(w, "tag", "0.1.0")
        commit(w, "c2")
        git(w, "tag", "0.2.0")
        git(w, "checkout", "-q", "-b", "develop")
        commit(w, "c3")
        commit(w, "c4")
      end
      expect(status).to be_success, out
      expect(info["version"]).to eq("0.3.0-dev.2+#{sha[0, 7]}")
      expect(info).to include("release" => false, "tag" => nil, "branch" => "develop")
    end
  end

  it "still derives N when the remote refuses filtered fetches" do
    Dir.mktmpdir("s15v") do |root|
      status, info, out, sha = run_derivation(root, branch: "develop", filter: false) do |w|
        commit(w, "c1")
        git(w, "tag", "0.2.0")
        git(w, "checkout", "-q", "-b", "develop")
        commit(w, "c2")
      end
      expect(status).to be_success, out
      expect(info["version"]).to eq("0.3.0-dev.1+#{sha[0, 7]}")
    end
  end

  it "is X.Y.Z-rc.N+sha on release/X.Y.Z" do
    Dir.mktmpdir("s15v") do |root|
      status, info, out, sha = run_derivation(root, branch: "release/0.3.0") do |w|
        commit(w, "c1")
        git(w, "tag", "0.2.0")
        git(w, "checkout", "-q", "-b", "release/0.3.0")
        commit(w, "c2")
      end
      expect(status).to be_success, out
      expect(info["version"]).to eq("0.3.0-rc.1+#{sha[0, 7]}")
      expect(info["release"]).to be(false)
    end
  end

  it "is 0.0.0-dev.0+sha when no tags exist" do
    Dir.mktmpdir("s15v") do |root|
      status, info, out, sha = run_derivation(root, branch: "master") { |w| commit(w, "c1") }
      expect(status).to be_success, out
      expect(info["version"]).to eq("0.0.0-dev.0+#{sha[0, 7]}")
      expect(info["release"]).to be(false)
    end
  end

  it "keeps release=false for an exact tag that is not master's tip" do
    Dir.mktmpdir("s15v") do |root|
      status, info, out, = run_derivation(root, branch: "develop") do |w|
        commit(w, "c1")
        git(w, "checkout", "-q", "-b", "develop")
        commit(w, "c2")
        git(w, "tag", "0.2.0")
        git(w, "checkout", "-q", "master")
      end
      expect(status).to be_success, out
      expect(info).to include("version" => "0.2.0", "tag" => "0.2.0", "release" => false)
    end
  end

  it "fails the build loudly when ls-remote cannot reach the remote (never stamps 0.0.0-dev)" do
    Dir.mktmpdir("s15v") do |root|
      status, info, out, = run_derivation(root, branch: "master", break_origin: true) do |w|
        commit(w, "c1")
        git(w, "tag", "0.2.0")
      end
      expect(status).not_to be_success
      expect(out).to match(/FATAL.*ls-remote/i)
      expect(info).to be_nil
    end
  end

  describe "agent stamp" do
    let(:src) { File.read(stage15_script) }

    it "keeps the date-sha12 stamp for every build (SmbRotationPreflight::STAMPED_VERSION)" do
      expect(src).not_to match(/agent_version_str="\$build_version"/)
      expect(src).to match(/agent_version_str="\$\{agent_build_date%T\*\}-\$\{agent_source_sha:0:12\}"/)
    end

    it "carries the platform release in a separate field on both binaries" do
      expect(src.scan("-X main.PlatformVersion=${build_version:-}").size).to eq(2)
    end
  end
end
