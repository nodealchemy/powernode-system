# frozen_string_literal: true

require "spec_helper"
require "open3"

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
# bundle command: it sets the SAME env before exec'ing, so an operator
# never has a reason to invoke bundler any other way against this tree.
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

  it "sets the SAME env rails-setup.sh's re-lock section and rails-start.sh both resolve through" do
    expect(script).to match(/export POWERNODE_DEPLOYED=1/)
    expect(script).to match(/export BUNDLE_GEMFILE="\$RAILS_DIR\/Gemfile"/)
    expect(script).to match(/export BUNDLE_APP_CONFIG="\$STATE_DIR\/\.bundle"/)
  end

  it "derives STATE_DIR the same way rails-setup.sh and rails-start.sh do (mountpoint -q /persist)" do
    expect(script).to match(/if mountpoint -q \/persist 2>\/dev\/null; then\s*\n\s*STATE_DIR=\/persist\/powernode-rails\s*\n\s*else\s*\n\s*STATE_DIR=\/var\/lib\/powernode-rails\s*\n\s*fi/)
  end

  it "execs bundle exec with the caller's own arguments, not a fixed command" do
    expect(script).to match(/exec \/usr\/local\/bin\/bundle exec "\$@"/)
  end

  it "cds into RAILS_DIR before exec'ing, so Gemfile discovery doesn't depend on the caller's own cwd" do
    cd_idx   = script.index('cd "$RAILS_DIR"')
    exec_idx = script.index("exec /usr/local/bin/bundle exec")
    expect(cd_idx).not_to be_nil
    expect(exec_idx).not_to be_nil
    expect(cd_idx).to be < exec_idx
  end
end
