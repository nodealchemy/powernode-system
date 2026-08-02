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
end
