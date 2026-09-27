# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

# IMP-01a0e40a-c0ef — an out-of-band `bundle exec rails console`/`runner`,
# run by hand against /opt/powernode/server, resolves through
# extensions_loader_helper.rb's discover_extension_gems_by_visibility just
# like the `rails` service does — but without POWERNODE_DEPLOYED=1, that
# discovery falls back to .gitmodules-gated public visibility, and
# .gitmodules is never shipped to a deployed node. That mode finds ZERO
# extension path gems, so a bare manual bundle command rewrites
# Gemfile.lock down to none, disagreeing with what the `rails` service
# (and rails-setup.sh's own re-lock — see rails_setup_root_prep_spec.rb)
# both resolve to. This wrapper is the supported way to run a manual
# bundle command: it mirrors the SERVICE's own runtime env before
# exec'ing (review round correction — a manual `rails console` needs to
# actually RUN the app, so it needs the full service env, not the
# isolated resolve-only one rails-setup.sh's re-lock section uses; see
# both scripts' own headers), so an operator never has a reason to invoke
# bundler any other way against this tree.
RSpec.describe "powernode-rails-exec: out-of-band bundle wrapper (IMP-01a0e40a-c0ef)" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:script_path) do
    File.join(extension_root, "modules/powernode-hub-backend/rootfs/usr/local/bin/powernode-rails-exec")
  end
  let(:script) { File.read(script_path) }

  describe "script integrity" do
    it "is valid bash (bash -n)" do
      _out, err, status = Open3.capture3("bash", "-n", script_path)
      expect(status.success?).to be(true), "bash -n failed: #{err}"
    end

    it "declares #!/bin/bash as its shebang" do
      expect(script.lines.first).to eq("#!/bin/bash\n")
    end

    it "passes shellcheck, when the binary is available in this environment" do
      skip "shellcheck not installed in this environment" unless system("which shellcheck > /dev/null 2>&1")

      out, _err, status = Open3.capture3("shellcheck", "-S", "error", script_path)
      expect(status.success?).to be(true), "shellcheck -S error failed:\n#{out}"
    end

    it "is committed executable (100755), not just chmod'd on disk" do
      mode = `git -C #{extension_root} ls-files -s modules/powernode-hub-backend/rootfs/usr/local/bin/powernode-rails-exec`
        .split(" ").first
      expect(mode).to eq("100755"),
        "git-tracked mode is #{mode.inspect}, not 100755 -- a 100644 blob ships non-executable on a clean " \
        "build regardless of this checkout's own filesystem bit"
    end
  end

  it "mirrors the manifest's rails `env:` block (review round -- must be kept in sync by hand)" do
    expect(script).to match(/export RAILS_ENV=production/)
    expect(script).to match(/export DATABASE_URL="postgres:\/\/powernode@localhost:5432\/powernode_production"/)
    expect(script).to match(/export REDIS_URL="redis:\/\/localhost:6379\/0"/)
    expect(script).to match(/export POWERNODE_DEPLOYED=1/)
    expect(script).to match(/export CACHE_STORE=memory_store/)
    expect(script).to match(/export QUEUE_ADAPTER=async/)
    expect(script).to match(/export POWERNODE_CA_MODE=local/)
  end

  # Sanity-checks the hardcoded literals above against the ACTUAL manifest
  # values, not hand-copied constants -- a manifest change to the rails
  # `env:` block fails this spec until mirrored here, the same shape the
  # OCI cache dir section of rails_setup_root_prep_spec.rb already uses.
  it "the hardcoded manifest env literals actually match manifest.yaml's rails `env:` block" do
    manifest = File.read(File.join(extension_root, "modules/powernode-hub-backend/manifest.yaml"))
    rails_env_block = manifest[/name: rails\b.*?env:\n(.*?)\n\s*exposed_ports:/m, 1]
    expect(rails_env_block).not_to be_nil

    expect(rails_env_block).to match(/RAILS_ENV: production/)
    expect(rails_env_block).to match(/DATABASE_URL: "postgres:\/\/powernode@localhost:5432\/powernode_production"/)
    expect(rails_env_block).to match(/REDIS_URL: "redis:\/\/localhost:6379\/0"/)
    expect(rails_env_block).to match(/CACHE_STORE: "memory_store"/)
    expect(rails_env_block).to match(/QUEUE_ADAPTER: "async"/)
    expect(rails_env_block).to match(/POWERNODE_CA_MODE: "local"/)
  end

  it "sources backend-default.conf with set -a, the same way rails-start.sh does" do
    expect(script).to match(/^set -a$/)
    expect(script).to match(/^\. "\$SECRETS_FILE"$/)
    expect(script).to match(/^set \+a$/)
  end

  it "resolves BUNDLE_* the same way rails-start.sh does at runtime" do
    expect(script).to match(/export BUNDLE_GEMFILE="\$RAILS_DIR\/Gemfile"/)
    expect(script).to match(/export BUNDLE_PATH="\$STATE_DIR\/vendor\/bundle"/)
    expect(script).to match(/export BUNDLE_APP_CONFIG="\$STATE_DIR\/\.bundle"/)
  end

  it "derives STATE_DIR the same way rails-setup.sh and rails-start.sh do (mountpoint -q /persist)" do
    expect(script).to match(/if mountpoint -q \/persist 2>\/dev\/null; then\s*\n\s*STATE_DIR=\/persist\/powernode-rails\s*\n\s*else\s*\n\s*STATE_DIR=\/var\/lib\/powernode-rails\s*\n\s*fi/)
  end

  describe "runs as $RAILS_USER, never as root (review round, MEDIUM)" do
    it "refuses when the caller is neither root nor RAILS_USER, before touching anything privileged" do
      expect(script).to match(/must run as root.*or as \$RAILS_USER itself/)
    end

    it "refuses when runuser is unavailable and the caller isn't already RAILS_USER" do
      expect(script).to match(/command -v runuser.*>\/dev\/null 2>&1.*\n.*runuser is not available/)
    end

    it "execs via `runuser -u \"$RAILS_USER\"` with environment preserved, not a bare bundle exec, when a drop is needed" do
      expect(script).to match(/exec runuser -u "\$RAILS_USER" -p -- \/usr\/local\/bin\/bundle exec "\$@"/)
    end

    it "execs bundle directly, without runuser, only when the caller already IS RAILS_USER" do
      expect(script).to match(/needs_runuser=1/)
      expect(script).to match(/if \[ "\$caller_user" = "\$RAILS_USER" \]; then\s*\n\s*needs_runuser=0/)
    end

    it "cds into RAILS_DIR before either exec branch, so Gemfile discovery doesn't depend on the caller's own cwd" do
      cd_idx           = script.index('cd "$RAILS_DIR"')
      runuser_exec_idx = script.index("exec runuser")
      direct_exec_idx  = script.index('exec /usr/local/bin/bundle exec "$@"')
      expect(cd_idx).not_to be_nil
      expect(runuser_exec_idx).not_to be_nil
      expect(direct_exec_idx).not_to be_nil
      expect(cd_idx).to be < runuser_exec_idx
      expect(cd_idx).to be < direct_exec_idx
    end
  end

  # Genuinely EXECUTES the script's identity-branch logic (extracted
  # verbatim), not a text assertion -- confirms needs_runuser resolves
  # correctly for each caller identity shape, and that the refusal path
  # actually exits non-zero rather than falling through.
  describe "identity-branch logic, actually run" do
    let(:identity_branch) do
      script[/caller_user="\$\(id -un\)"\nneeds_runuser=1\n.*?\nfi\n/m]
    end

    it "the extraction itself found the real identity branch (sanity-checks the extraction, not the script)" do
      expect(identity_branch).not_to be_nil
      expect(identity_branch).to include("needs_runuser=0")
    end

    it "sets needs_runuser=0 when the caller already IS RAILS_USER" do
      real_user = `id -un`.strip
      snippet = <<~BASH
        set -euo pipefail
        RAILS_USER=#{real_user}
        #{identity_branch}
        echo "needs_runuser=$needs_runuser"
      BASH
      out, err, status = Open3.capture3("bash", "-c", snippet)
      expect(status.success?).to be(true), "aborted: #{err}"
      expect(out).to include("needs_runuser=0")
    end

    it "refuses when the real (non-root) caller running this spec is neither root nor RAILS_USER" do
      real_user = `id -un`.strip
      raise "this spec must not itself run as root" if real_user == "root"

      snippet = <<~BASH
        set -euo pipefail
        RAILS_USER=definitely-not-#{real_user}
        #{identity_branch}
        echo "needs_runuser=$needs_runuser"
      BASH
      out, err, status = Open3.capture3("bash", "-c", snippet)
      expect(status.success?).to be(false), "expected a refusal, got: #{out} / #{err}"
      expect(err).to include("must run as root")
    end
  end
end
