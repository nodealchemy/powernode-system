# frozen_string_literal: true

# P8.4 — Cluster-member HA smoke.
#
# Exercises the cluster_member spawn flow end-to-end: the parent
# platform creates a federation peer in `cluster_member` mode, the
# replica setup service materializes a PG physical replication slot
# + replication credentials, and the cluster_member template
# composition is verified.
#
# Two modes:
#   POWERNODE_LIBVIRT_MODE=local (default) — orchestration-only.
#       Asserts the spawn pipeline produces the right DB rows + the
#       PG replica setup service is reachable. No VMs booted.
#   POWERNODE_LIBVIRT_MODE=real            — boots two QEMU VMs.
#       Verifies live PG replication, then kills the parent and times
#       the failover to confirm <60s recovery.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_cluster_member_ha.rb')"
#
# Exits non-zero on any failure for CI gating.
#
# Plan reference: P8.4 (Cluster_member HA scenario, primary loss + <60s failover).

require "socket"
require "timeout"

# ── Helpers ───────────────────────────────────────────────────────────

class ClusterHaResult
  attr_reader :passed, :failed
  def initialize
    @passed = []
    @failed = []
  end

  def check(label)
    yield
    @passed << label
    puts "    ✓ #{label}"
  rescue StandardError => e
    @failed << [ label, e.message ]
    puts "    ✗ #{label} — #{e.message}"
  end

  def report!
    total = @passed.size + @failed.size
    puts ""
    puts "  ======================================="
    puts "  Cluster-member HA smoke: #{@passed.size}/#{total} passed"
    puts "  ======================================="
    @failed.each { |label, msg| puts "    FAIL: #{label} — #{msg}" }
    exit(@failed.empty? ? 0 : 1)
  end
end

def libvirt_mode
  ENV.fetch("POWERNODE_LIBVIRT_MODE", "local")
end

def tcp_open?(host, port, timeout: 3)
  ::Timeout.timeout(timeout) do
    s = ::TCPSocket.new(host, port)
    s.close
    true
  end
rescue ::Errno::ECONNREFUSED, ::Errno::EHOSTUNREACH, ::Errno::ENETUNREACH, ::Timeout::Error => e
  raise "TCP #{host}:#{port} — #{e.class}: #{e.message}"
end

# ── Setup ─────────────────────────────────────────────────────────────

puts "\n  P8.4 — Cluster-member HA smoke"
puts "  ======================================="
puts "  POWERNODE_LIBVIRT_MODE=#{libvirt_mode}"
puts ""

account = ::Account.first or abort("  ❌ No account")
parent_url = ENV.fetch("SMOKE_PARENT_URL", "https://parent-hub.smoke.example.com")
child_name = ENV.fetch("SMOKE_CLUSTER_CHILD_NAME", "cluster-child-1-#{Time.now.to_i}")

# Find or stub a target. SpawnPlatformService can produce a Node +
# NodeInstance OR can defer that to a Federation::SpawnProvisioner
# pass; for the smoke we just need the peer-row machinery + replica
# setup pipeline to fire.
cluster_template = ::System::NodeTemplate.find_by(account: account, name: "powernode-hub-cluster-member")
abort("  ❌ powernode-hub-cluster-member template missing — run powernode_platform_templates.rb") unless cluster_template

results = ClusterHaResult.new

# ── Stage 1: cluster_member template composition ──────────────────────

results.check("cluster-member template ships the canonical 6-module set (no local postgres/redis/frontend)") do
  # Plan §H: cluster-member = reverse-proxy + base-ruby + hub-backend +
  # hub-worker + pg-replica (no own postgres). Extension-system is
  # loaded into hub-backend so it ships too. Redis + frontend are
  # served from the parent via SDWAN VIP — NOT local to the member.
  expected = %w[
    powernode-reverse-proxy powernode-base-ruby
    powernode-pg-replica powernode-hub-backend powernode-hub-worker
    powernode-extension-system
  ]
  tmpl_modules = cluster_template.template_modules.includes(:node_module).map { |tm| tm.node_module.name }
  missing = expected - tmpl_modules
  raise "missing from template: #{missing.inspect}" if missing.any?
end

results.check("cluster-member template does NOT include postgres / redis / frontend (shared from parent)") do
  forbidden = %w[powernode-postgres powernode-redis powernode-hub-frontend]
  present_forbidden = cluster_template.template_modules.includes(:node_module)
                                       .map { |tm| tm.node_module.name } & forbidden
  raise "cluster member shouldn't ship: #{present_forbidden.inspect}" if present_forbidden.any?
end

# ── Stage 2: spawn pipeline — peer record + replica setup ─────────────

# We dispatch via SpawnPlatformService just like a real cluster-member
# spawn. The service creates a FederationPeer in `proposed` with
# spawn_mode=cluster_member + spawn_role=parent and enqueues the PG
# replica setup job.
peer_id = nil
spawn_result = nil
results.check("SpawnPlatformService.spawn!(cluster_member) creates a FederationPeer row") do
  # spawn_target encodes the provider-specific provisioning args.
  # template_id is the cluster-member template (PG replica + minimal stack).
  spawn_result = ::System::SpawnPlatformService.spawn!(
    account:     account,
    spawn_mode:  "cluster_member",
    spawn_target: { template_id: cluster_template.id },
    parent_url:  parent_url
  )
  raise "spawn failed: #{spawn_result.error}" if spawn_result.respond_to?(:ok?) && !spawn_result.ok?
  peer = spawn_result.respond_to?(:federation_peer) ? spawn_result.federation_peer : nil
  raise "no peer returned: #{spawn_result.inspect}" unless peer.is_a?(::System::FederationPeer)
  raise "spawn_mode wrong: #{peer.spawn_mode.inspect}" unless peer.spawn_mode.to_s == "cluster_member"
  raise "spawn_role wrong: #{peer.spawn_role.inspect}" unless peer.spawn_role.to_s == "parent"
  peer_id = peer.id
end

peer = peer_id ? ::System::FederationPeer.find_by(id: peer_id) : nil

results.check("FederationPeer is in `proposed` state with valid acceptance_token") do
  raise "no peer to inspect" unless peer
  raise "status not proposed: #{peer.status.inspect}" unless peer.status == "proposed"
  raise "no acceptance_token digest" if peer.acceptance_token_digest.blank?
  raise "no acceptance_token expiry" if peer.acceptance_token_expires_at.nil?
end

results.check("FederationPeer carries the parent_url in remote_instance_url") do
  raise "no peer to inspect" unless peer
  raise "wrong url: #{peer.remote_instance_url.inspect}" unless peer.remote_instance_url == parent_url
end

results.check("PG replica setup service is reachable + accepts the peer") do
  service_class = "::System::ClusterMember::PgReplicaSetupService".safe_constantize
  raise "service class missing" unless service_class
  raise "no run! method" unless service_class.instance_method(:run!)
  raise "no peer to setup against" unless peer
  # Don't actually run! — that requires a real PG primary running on
  # localhost with replication user creation rights. The check
  # confirms the service can be instantiated with the peer.
  svc = service_class.new(peer: peer)
  raise "service didn't accept peer" unless svc
end

# ── Stage 3: spawn payload shape ──────────────────────────────────────

results.check("SpawnPlatformService::Result exposes spawn_payload with parent_url + acceptance_token + spawn_mode") do
  raise "no spawn result captured" unless spawn_result
  payload = spawn_result.respond_to?(:spawn_payload) ? spawn_result.spawn_payload : nil
  raise "no spawn_payload on Result struct" if payload.nil?
  raise "no parent_url"       if payload["parent_url"].blank? && payload[:parent_url].blank?
  raise "no acceptance_token" if payload["acceptance_token"].blank? && payload[:acceptance_token].blank?
  mode = payload["spawn_mode"] || payload[:spawn_mode]
  raise "wrong spawn_mode: #{mode.inspect}" unless mode.to_s == "cluster_member"
end

# ── Stage 4: real-mode HA timing (only when explicitly requested) ─────

if libvirt_mode == "real"
  parent_host = ENV["SMOKE_PARENT_HOST"]    or abort("  ❌ SMOKE_PARENT_HOST required in real mode")
  child_host  = ENV["SMOKE_CHILD_HOST"]     or abort("  ❌ SMOKE_CHILD_HOST required in real mode")

  results.check("parent PG accepts replication on :5432") { tcp_open?(parent_host, 5432) }
  results.check("child  PG replica accepting on :5433")   { tcp_open?(child_host,  5433) }

  results.check("replication catches up (lag < 10s) within 60s") do
    deadline = ::Time.now + 60
    until ::Time.now > deadline
      lag = `psql -h #{child_host} -p 5433 -U postgres -tAc "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))"`.to_f rescue nil
      break if lag && lag < 10
      sleep 2
    end
    raise "replica didn't catch up within 60s (last lag=#{lag.inspect})" if lag.nil? || lag >= 10
  end

  results.check("failover happens within 60s after primary loss") do
    # Force-stop parent's PG. Then watch child's replica for promotion.
    `ssh #{parent_host} 'sudo systemctl stop powernode-019e29d3-7c2f-7af8-8750-2c619927cd25-postgres.service'`
    t0 = ::Time.now
    deadline = t0 + 60
    promoted = false
    until ::Time.now > deadline
      in_recovery = `psql -h #{child_host} -p 5433 -U postgres -tAc "SELECT pg_is_in_recovery()"`.strip
      if in_recovery == "f"
        promoted = true
        break
      end
      sleep 2
    end
    elapsed = ::Time.now - t0
    raise "no promotion within 60s (in_recovery still true)" unless promoted
    raise "promotion took #{elapsed.round(1)}s (>60s)" if elapsed > 60
    puts "      (failover elapsed: #{elapsed.round(1)}s)"
  end
end

# Cleanup the synthetic peer so reruns don't accumulate
::System::FederationPeer.where(id: peer_id).destroy_all if peer_id

results.report!
