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

  it "resolves BUNDLE_* the same way rails-start.sh does at runtime, plus HOME and BOOTSNAP_CACHE_DIR (review round)" do
    expect(script).to match(/export BUNDLE_GEMFILE="\$RAILS_DIR\/Gemfile"/)
    expect(script).to match(/export BUNDLE_PATH="\$STATE_DIR\/vendor\/bundle"/)
    expect(script).to match(/export BUNDLE_APP_CONFIG="\$STATE_DIR\/\.bundle"/)
    expect(script).to match(/export HOME="\$STATE_DIR"/)
    expect(script).to match(/export BOOTSNAP_CACHE_DIR="\$STATE_DIR\/bootsnap"/)
  end

  it "unsets inherited caller env that could leak into or override the resolution above (review round)" do
    expect(script).to match(/unset RUBYOPT GEM_HOME GEM_PATH GEM_ROOT/)
    expect(script).to match(/unset BUNDLE_WITHOUT BUNDLE_FROZEN BUNDLE_DEPLOYMENT BUNDLE_BIN/)
  end

  describe "sources $SECRETS_FILE only AFTER the privilege drop (second review round, MEDIUM)" do
    it "sources it directly ONLY in the already-RAILS_USER branch -- exactly once, textually" do
      # `. "$1"` (inside the runuser payload, sourcing the PLACEHOLDER
      # argument) is a separate, deliberately different literal from
      # `. "$SECRETS_FILE"` (sourcing the real path directly) -- this
      # counts only the latter. More than one occurrence would mean root
      # is sourcing rails-writable state directly somewhere outside the
      # already-dropped else branch.
      direct_source_count = script.scan(/^\s*\. "\$SECRETS_FILE"$/).size
      expect(direct_source_count).to eq(1),
        "expected exactly one direct `. \"$SECRETS_FILE\"` (the already-RAILS_USER branch), found #{direct_source_count}"
    end

    it "the identity decision and every hardcoded/manifest export happen BEFORE either branch touches $SECRETS_FILE" do
      # Search from AFTER the shebang/header comment block (set -euo
      # pipefail is the first real line of code) -- the header's own
      # prose quotes `. "$SECRETS_FILE"` while describing what an
      # EARLIER revision did wrong, and a plain `.index` would find that
      # mention first, not the real code.
      code_start         = script.index("set -euo pipefail")
      identity_idx       = script.index('caller_user="$(id -un)"', code_start)
      hardcoded_env_idx  = script.index("export RAILS_ENV=production", code_start)
      runuser_idx        = script.index("exec runuser", code_start)
      direct_source_idx  = script.index('. "$SECRETS_FILE"', code_start)
      expect([ code_start, identity_idx, hardcoded_env_idx, runuser_idx, direct_source_idx ]).to all(be_a(Integer))
      expect(identity_idx).to be < hardcoded_env_idx
      expect(hardcoded_env_idx).to be < runuser_idx
      expect(hardcoded_env_idx).to be < direct_source_idx
    end

    it "sources it INSIDE the runuser payload via the placeholder arg, not the literal path, when a drop is needed" do
      expect(script).to match(/exec runuser -u "\$RAILS_USER" -p -- bash -c '/)
      payload = script[/exec runuser -u "\$RAILS_USER" -p -- bash -c '(.*?)' _ "\$SECRETS_FILE" "\$@"/m, 1]
      expect(payload).not_to be_nil
      expect(payload).to match(/set -a/)
      expect(payload).to match(/\.\s+"\$1"/)
      expect(payload).to match(/set \+a/)
      expect(payload).to match(/shift/)
      expect(payload).to match(/exec \/usr\/local\/bin\/bundle exec "\$@"/)
    end
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

    it "execs via `runuser -u \"$RAILS_USER\" -p` (environment preserved) when a drop is needed, not a bare bundle exec" do
      expect(script).to match(/exec runuser -u "\$RAILS_USER" -p -- bash -c '/)
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

  # Genuinely RUNS the real script (with RAILS_DIR/STATE_DIR substituted
  # to fixtures, and `id`/`runuser`/bundle stubbed via PATH) end-to-end,
  # proving the second-review-round MEDIUM fix by observing where a
  # SIDE EFFECT happens, not by reading the source for the right shape.
  # The fixture SECRETS_FILE is itself executable shell (exactly what
  # sourcing it means) that writes a DIFFERENT marker depending on
  # whether a "privilege already dropped" marker exists yet -- the stub
  # `runuser` writes that marker before running its payload, the same
  # order a real drop would impose. If root ever sourced the real
  # secrets file directly, the "sourced as root" marker would appear
  # instead.
  describe "does not source $SECRETS_FILE as root (second review round, MEDIUM), actually run" do
    let(:runnable_body) do
      script[/SECRETS_FILE="\$STATE_DIR\/backend-default\.conf"\n.*/m]
    end

    it "the extraction itself found the real runnable body (sanity-checks the extraction, not the script)" do
      expect(runnable_body).not_to be_nil
      expect(runnable_body).to include("exec runuser")
    end

    it "sources the secrets file's shell ONLY after the stub runuser's own drop marker exists" do
      Dir.mktmpdir do |dir|
        rails_dir = File.join(dir, "server")
        stub_dir = File.join(dir, "stub-bin")
        FileUtils.mkdir_p(rails_dir)
        FileUtils.mkdir_p(stub_dir)

        dropped_marker         = File.join(dir, "dropped-marker")
        sourced_as_root_marker = File.join(dir, "sourced-as-root")
        sourced_dropped_marker = File.join(dir, "sourced-dropped")

        secrets_file = File.join(dir, "backend-default.conf")
        File.write(secrets_file, <<~CONF)
          SECRET_KEY_BASE=fake
          if [ -f #{dropped_marker} ]; then
            touch #{sourced_dropped_marker}
          else
            touch #{sourced_as_root_marker}
          fi
        CONF

        File.write(File.join(stub_dir, "id"), <<~STUB)
          #!/bin/bash
          if [ "$1" = "-un" ]; then echo "root"; fi
        STUB
        # Simulates the drop: touches the marker BEFORE running the real
        # payload, the same order a genuine privilege drop imposes.
        File.write(File.join(stub_dir, "runuser"), <<~STUB)
          #!/bin/bash
          touch #{dropped_marker}
          shift 4
          exec "$@"
        STUB
        File.write(File.join(stub_dir, "bundle"), <<~STUB)
          #!/bin/bash
          exit 0
        STUB
        %w[id runuser bundle].each { |f| FileUtils.chmod(0o755, File.join(stub_dir, f)) }

        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER=powernode-rails
          RAILS_DIR=#{rails_dir}
          STATE_DIR=#{dir}
          #{runnable_body.gsub('/usr/local/bin/bundle', "#{stub_dir}/bundle")}
        BASH
        env = { "PATH" => "#{stub_dir}:#{ENV.fetch("PATH", nil)}" }
        _out, err, status = Open3.capture3(env, "bash", "-c", snippet, "--", "rails", "console")

        expect(status.success?).to be(true), "script aborted: #{err}"
        expect(File.exist?(sourced_as_root_marker)).to be(false),
          "the secrets file's shell ran BEFORE the drop marker existed -- root sourced rails-writable state directly"
        expect(File.exist?(sourced_dropped_marker)).to be(true),
          "the secrets file's shell never ran at all inside the dropped context"
      end
    end
  end
end
