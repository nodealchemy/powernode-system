# frozen_string_literal: true

require "rails_helper"

# IMP-c043800b3f21 — the ACTUATION half.
#
# Permissions::RoleGrantReconciler closing the catalog->DB gap is worth nothing
# unless something on an installed deployment RUNS it. `db:seed` is first-boot
# only (rails-start.sh gates it behind the durable .db-initialized marker) and
# every other caller of Role.sync_from_config! is first-install-only too, so the
# per-boot hook below IS the mechanism. A reconciler nobody invokes is the same
# inert state this task exists to remove.
#
# `type: :lib` is explicit and load-bearing: rails_helper enables
# infer_spec_type_from_file_location!, which maps spec/system/** to RSpec's
# BROWSER system tests and would raise Gem::LoadError (capybara is not in the
# Gemfile) at LOAD time — aborting the whole run with "0 examples" and a
# non-zero exit that reads as green to anything checking a piped exit code.
# See db_init_invariant_spec.rb, which learned this the hard way.
RSpec.describe "hub-backend role-grant reconcile wiring (IMP-c043800b3f21)", type: :lib do
  module_bin = File.expand_path(
    "../../../modules/powernode-hub-backend/rootfs/usr/local/bin", __dir__
  )
  rails_start = File.join(module_bin, "rails-start.sh")
  runner      = File.join(module_bin, "role-grants-reconcile.rb")

  it "ships the boot runner script" do
    expect(File.exist?(runner)).to be(true)
  end

  context "when the boot script is present" do
    let(:body) { File.read(rails_start) }

    # Comment lines are rejected everywhere in this file: a whole-file regex is
    # satisfied by the prose ABOUT the invocation, and by the invocation itself
    # commented out.
    let(:invocations) do
      body.lines.each_with_index
          .reject { |line, _i| line.match?(/\A\s*#/) }
          .select { |line, _i| line.match?(%r{rails runner /usr/local/bin/role-grants-reconcile\.rb}) }
    end

    it "invokes the role-grant reconcile runner" do
      expect(invocations.size).to eq(1)
    end

    it "invokes it on EVERY boot, not inside the first-boot branch" do
      # `touch "$MIGRATED_MARKER"` is the last line of the first-boot-only
      # branch. An invocation above it runs once per install and leaves this
      # task's whole finding in place — which a bare "is the line present?"
      # check would report as wired. That is the regression this guards.
      marker_line = body.lines.index { |line| line.match?(/\A\s*touch "\$MIGRATED_MARKER"/) }
      expect(marker_line).not_to be_nil, "first-boot marker write not found — re-derive this guard"

      _line, invocation_index = invocations.first
      expect(invocation_index).to be > marker_line
    end

    it "keeps the reconcile advisory so a reconciler bug cannot brick a sole control plane" do
      line, _i = invocations.first
      expect(line).to include("|| true")
    end

    it "never runs a DESTRUCTIVE role sync at boot" do
      # Role#sync_permissions! is full destructive reconciliation against the
      # catalog LOADED IN THIS PROCESS, and instances are module-composed — a
      # boot that did not compose an extension would delete every grant for that
      # extension's permissions. The reconciler is absence-only precisely so
      # this line never needs to exist.
      # Comment lines are excluded deliberately: the block above this hook
      # EXPLAINS why the destructive sync is not used, and a naive grep matches
      # its own rationale (db_init_invariant_spec.rb hit the same shape).
      offending = body.lines.reject { |line| line.match?(/\A\s*#/) }.grep(/sync_from_config/)
      expect(offending).to be_empty,
        "rails-start.sh must not run a destructive role sync — found: #{offending.inspect}"
    end
  end

  context "when the runner script is present" do
    let(:body) { File.read(runner) }

    it "prints a summary line on the reconcile path, including the created=0 steady state" do
      # Not unconditional: the `unless defined?(...)` skip path prints its own
      # distinct line instead. Both are tagged, so the journal always says which
      # of the two happened — that is the property, not "one fixed line".
      expect(body).to match(/\[role-grants-reconcile\] created_grants=/)
      expect(body).to match(/\[role-grants-reconcile\].*skipping/)
    end

    it "never raises out of the runner" do
      expect(body).to match(/rescue StandardError/)
    end
  end
end
