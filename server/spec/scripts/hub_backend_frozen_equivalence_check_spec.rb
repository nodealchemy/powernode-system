# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

# IMP-094d900f9093 part 2, review round R6: a REAL hub-backend build
# failed inside stage15.sh's own S5 frozen-equivalence check --
# `definition.specs` MATERIALIZES every locked gem against whatever is
# actually installed under the active BUNDLE_PATH, and this check
# deliberately points BUNDLE_APP_CONFIG at an EMPTY scratch install
# location (never rails-writable state) -- so materialization failed
# for literally every locked gem (Bundler::GemNotFound: "Could not find
# rails-8.1.3, pg-1.6.3-x86_64-linux, ..."), even though the lock and
# vendor/cache were both genuinely fine (the PATH-presence assertion
# right before this check had already passed).
#
# WHY THE PRIOR REVIEW ROUND DID NOT CATCH THIS: R4's own verification
# of this check was never committed as a spec at all -- an ad hoc
# `ruby -e` run in a sandbox that happened to have OTHER, unrelated
# gems genuinely installed system-wide. `definition.specs` silently
# materialized against THOSE (Bundler falls back to the ambient system
# Gem.path when BUNDLE_PATH is unset) instead of failing, which masked
# the defect entirely -- it only surfaces in an environment with truly
# nothing pre-installed, which is exactly the real module-forge
# builder's own shape, and exactly what this spec now reproduces
# deliberately, not by accident.
RSpec.describe "stage15.sh hub-backend frozen-equivalence check (IMP-094d900f9093 part 2, review round R6)" do
  ext_root = File.expand_path("../../..", __dir__)
  let(:stage15_script) { File.join(ext_root, "scripts/module-build/stage15.sh") }

  # Lifts the shipped text between `# --- BEGIN <name> ---` / `# --- END
  # ... ---` so these examples execute the real bytes rather than a
  # restated copy (same technique as module_build_core_provenance_spec.rb).
  # A missing marker fails loudly instead of silently testing nothing.
  def extract_block(path, name)
    src = File.read(path)
    re = /^[ \t]*# --- BEGIN #{Regexp.escape(name)} ---[ \t]*$\n(.*?)^[ \t]*# --- END #{Regexp.escape(name)} ---[ \t]*$/m
    m = src.match(re)
    raise "no '#{name}' marker block found in #{path}" unless m

    m[1]
  end

  let(:check_block) { extract_block(stage15_script, "hub-backend frozen-equivalence check") }
  # The block's own comments document the OLD, buggy `definition.specs`
  # shape by name (so a future reader knows why NOT to reintroduce it) --
  # strip comment-only lines before asserting on what the CODE does, same
  # technique rails_relock_gemfile_spec.rb's own code_lines uses.
  let(:check_code_lines) do
    check_block.lines.reject { |line| line.strip.start_with?("#") }.join
  end

  it "the extraction itself found the real block (sanity-checks the extraction, not the script)" do
    expect(check_block).not_to be_nil
    expect(check_code_lines).to include("definition.locked_gems.specs"),
      "review round R6: must use the parsed-lockfile API (no materialization), not definition.specs"
    expect(check_code_lines).not_to match(/\bdefinition\.specs\b/),
      "definition.specs materializes against installed content -- the exact R6 regression -- must not reappear in the CODE (the comments above may still mention it by name, to document why not)"
    expect(check_code_lines).to include("ensure_equivalent_gemfile_and_lockfile")
  end

  # Runs the extracted block exactly the way stage15.sh does: cwd is the
  # app dir, POWERNODE_DEPLOYED=1, BUNDLE_FROZEN=1, BUNDLE_GEMFILE points
  # at the real Gemfile, and BUNDLE_APP_CONFIG points at a FRESH, EMPTY
  # scratch dir with no BUNDLE_PATH set at all -- the exact shape that
  # broke `definition.specs` (nothing "installed" anywhere it could see).
  # `unsetenv_others: true` + a minimal clean PATH: this suite itself
  # runs under `bundle exec rspec`, which pollutes GEM_HOME/GEM_PATH/
  # RUBYOPT for every child process (same reasoning as
  # rails_relock_gemfile_spec.rb's own S4 test) -- without stripping
  # that, this process's own worktree gems would be ambiently visible
  # and mask the exact defect this reproduces, the same way R4's own
  # unstripped sandbox did.
  def run_check(app_dir:)
    scratch_config = Dir.mktmpdir
    clean_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    Open3.capture3(
      { "PATH" => clean_path,
        "POWERNODE_DEPLOYED" => "1",
        "BUNDLE_FROZEN" => "1",
        "BUNDLE_GEMFILE" => File.join(app_dir, "Gemfile"),
        "BUNDLE_APP_CONFIG" => scratch_config },
      "bash", "-c", check_block,
      chdir: app_dir,
      unsetenv_others: true
    )
  ensure
    FileUtils.remove_entry(scratch_config) if scratch_config && File.exist?(scratch_config)
  end

  # Builds a REAL Gemfile/Gemfile.lock/vendor/cache with the real
  # bundler/gem toolchain (`bundle lock` + a real `bundle cache`
  # equivalent below), not hand-written fixtures -- the same shape
  # rails_relock_gemfile_spec.rb's own S4 test uses, and for the same
  # reason (a hand-typed lock risks not matching what a real bundler
  # would ever produce, masking the very defect under test). Two small,
  # pure-Ruby, no-native-extension gems so this stays fast and needs no
  # compilation or network beyond what is already cached locally.
  def build_real_app(dir)
    clean_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    probe = <<~RUBY
      %w[rake matrix].each do |name|
        spec = Gem::Specification.find_by_name(name)
        puts [name, spec.version, File.join(Gem.dir, "cache", "\#{spec.full_name}.gem")].join(" ")
      end
    RUBY
    probe_out, probe_err, probe_status = Open3.capture3({ "PATH" => clean_path }, "ruby", "-e", probe, unsetenv_others: true)
    skip "could not resolve rake/matrix from the clean system gem path: #{probe_err}" unless probe_status.success?
    gems = probe_out.lines.map { |l| l.split(" ") }.to_h { |name, version, path| [name, { version: version, path: path }] }

    gemfile_path = File.join(dir, "Gemfile")
    FileUtils.mkdir_p(File.join(dir, "vendor/cache"))
    File.write(gemfile_path,
               "source \"https://rubygems.org\"\n" \
               "gem \"rake\", \"#{gems['rake'][:version]}\"\n" \
               "gem \"matrix\", \"#{gems['matrix'][:version]}\"\n")

    lock_out, lock_err, lock_status = Open3.capture3(
      { "PATH" => clean_path, "BUNDLE_GEMFILE" => gemfile_path },
      "bundle", "lock", "--local",
      unsetenv_others: true
    )
    skip "could not generate a real lock on this machine: #{lock_out}\n#{lock_err}" unless lock_status.success?

    gems.each_value do |g|
      skip "#{g[:path]} is not cached on this machine -- cannot run this repro" unless File.exist?(g[:path])
      FileUtils.cp(g[:path], File.join(dir, "vendor/cache", File.basename(g[:path])))
    end
    gems
  end

  it "passes on a REAL, matching Gemfile.lock + vendor/cache, with an EMPTY BUNDLE_APP_CONFIG and no BUNDLE_PATH (the exact shape that broke definition.specs)" do
    Dir.mktmpdir do |dir|
      build_real_app(dir)
      out, err, status = run_check(app_dir: dir)
      expect(status.success?).to be(true), "aborted (this is the R6 regression if it mentions Bundler::GemNotFound): #{err}"
      expect(out).to match(/frozen-equivalence OK/), "expected success, got stdout=#{out.inspect} stderr=#{err.inspect}"
    end
  end

  it "fails loud, WITHOUT materializing anything, when a cached .gem goes missing from vendor/cache (review round R6 regression guard)" do
    Dir.mktmpdir do |dir|
      gems = build_real_app(dir)
      FileUtils.rm(File.join(dir, "vendor/cache", File.basename(gems["rake"][:path])))
      out, err, status = run_check(app_dir: dir)
      expect(status.success?).to be(false), "expected the check to fail: stdout=#{out.inspect}"
      expect(err).to match(/FATAL:.*have no cached \.gem/m)
      expect(err).to match(/rake/)
      expect(err).not_to match(/Bundler::GemNotFound|could not find .* in locally installed gems/i),
        "a real Bundler::GemNotFound/materialization error means definition.specs ran again -- the exact R6 regression"
    end
  end

  it "fails loud (via ensure_equivalent_gemfile_and_lockfile) on a genuinely non-equivalent Gemfile/lock pair" do
    Dir.mktmpdir do |dir|
      build_real_app(dir)
      gemfile_path = File.join(dir, "Gemfile")
      File.write(gemfile_path, "#{File.read(gemfile_path)}gem \"hashery\"\n")
      out, err, status = run_check(app_dir: dir)
      expect(status.success?).to be(false)
      expect(err).to match(/not frozen-equivalent/)
      expect(out).not_to match(/frozen-equivalence OK/)
    end
  end
end
