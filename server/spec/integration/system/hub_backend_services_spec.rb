# frozen_string_literal: true

require "rails_helper"

# Regression guard — rails-setup.sh (the root-only prep unit,
# IMP-94977647c24c part A) needs the capabilities its own chown/chmod
# calls require, or a fresh boot dies before the rails service ever
# starts.
#
# Found 2026-09-20 on ops-hub, RESURFACED 2026-09-21: hub-backend's
# manifest declares a top-level `security: capabilities: []`. The agent's
# buildPolicy renders that ONE list into a per-unit
# CapabilityBoundingSet=/AmbientCapabilities= drop-in for EVERY service in
# the module — including rails-setup, whose entire job is unconditional
# chown/chmod under `set -e` (STATE_DIR + the two secrets files at
# :183-184, the internal CA store, the OCI blob cache dir, the traefik
# ingress dirs, the agent-PKI parent). Root without CAP_CHOWN/CAP_FOWNER/
# CAP_DAC_OVERRIDE gets EPERM on plain ext4 the moment it tries any of
# that on a filesystem it doesn't already own by uid — "root ignores Unix
# permission bits" is true only while root HOLDS those capabilities. An
# empty bounding set leaves rails-setup.service dying at its very first
# chown, and rails' `Requires=` on rails-setup (from `start_before` in the
# manifest) then CANCELS rails' own start job — the backend never starts.
#
# The only reason this has worked on ops-hub at all is a HAND-APPLIED
# /etc/systemd/system/<unit>.d/zz-operator-restore-caps.conf from the
# 2026-09-20 incident, itself commented "TEMPORARY: the agent overwrites
# drop-ins on reconcile. The durable fix is the module manifest security
# policy." That drop-in lives in /run/powernode/scratch/upper — tmpfs,
# gone on reboot. Same defect shape, same fix, as hub-worker's
# CAP_DAC_READ_SEARCH grant (see hub_worker_services_spec.rb and that
# manifest's own comment for the parallel incident) — mirrored here
# deliberately rather than invented fresh.
RSpec.describe "powernode-hub-backend module services" do
  let(:manifest_path) do
    Rails.root.join("../extensions/system/modules/powernode-hub-backend/manifest.yaml")
  end

  let(:manifest) { YAML.safe_load(File.read(manifest_path), aliases: true) }
  let(:services) { manifest.fetch("services") }

  it "validates against the real ManifestImportService schema" do
    result = System::ManifestImportService.validate_only(
      yaml: File.read(manifest_path),
      node_module: System::NodeModule.new(name: "powernode-hub-backend")
    )

    expect(result.validation_errors).to be_empty
    expect(result.ok?).to be true
  end

  it "ships both the root-only prep unit and the rails service" do
    expect(services.map { |s| s["name"] }).to contain_exactly("rails-setup", "rails")
  end

  # 2026-09-20/21, ops-hub: rails-setup.service died before rails' own
  # start job ever ran, because the module-level security policy left it
  # with an EMPTY CapabilityBoundingSet= while its whole purpose is
  # chown/chmod. The grant MUST live in the TOP-LEVEL security block, not
  # a per-service key — the agent's buildPolicy reads
  # config["security"]["capabilities"] and applies that ONE module-level
  # policy to every unit (reconcile.go: `for _, unit := range
  # mf.UnitNames()`). A per-SERVICE `capabilities:` key never reaches the
  # drop-in, so granting it there is a no-op that reads exactly like a fix.
  describe "the module security policy" do
    let(:rails_setup_script) do
      Rails.root.join(
        "../extensions/system/modules/powernode-hub-backend/rootfs/usr/local/bin/rails-setup.sh"
      )
    end
    let(:rails_setup_source) { File.read(rails_setup_script) }

    it "has a root-only prep unit whose entire job is chown/chmod, unconditionally, under set -e" do
      # The premise of the grant below. If rails-setup.sh stops doing
      # unconditional ownership work under set -e, the capability grant
      # should be re-justified or narrowed — not silently retained.
      rails_setup = services.find { |s| s["name"] == "rails-setup" }
      expect(rails_setup.dig("unit_body")).to match(/Type=oneshot/)
      expect(rails_setup_source).to match(/^set -euo pipefail$/)
      expect(rails_setup_source).to match(/^chown "\$RAILS_USER:\$RAILS_USER" "\$STATE_DIR"$/)
      expect(rails_setup_source).to match(/^chmod 700 "\$STATE_DIR"$/)
    end

    it "grants CAP_CHOWN, CAP_FOWNER and CAP_DAC_OVERRIDE at the TOP LEVEL, where the agent reads it" do
      granted = manifest.dig("security", "capabilities")
      expect(granted).to include("CAP_CHOWN")
      expect(granted).to include("CAP_FOWNER")
      expect(granted).to include("CAP_DAC_OVERRIDE")
    end

    it "grants EXACTLY that set — empirically what the live host's restore drop-in holds, not a guess — and stays unprivileged" do
      # Adding more than this without the same live `systemctl show`
      # verification would be re-introducing the "guessed, not measured"
      # failure mode this whole IMP exists to close.
      expect(manifest.dig("security", "capabilities")).to contain_exactly(
        "CAP_CHOWN", "CAP_FOWNER", "CAP_DAC_OVERRIDE"
      )
      expect(manifest.dig("security", "privileged")).to be false
    end

    it "does NOT declare the grant on the per-service capabilities key instead (that key never reaches the drop-in)" do
      rails_setup = services.find { |s| s["name"] == "rails-setup" }
      rails_service = services.find { |s| s["name"] == "rails" }
      # rails-setup has no structured `capabilities:` field at all (it's a
      # raw unit_body); rails's own per-service field must stay empty —
      # the grant belongs ONLY at the top level.
      expect(rails_setup["capabilities"]).to be_nil
      expect(rails_service["capabilities"]).to eq([])
    end
  end
end
