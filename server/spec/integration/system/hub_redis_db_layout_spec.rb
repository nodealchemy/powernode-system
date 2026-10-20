# frozen_string_literal: true

require "rails_helper"
require "open3"

# IMP-fa170be95ab9 / IMP-daecbb8a050e — the server and the hub-worker must
# agree on which Redis database holds the Sidekiq queues.
#
# On a module-composed hub the worker's REDIS_URL is redis://localhost:6379/0:
# the manifest env says so, and the persisted secrets file rails-start.sh
# writes on first boot says so too (both start scripts source that file with
# `set -a` AFTER systemd's Environment=, so the file is what actually wins).
# Left alone, the server derives every worker-side Redis address as database 1
# (Powernode::Redis.worker_url rewrites the general URL's /N to /1), so jobs
# the server pushes are never run and Sidekiq's process registry read from
# there is always empty: lost jobs and a false "Sidekiq down".
#
# Phase 1 of the canonical layout (0 general / 1 Sidekiq / 2 cable) moves no
# data: hub-backend exports POWERNODE_WORKER_REDIS_URL at the hub's interim
# Sidekiq DB (/0), worker_url honors it, and System::WorkerJobEnqueuer resolves
# through worker_url. These examples resolve the server's worker URL under
# exactly the env hub-backend gives Rails, by running the derivation line out
# of rails-start.sh itself.
#
# Installer hosts (scripts/systemd/configs) put the worker on /1 and set no
# override; the last example pins that, so the fix cannot regress them.
RSpec.describe "Hub Redis database layout (server enqueue DB == worker Sidekiq DB)" do
  let(:repo_root) { Rails.root.join("..") }
  let(:modules_dir) { repo_root.join("extensions/system/modules") }

  let(:worker_manifest) do
    YAML.safe_load(File.read(modules_dir.join("powernode-hub-worker/manifest.yaml")), aliases: true)
  end
  let(:backend_manifest_text) { File.read(modules_dir.join("powernode-hub-backend/manifest.yaml")) }
  let(:rails_start) { File.read(modules_dir.join("powernode-hub-backend/rootfs/usr/local/bin/rails-start.sh")) }
  let(:rails_exec) { File.read(modules_dir.join("powernode-hub-backend/rootfs/usr/local/bin/powernode-rails-exec")) }

  # The one line that derives the worker URL; a default, never an override.
  def derivation(script, name)
    script[/^: "\$\{POWERNODE_WORKER_REDIS_URL:=[^\n]*\}"$/] ||
      raise("#{name} does not derive POWERNODE_WORKER_REDIS_URL")
  end

  # Evaluate rails-start.sh's derivation in bash as a default-topology hub
  # boots it: REDIS_HOST=localhost, nothing preset.
  let(:hub_backend_worker_redis_url) do
    script = "#{derivation(rails_start, 'rails-start.sh')}\nprintf '%s' \"$POWERNODE_WORKER_REDIS_URL\""
    out, status = Open3.capture2(
      { "REDIS_HOST" => "localhost", "POWERNODE_WORKER_REDIS_URL" => nil }, "bash", "-c", script
    )
    raise "derivation failed: #{status.inspect}" unless status.success?

    out
  end

  def redis_db(url)
    Integer(URI.parse(url.gsub("${REDIS_HOST}", "localhost")).path.delete("/"), 10)
  end

  # The REDIS_URL hub-backend's Rails process runs with (unit_body Environment=).
  let(:hub_backend_redis_url) do
    backend_manifest_text[/Environment=REDIS_URL=(\S+)/, 1] || raise("hub-backend unit sets no REDIS_URL")
  end

  # The worker's Sidekiq URL the persisted secrets file carries; sidekiq-start.sh
  # and worker-web-start.sh source it last, so this is the worker's effective
  # URL. The worker reads POWERNODE_WORKER_REDIS_URL first, then REDIS_URL.
  let(:secrets_file_redis_url) do
    heredoc = rails_start[/cat > "\$SECRETS_FILE" <<EOF\n(.*?)\nEOF/m, 1] || raise("secrets heredoc not found")
    heredoc[/^POWERNODE_WORKER_REDIS_URL=(\S+)/, 1] || heredoc[/^REDIS_URL=(\S+)/, 1] ||
      raise("secrets file sets no REDIS_URL")
  end

  let(:worker_service_urls) do
    worker_manifest.fetch("services").to_h do |s|
      [ s["name"], s.dig("env", "POWERNODE_WORKER_REDIS_URL") || s.dig("env", "REDIS_URL") ]
    end
  end

  let(:hub_worker_db) { redis_db(secrets_file_redis_url) }

  # Resolve a worker URL as a production process would: no test lane rewrite,
  # the general URL taken from the hub-backend environment, and
  # POWERNODE_WORKER_REDIS_URL as the unit exports it (nil = not exported).
  def production_worker_url(general_url, worker_override: nil, resolver: -> { Powernode::Redis.worker_url })
    allow(ENV).to receive(:[]).with("POWERNODE_WORKER_REDIS_URL").and_return(worker_override)
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    allow(Admin::SystemSettings).to receive(:redis_config).and_return({ "url" => general_url })
    Powernode::Redis.reconfigure!
    resolver.call
  ensure
    Powernode::Redis.reconfigure!
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    # Neither unit sets the deprecated alias.
    allow(ENV).to receive(:[]).with("SIDEKIQ_REDIS_URL").and_return(nil)
    allow(ENV).to receive(:[]).with("POWERNODE_WORKER_REDIS_URL").and_return(nil)
  end

  it "has one worker Redis database across sidekiq, worker-web and the secrets file" do
    expect(worker_service_urls.keys).to contain_exactly("sidekiq", "worker-web")
    dbs = worker_service_urls.values.map { |u| redis_db(u) } + [ hub_worker_db ]
    expect(dbs.uniq).to eq([ hub_worker_db ])
  end

  it "hub-backend exports POWERNODE_WORKER_REDIS_URL, identically for puma and out-of-band rails" do
    expect(rails_start).to match(/^export POWERNODE_WORKER_REDIS_URL$/)
    expect(rails_exec).to match(/^export POWERNODE_WORKER_REDIS_URL$/)
    expect(derivation(rails_exec, "powernode-rails-exec")).to eq(derivation(rails_start, "rails-start.sh"))
    expect(redis_db(hub_backend_worker_redis_url)).to eq(hub_worker_db)
  end

  it "Powernode::Redis.worker_url points at the database hub-worker Sidekiq reads" do
    url = production_worker_url(hub_backend_redis_url, worker_override: hub_backend_worker_redis_url)

    expect(redis_db(url)).to eq(hub_worker_db),
      "server worker_url #{url} (db #{redis_db(url)}) != hub-worker REDIS_URL #{secrets_file_redis_url} (db #{hub_worker_db})"
  end

  it "System::WorkerJobEnqueuer pushes into the database hub-worker Sidekiq reads" do
    url = production_worker_url(hub_backend_redis_url, worker_override: hub_backend_worker_redis_url,
                                                       resolver: -> { System::WorkerJobEnqueuer.worker_redis_url })

    expect(redis_db(url)).to eq(hub_worker_db),
      "WorkerJobEnqueuer #{url} (db #{redis_db(url)}) != hub-worker REDIS_URL #{secrets_file_redis_url} (db #{hub_worker_db})"
  end

  it "keeps installer hosts consistent (worker conf DB == server-derived worker DB)" do
    configs = repo_root.join("scripts/systemd/configs")
    conf_url = ->(name) { File.read(configs.join(name))[/^REDIS_URL=(\S+)/, 1] }
    installer_worker_dbs = %w[worker-default.conf worker-web-default.conf].map { |f| redis_db(conf_url.call(f)) }

    expect(installer_worker_dbs.uniq.size).to eq(1)
    expect(redis_db(production_worker_url(conf_url.call("backend-default.conf")))).to eq(installer_worker_dbs.first)
  end
end
