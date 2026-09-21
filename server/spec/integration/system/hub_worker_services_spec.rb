# frozen_string_literal: true

require "rails_helper"

# Regression guard — the worker HTTP API must stay in the hub-worker module.
#
# Found 2026-08-02 on ops-hub: `powernode-hub-worker` declared exactly ONE
# service (sidekiq), so the fleet-hosted control plane had no worker HTTP API
# at all — no unit file on disk, nothing on 4567 — while `/up` returned 200
# and every composed service reported running. The worker CODE shipped fine
# (file_spec covers /opt/powernode/worker/**); only the service was missing.
#
# The blast radius is quiet and wide: config.ru maps /api/v1 -> JobsController,
# which is where embeddings live, and the backend reaches it at
# Rails.application.config.worker_url (WORKER_URL, default
# http://localhost:4567). Without it the platform can still SEARCH vectors
# already at rest but cannot GENERATE a query embedding — so semantic search
# and embed-on-write fail while plain SQL lookups keep working, which reads as
# "mostly healthy" from every health check we have.
#
# It went unnoticed because the service historically ran only on the dev box as
# a hand-managed systemd unit (scripts/systemd/powernode-worker-web.sh) and so
# was never modularized. These assertions exist so it cannot silently vanish
# again.
RSpec.describe "powernode-hub-worker module services" do
  let(:manifest_path) do
    Rails.root.join("../extensions/system/modules/powernode-hub-worker/manifest.yaml")
  end

  let(:manifest) { YAML.safe_load(File.read(manifest_path), aliases: true) }
  let(:services) { manifest.fetch("services") }

  it "validates against the real ManifestImportService schema" do
    result = System::ManifestImportService.validate_only(
      yaml: File.read(manifest_path),
      node_module: System::NodeModule.new(name: "powernode-hub-worker")
    )

    expect(result.validation_errors).to be_empty
    expect(result.ok?).to be true
  end

  it "ships BOTH the sidekiq job processor and the worker HTTP API" do
    expect(services.map { |s| s["name"] }).to contain_exactly("sidekiq", "worker-web")
  end

  describe "the worker-web service" do
    let(:worker_web) { services.find { |s| s["name"] == "worker-web" } }

    it "listens on the port the backend's WorkerTransport defaults to" do
      # Rails.application.config.worker_url default is http://localhost:4567.
      expect(worker_web.dig("env", "SIDEKIQ_WEB_PORT")).to eq("4567")
      expect(worker_web["exposed_ports"]).to include(
        hash_including("port" => 4567, "protocol" => "tcp")
      )
    end

    it "binds loopback only, since the backend is co-resident" do
      expect(worker_web.dig("env", "SIDEKIQ_WEB_HOST")).to eq("127.0.0.1")
    end

    it "starts after sidekiq so the two never race on the shared bundle install" do
      # sidekiq-start.sh owns the one-time offline `bundle install` into
      # /opt/powernode/worker/vendor/bundle; two concurrent installs corrupt it.
      expect(worker_web["dependencies"]).to include(
        hash_including("service" => "sidekiq", "kind" => "start_before")
      )
    end

    it "is health-checked on the endpoint config.ru actually mounts" do
      expect(worker_web.dig("health", "endpoint")).to eq("/health")
    end

    it "has an executable launcher in the module rootfs" do
      launcher = Rails.root.join(
        "../extensions/system/modules/powernode-hub-worker/rootfs/usr/local/bin/worker-web-start.sh"
      )

      expect(File).to exist(launcher)
      expect(File.executable?(launcher)).to be true
      expect(worker_web["start_command"]).to eq("/usr/local/bin/worker-web-start.sh")
    end

    it "generates .session.key, which config.ru reads at load time" do
      # config.ru does File.read('.session.key') unconditionally, so an absent
      # file is a hard boot failure — and the secret is deliberately unshipped
      # (scripts/security-cleanup.sh scrubs it). The launcher must create it.
      launcher_body = File.read(
        Rails.root.join(
          "../extensions/system/modules/powernode-hub-worker/rootfs/usr/local/bin/worker-web-start.sh"
        )
      )

      expect(launcher_body).to include(".session.key")
    end
  end

  # 2026-09-21, ops-hub: BOTH services of this module crash-looped for ~26h
  # (NRestarts=387 each), so NO Sidekiq cron ran at all. That silently stalled
  # native module build batches too, because the only thing that readvances a
  # batch whose member finished but was never recorded is the CI runner lease
  # sweep — and that sweep ticks solely from this module's 60s cron.
  #
  # The cause is a stale assumption written into both launchers. They read
  # hub-backend's secrets at $STATE_DIR/backend-default.conf, and
  # sidekiq-start.sh asserts this is "safe TODAY: sidekiq reads [it] AS ROOT,
  # and STATE_DIR is now 0700-mode, owned by powernode-rails (not root) — root
  # ignores Unix permission bits entirely". Root only ignores those bits while
  # it holds CAP_DAC_READ_SEARCH (or CAP_DAC_OVERRIDE). The agent writes a
  # per-unit drop-in from this manifest's security policy, and `capabilities:
  # []` renders an EMPTY CapabilityBoundingSet=, so both units run as uid 0
  # with no capabilities and cannot even traverse into STATE_DIR. Observed on
  # the live host, not inferred:
  #   Uid: 0 0 0 0   CapEff: 0000000000000000
  # while rails itself was fine at Uid 71005 — it OWNS the directory and so
  # never needed the override.
  #
  # The grant MUST live in the TOP-LEVEL security block. The agent's
  # buildPolicy reads config["security"]["capabilities"] and applies that one
  # module-level policy to every unit (reconcile.go: `for _, unit := range
  # mf.UnitNames()`). The per-SERVICE `capabilities:` key never reaches the
  # drop-in, so granting it there is a no-op that reads exactly like a fix.
  describe "the module security policy" do
    let(:rootfs_bin) do
      Rails.root.join("../extensions/system/modules/powernode-hub-worker/rootfs/usr/local/bin")
    end

    # Derived from the launchers themselves rather than hardcoded, so that a
    # service which STOPS reading the cross-module secrets file drops out of
    # the premise instead of quietly keeping a grant it no longer needs.
    let(:services_reading_backend_secrets) do
      services.filter_map do |service|
        launcher = rootfs_bin.join(File.basename(service.fetch("start_command")))
        next unless File.exist?(launcher)

        service["name"] if File.read(launcher).include?("backend-default.conf")
      end
    end

    it "has services that read hub-backend's root-only secrets file as root" do
      # The premise of the grant below. If this changes, the capability should
      # be re-justified or removed — not silently retained.
      expect(services_reading_backend_secrets).to contain_exactly("sidekiq", "worker-web")
      expect(services.map { |s| s["user"] }.uniq).to eq([ "root" ])
    end

    it "grants CAP_DAC_READ_SEARCH at the TOP LEVEL, where the agent reads it" do
      expect(manifest.dig("security", "capabilities")).to include("CAP_DAC_READ_SEARCH")
    end

    it "keeps the grant minimal — read/traverse only, and not privileged" do
      # CAP_DAC_OVERRIDE would additionally bypass WRITE checks; nothing here
      # writes outside /opt/powernode/worker, which root already owns.
      # privileged:true would skip the capability drop-in entirely, and
      # policy.Validate() rejects privileged combined with explicit caps.
      expect(manifest.dig("security", "capabilities")).to contain_exactly("CAP_DAC_READ_SEARCH")
      expect(manifest.dig("security", "privileged")).to be false
    end
  end
end
