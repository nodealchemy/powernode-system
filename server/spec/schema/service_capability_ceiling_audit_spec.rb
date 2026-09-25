# frozen_string_literal: true

require "rails_helper"
require "yaml"

# IMP-e75df089523d — pins the four decisions this audit made, so a future
# edit that reintroduces (or removes) a service-level `capabilities:` line
# on one of these modules is caught here rather than rediscovered the hard
# way once the per-service resolver (IMP-caef5c00d63f) ships.
#
# Under the agreed design, module security.capabilities is a CEILING;
# ABSENT service-level capabilities means "inherit the whole ceiling";
# explicit `capabilities: []` means "grant this unit nothing". These four
# modules are the ones where that distinction is NOT boilerplate — their
# module ceiling is non-empty, so which shape a service declares changes
# its real, effective privilege the moment the resolver ships.
#
# LOCALS, not constants, in each example group body: a constant assigned
# there lands at Object top-level and a same-named constant in another spec
# file can clobber it (see spec/lib/tasks/mcp_tool_catalog_extension_tools_
# spec.rb's comment on the same rule).
RSpec.describe "service-level capabilities audit (IMP-e75df089523d)" do
  extension_root = File.expand_path("../../..", __dir__)

  load_manifest = lambda do |module_name|
    YAML.safe_load(File.read(File.join(extension_root, "modules", module_name, "manifest.yaml")))
  end

  service_in = lambda do |manifest, service_name|
    Array(manifest["services"]).find { |s| s["name"] == service_name }
  end

  # postgres-primary, redis, vault: the ONLY process each of these units
  # ever runs is a single root-prep-then-privilege-drop script (postgres-
  # start.sh / redis-start.sh / vault-start.sh) — there is no separate
  # setup unit the way powernode-hub-backend splits rails-setup from
  # rails. The prep phase genuinely needs the module's declared ceiling,
  # so the service must INHERIT it (no capabilities key at all), not
  # declare `[]`. A `[]` here would strip the prep phase's caps the
  # moment the resolver ships and reproduce the rails-setup EPERM outage.
  #
  # Each entry also names the exact drop command its start script must
  # still end in — the load-bearing fact "inherit is correct" depends
  # on, not just today's key shape. Reviewer finding: an EARLIER version
  # of this spec asserted only that the service-level key is absent; it
  # never asserted the module ceiling itself is non-empty, so deleting a
  # module's `security.capabilities` block entirely would keep every
  # example here green while silently turning "inherit the ceiling" into
  # "inherit nothing" — exactly the outcome this spec exists to prevent.
  # Both gaps are closed below.
  [
    [ "postgres-primary", "postgres", "usr/local/bin/postgres-start.sh", /exec runuser -u postgres --/ ],
    [ "redis", "redis", "usr/local/bin/redis-start.sh", /exec runuser -u redis --/ ],
    [ "vault", "vault", "usr/local/bin/vault-start.sh", /exec setpriv --reuid="\$RUN_USER"/ ]
  ].each do |module_name, service_name, script_relpath, exec_pattern|
    it "#{module_name}/#{service_name} inherits the module ceiling (no capabilities key — its root-prep script needs it)" do
      manifest = load_manifest.call(module_name)
      service  = service_in.call(manifest, service_name)

      expect(service).not_to be_nil, "#{service_name} missing from #{module_name}'s services"
      expect(service.key?("capabilities")).to be(false),
        "#{module_name}/#{service_name} declares a capabilities key — this service's start script does its " \
        "root-prep (chown/chmod/privilege-drop) in the SAME unit, which needs the module's full ceiling; an " \
        "explicit `[]` here strips that prep the moment the per-service resolver reads this field"
    end

    it "#{module_name}'s module ceiling is still non-empty — the whole premise 'inherit' rests on" do
      ceiling = Array(load_manifest.call(module_name).dig("security", "capabilities"))
      expect(ceiling).not_to be_empty,
        "#{module_name}'s security.capabilities ceiling is empty — 'inherit the ceiling' now means 'inherit " \
        "nothing', silently reversing this audit's decision without touching the service-level key at all"
    end

    it "#{module_name}'s start script still ends by dropping privilege via #{exec_pattern.inspect} — the mechanism this decision depends on" do
      script = File.read(File.join(extension_root, "modules", module_name, "rootfs", script_relpath))
      expect(script).to match(exec_pattern),
        "#{module_name}'s start script no longer matches the root-prep-then-drop shape this audit's " \
        "'inherit the ceiling' decision assumed — re-verify the capability decision if this script was restructured"
    end
  end

  # vault specifically: its daemon does not merely need the ceiling for a
  # PREP phase like postgres/redis — vault-start.sh's own header comment
  # and its `setpriv --ambient-caps=+ipc_lock` command line establish that
  # CAP_IPC_LOCK is deliberately carried into the RUNNING vault process
  # (mlockall() is fatal without it). Pinning that the ceiling still
  # contains it, since vault's whole "inherit the ceiling" answer depends
  # on the ceiling actually carrying this capability.
  it "vault's module ceiling includes CAP_IPC_LOCK — the one capability vault's daemon needs at runtime, not just at prep" do
    ceiling = Array(load_manifest.call("vault").dig("security", "capabilities"))
    expect(ceiling).to include("CAP_IPC_LOCK")
  end

  # postgres-replica: structurally different from the three above — its
  # start_command execs the bare postgres binary directly as `user:
  # postgres` at the systemd-unit level. No wrapper script, no root
  # phase, no privilege drop anywhere in this unit's own lifecycle, so
  # `[]` is this unit's genuine, confirmed requirement — kept explicit,
  # not deleted.
  it "postgres-replica/pg-replica keeps an explicit [] — its unit runs directly as user: postgres, no root phase exists to need the ceiling" do
    manifest = load_manifest.call("postgres-replica")
    service  = service_in.call(manifest, "pg-replica")

    expect(service).not_to be_nil, "pg-replica missing from postgres-replica's services"
    expect(service["user"]).to eq("postgres"),
      "this spec's oracle for '[] is correct here' depends on the unit running directly as postgres, " \
      "with no root/privilege-drop phase — re-verify this decision if that ever changes"
    expect(service.key?("capabilities")).to be(true)
    expect(service["capabilities"]).to eq([])
  end

  # IMP-caef5c00d63f sweep: powernode-hub-worker's sidekiq and worker-web
  # both run as root and read hub-backend's STATE_DIR under the module's
  # CAP_DAC_READ_SEARCH ceiling (added on develop in the 09-21 outage fix).
  # They declared a boilerplate `capabilities: []`, which the per-service
  # resolver reads as ZERO — they would lose that read the moment it ships.
  # They must INHERIT the ceiling: no service-level key at all.
  %w[sidekiq worker-web].each do |service_name|
    it "powernode-hub-worker/#{service_name} inherits the module ceiling (no capabilities key)" do
      service = service_in.call(load_manifest.call("powernode-hub-worker"), service_name)

      expect(service).not_to be_nil, "#{service_name} missing from powernode-hub-worker's services"
      expect(service.key?("capabilities")).to be(false),
        "#{service_name} declares a service-level capabilities key; [] resolves to ZERO under the " \
        "per-service resolver and strips the module's CAP_DAC_READ_SEARCH"
    end
  end
end
