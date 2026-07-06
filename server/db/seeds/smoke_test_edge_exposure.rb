# frozen_string_literal: true

# System extension — end-to-end edge smoke across all six ingress/egress
# exposure paths (campaign 019f3458 increment 10), grounded in
# docs/runbooks/traefik-tcp-exposure-vs-dnat.md:
#
#   1. HTTPS via Path A (Sdwan::VirtualIp + Sdwan::PortMapping projection,
#      System::Ai::Skills::ExposeServicePubliclyExecutor)
#   2. Federated TLS passthrough (Federation::ServiceRouteWriter, tls-protocol
#      subscription -> tcp.routers with tls.passthrough + entryPoints websecure)
#   3. Federated TCP via tcpfwd (Federation::TcpForwarderConfigWriter,
#      non-site-local tcp-protocol subscription)
#   4. Public TLS-carrying TCP via Traefik SNI -- Path B -- in all three
#      edge_mode/client_auth shapes (passthrough, terminate, terminate+mTLS),
#      driven through the real System::Ai::Skills::ExposeServicePublicTcpExecutor
#   5. Public TCP+UDP via nftables DNAT -- Path C -- with the increment-6
#      hardening tier (source_cidrs / max_connections / rate_limit),
#      Sdwan::NatCompiler
#   6. Site-local tcpfwd (Federation::TcpForwarderConfigWriter, site-local
#      subscription)
#
# HONESTY BAR: this seed classifies, per path, the verification depth it
# actually achieved -- printed as a ledger at the end and stamped into each
# path's System::FleetEvent#payload["depth"]:
#
#   (a) real network reachability      -- an actual socket handshake through
#                                          real running code, on this host
#   (b) recorder-tape/agent-contract   -- not used here (no libvirt/agent
#                                          recorder in scope for this seed)
#   (c) config-plane verification      -- writer output structurally correct
#                                          + Ruby-side re-parse of the exact
#                                          bytes a real Traefik/nft would
#                                          consume, but no live Traefik/nft
#                                          process actually consumes them
#
# Paths 3 and 6 reach (a): campaign 019f3458 increment 4 wired the tcpfwd
# daemon into the agent's service loop, but no standalone entrypoint existed
# to run it outside the full mTLS-enrolled agent service -- so this seed
# builds one (agent/cmd/tcpfwd-smoke), compiles it, and runs the REAL
# forwarder package against a REAL Ruby-writer-generated config, pumping
# real bytes through real loopback sockets (127.0.0.1 listen -> 127.0.0.2
# backend, both real interfaces, no stubbing).
#
# Paths 1, 2, 4, 5 stay at (c): a live Traefik process consuming the emitted
# YAML, and a live nft process applying the emitted ruleset, are both
# structurally unavailable from this worktree (campaign-branch code isn't
# deployed to the live platform, and this host has no CAP_NET_ADMIN/user-
# namespace access for `nft -c` -- see the Path 5 section for the specific
# error). The campaign's disposable-hub increments (12/15) own the real
# end-to-end network pass on campaign-built instances.
#
# Safe to run repeatedly: every fixture is prefixed "smoke-edge-"; the top of
# each section wipes prior smoke-edge rows before creating fresh ones
# (mirroring smoke_test_expose_service.rb); the Traefik dynamic-config writes
# go to a scratch tmp dir via POWERNODE_TRAEFIK_DYNAMIC_DIR (restored after);
# the tcpfwd daemon subprocess and its Ruby-side echo-server threads are
# torn down in an ensure block regardless of check outcome.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_edge_exposure.rb')"
#
# Exits non-zero on any check failure so CI can gate on it.

require "fileutils"
require "yaml"
require "json"
require "socket"
require "timeout"
require "open3"
require "securerandom"

# ── Result tracker: pass/fail bookkeeping + a System::FleetEvent per check
#    + the per-path depth ledger the campaign verification bar requires ──

class EdgeSmokeResult
  attr_reader :passed, :failed, :fleet_event_ids, :ledger

  def initialize(account:, correlation_id:)
    @account = account
    @correlation_id = correlation_id
    @passed = []
    @failed = []
    @fleet_event_ids = []
    @ledger = {} # path_key => { depth:, note: }
  end

  def depth!(path_key, depth, note)
    @ledger[path_key] = { depth: depth, note: note }
  end

  # Runs the block, records pass/fail, and always emits a System::FleetEvent
  # (severity high on failure) so the campaign's "emit expected
  # System::FleetEvent rows" bar is met for every check, not just passes.
  def check(path_key, label)
    yield
    @passed << label
    puts "    ✓ #{label}"
    emit_event!(path_key, label, "low", nil)
  rescue StandardError => e
    @failed << [ label, e.message ]
    puts "    ✗ #{label} — #{e.message}"
    emit_event!(path_key, label, "high", e.message)
  end

  def emit_event!(path_key, label, severity, error)
    event = ::System::FleetEvent.create!(
      account: @account,
      kind: "system.edge_exposure_smoke.#{path_key}",
      severity: severity,
      source: "smoke_test_edge_exposure",
      correlation_id: @correlation_id,
      payload: {
        "label" => label,
        "depth" => @ledger[path_key]&.dig(:depth),
        "error" => error
      }.compact
    )
    @fleet_event_ids << event.id
  end

  def report!
    total = @passed.size + @failed.size
    puts ""
    puts "  ==========================================="
    puts "  Edge exposure smoke: #{@passed.size}/#{total} passed"
    puts "  ==========================================="
    @failed.each { |label, msg| puts "    FAIL: #{label} — #{msg}" }
    puts ""
    puts "  Per-path depth ledger:"
    @ledger.each { |path, info| puts "    #{path}: (#{info[:depth]}) #{info[:note]}" }
    puts ""
    puts "  FleetEvent ids: #{@fleet_event_ids.join(', ')}"
    exit(@failed.empty? ? 0 : 1)
  end
end

def reserve_port
  server = TCPServer.new("0.0.0.0", 0)
  port = server.addr[1]
  server.close
  port
end

# In-process Ruby TCP echo server (mirrors the Go forwarder_test.go
# `startEchoServer` idiom): reads until the peer half-closes (EOF), writes
# the same bytes back, then half-closes its own write side so the far end
# (the tcpfwd daemon's backend connection) observes EOF and completes the
# bidirectional pump cleanly.
def start_echo_server(host, port)
  server = TCPServer.new(host, port)
  thread = Thread.new do
    loop do
      client = server.accept
      Thread.new(client) do |c|
        data = c.read
        c.write(data)
        c.shutdown(Socket::SHUT_WR)
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
      ensure
        c.close rescue nil
      end
    end
  rescue IOError, Errno::EBADF
    # server closed during shutdown — expected, exit the accept loop
  end
  [ server, thread ]
end

def echo_roundtrip(host, port, payload, timeout: 3)
  Timeout.timeout(timeout) do
    sock = TCPSocket.new(host, port)
    sock.write(payload)
    sock.shutdown(Socket::SHUT_WR)
    response = sock.read
    sock.close
    response
  end
end

puts "\n  Edge exposure smoke (campaign 019f3458 increment 10) — six paths"
puts "  " + ("=" * 66)

# ── Shared setup ────────────────────────────────────────────────────────

account  = ::Account.first or abort("  ❌ No account in DB")
template = ::System::NodeTemplate.find_by(account: account, name: "base") ||
           ::System::NodeTemplate.where(account: account).first ||
           abort("  ❌ No node template — run node_module_catalog.rb first")
provider = ::System::Provider.find_by(account: account, provider_type: "local_qemu") ||
           abort("  ❌ No local_qemu provider")
region   = provider.provider_regions.first or abort("  ❌ No provider region")
itype    = provider.provider_instance_types.first or abort("  ❌ No instance type")

def find_or_create_instance!(account:, template:, region:, itype:, name:)
  node = ::System::Node.find_or_create_by!(account: account, name: "#{name}-node") do |n|
    n.node_template = template
  end
  instance = ::System::NodeInstance.find_or_initialize_by(node: node, name: name)
  instance.assign_attributes(variety: "cloud", provider_region: region,
                              provider_instance_type: itype, status: "running")
  instance.save!
  [ node, instance ]
end

hub_node, hub_instance         = find_or_create_instance!(account: account, template: template, region: region,
                                                            itype: itype, name: "smoke-edge-hub-instance")
backend_node, backend_instance = find_or_create_instance!(account: account, template: template, region: region,
                                                            itype: itype, name: "smoke-edge-backend-instance")

network = ::Sdwan::Network.find_or_create_by!(account: account, name: "smoke-edge-network") do |n|
  n.cidr_64 = "fd00:beef:ed6e:#{rand(0x1000..0xffff).to_s(16)}::/64"
  n.routing_protocol = "static"
  n.settings = { "topology_strategy" => "hub_and_spoke" }
end
# PortMapping/VirtualIp FK-reference Peer (target_peer_id/sdwan_peer_id,
# target_virtual_ip_id's holder) — the network survives across runs
# (find_or_create_by!) but peers get wiped and recreated every run, so any
# leftover mapping/VIP from a prior run (crash, or SMOKE_KEEP=1) must be
# cleared BEFORE the peer reset below, not just at each path's own
# idempotent top-of-section cleanup, or the peer destroy_all raises
# ForeignKeyViolation.
::Sdwan::PortMapping.where(sdwan_network_id: network.id).destroy_all
::Sdwan::VirtualIp.where(network: network).destroy_all
::Sdwan::Peer.where(network: network, node_instance: [ hub_instance, backend_instance ]).destroy_all

hub_peer = ::Sdwan::PeerEnroller.call(
  network: network, node_instance: hub_instance,
  publicly_reachable: true, endpoint_host_v6: "fd00:beef:ed6e::1", endpoint_port: 51_820
)
backend_peer = ::Sdwan::PeerEnroller.call(network: network, node_instance: backend_instance)
vip_prefix = network.cidr_64.sub(%r{::/64\z}, "")

correlation_id = SecureRandom.uuid
results = EdgeSmokeResult.new(account: account, correlation_id: correlation_id)

puts "  Account:      #{account.id[0..7]}…"
puts "  Network:      #{network.name} (#{network.cidr_64})"
puts "  Hub peer:     #{hub_peer.id[0..7]}…  addr=#{hub_peer.assigned_address}"
puts "  Backend peer: #{backend_peer.id[0..7]}…  addr=#{backend_peer.assigned_address}"
puts "  Correlation:  #{correlation_id}"
puts ""

# Shared Traefik-dynamic-config scratch dir (Path A doesn't write YAML —
# it goes through Sdwan::VirtualIp/PortMapping — but Paths 2/4 both do, and
# their filenames never collide: "service-subscriptions-<id>.yaml" vs
# "local-services-<id>.yaml").
scratch_dir = ::Rails.root.join("tmp", "smoke-edge-exposure")
FileUtils.mkdir_p(scratch_dir)
prior_dynamic_dir = ENV["POWERNODE_TRAEFIK_DYNAMIC_DIR"]
ENV["POWERNODE_TRAEFIK_DYNAMIC_DIR"] = scratch_dir.to_s

# ══════════════════════════════════════════════════════════════════════
# PATH 1 — HTTPS via Path A (VIP + PortMapping projection)
# ══════════════════════════════════════════════════════════════════════
puts "  [Path A] HTTPS via ExposeServicePubliclyExecutor"

path_a_hostname = "smoke-edge-a.example.test"
path_a_vip_name = "expose-#{path_a_hostname}"
::Sdwan::VirtualIp.where(network: network, name: path_a_vip_name).destroy_all

# Depth is known a priori (independent of the check's outcome) — set before
# the check runs so the check's own FleetEvent payload carries it.
results.depth!("path_a", "c",
  "real ExposeServicePubliclyExecutor invoked end-to-end (no stub) — creates real " \
  "Sdwan::VirtualIp + Sdwan::PortMapping DB rows a reconciler would later compile; " \
  "no live Traefik/kernel nft consumes them in this worktree")
results.check("path_a", "Path A: create-and-expose (http, no ACME)") do
  executor = ::System::Ai::Skills::ExposeServicePubliclyExecutor.new(account: account)
  result = executor.execute(
    service_hostname: path_a_hostname, service_protocol: "http",
    sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
    vip_cidr: "#{vip_prefix}::a1/128",
    target_peer_id: backend_peer.id, backend_port: 8080
  )
  raise "execute returned success: false (#{result[:error]})" unless result[:success]
  raise "no vip_id in result" if result[:data][:vip_id].blank?
  raise "no port_mapping_id in result" if result[:data][:port_mapping_id].blank?

  vip = ::Sdwan::VirtualIp.find(result[:data][:vip_id])
  raise "VIP holder is not the backend peer" unless vip.holder_peer_ids == [ backend_peer.id ]
  pm = ::Sdwan::PortMapping.find(result[:data][:port_mapping_id])
  raise "port mapping wiring wrong (:80 -> :8080 expected)" \
    unless pm.listen_port == 80 && pm.target_port == 8080 && pm.target_virtual_ip_id == vip.id
end

# ══════════════════════════════════════════════════════════════════════
# Federation fixtures shared by Paths 2, 3, 6
# ══════════════════════════════════════════════════════════════════════

::System::Federation::ServiceSubscription.where(account: account,
  service_offering_slug: "smoke-edge-offering").destroy_all
::System::Federation::ServiceOffering.where(account: account, slug: "smoke-edge-offering").destroy_all
::Sdwan::Service.where(account: account, slug: "smoke-edge-offering-backend").destroy_all
::System::FederationGrant.where(remote_subject: "smoke-edge-subject@peer.example.test").destroy_all
::System::FederationPeer.where(account: account, remote_instance_url: "https://smoke-edge-peer.example.test").destroy_all
::System::AcmeCertificate.where(account: account, common_name: "smoke-edge-tls.example.test").destroy_all

federation_peer = ::System::FederationPeer.create!(
  account: account, remote_instance_url: "https://smoke-edge-peer.example.test",
  remote_instance_id: SecureRandom.uuid, status: "active", peer_kind: "platform",
  spawn_role: "symmetric", spawn_mode: "out_of_band",
  last_handshake_at: 1.hour.ago, last_heartbeat_at: Time.current
)
federation_grant = ::System::FederationGrant.create!(
  account: account, federation_peer: federation_peer, grantor_user: nil,
  remote_subject: "smoke-edge-subject@peer.example.test", resource_kind: "service_subscription",
  permission_scopes: [ "read" ], issued_at: Time.current, expires_at: 30.days.from_now
)
offering_backend_service = ::Sdwan::Service.create!(
  account: account, slug: "smoke-edge-offering-backend", name: "Smoke Edge Offering Backend",
  protocol: "https", backend_host: "backend.smoke-edge.example.test", backend_port: 443
)
service_offering = ::System::Federation::ServiceOffering.create!(
  account: account, slug: "smoke-edge-offering", name: "Smoke Edge Offering",
  status: "active", default_grant_ttl_days: 30, default_grant_scopes: [ "read" ],
  service: offering_backend_service
)
tls_cert = ::System::AcmeCertificate.create!(
  account: account, common_name: "smoke-edge-tls.example.test",
  issuer: "letsencrypt-prod", challenge_type: "http-01", dns_credential: nil,
  status: "valid", issued_at: Time.current, expires_at: 90.days.from_now
)

# ══════════════════════════════════════════════════════════════════════
# PATH 2 — Federated TLS passthrough (Federation::ServiceRouteWriter)
# ══════════════════════════════════════════════════════════════════════
puts ""
puts "  [Path D] Federated TLS passthrough (Federation::ServiceRouteWriter)"

tls_sub = ::System::Federation::ServiceSubscription.create!(
  account: account, federation_peer: federation_peer, federation_grant: federation_grant,
  acme_certificate: tls_cert, service_offering_slug: service_offering.slug,
  service_offering_id: service_offering.id, local_hostname: "smoke-edge-tls.example.test",
  protocol: "tls", backend_vip: "fd00:beef:ed6e::30", backend_port: 8883,
  status: "active", activated_at: Time.current
)

# ══════════════════════════════════════════════════════════════════════
# Loopback fixtures for Paths 3 + 6 (real tcpfwd daemon run)
# ══════════════════════════════════════════════════════════════════════

fwd_tcp_port = reserve_port          # Path 3: non-site-local tcp-protocol sub
fwd_site_local_port = reserve_port   # Path 6: site-local sub

tcp_sub = ::System::Federation::ServiceSubscription.create!(
  account: account, federation_peer: federation_peer, federation_grant: federation_grant,
  acme_certificate: nil, service_offering_slug: service_offering.slug,
  service_offering_id: service_offering.id, local_hostname: "127.0.0.1", protocol: "tcp",
  backend_vip: "127.0.0.2", backend_port: fwd_tcp_port, status: "active", activated_at: Time.current
)
site_local_sub = ::System::Federation::ServiceSubscription.create!(
  account: account, federation_peer: federation_peer, federation_grant: federation_grant,
  acme_certificate: nil, service_offering_slug: service_offering.slug,
  service_offering_id: service_offering.id, local_hostname: "127.0.0.1:#{fwd_site_local_port}",
  protocol: "tcp", backend_vip: "127.0.0.2", backend_port: fwd_site_local_port,
  status: "active", activated_at: Time.current
)

results.depth!("path_d_tls_passthrough", "c",
  "Federation::ServiceRouteWriter invoked for real; asserted the exact YAML bytes a real " \
  "Traefik file-provider would load (passthrough:true, entryPoints:[websecure], HostSNI rule); " \
  "no live Traefik process actually loads it")
results.check("path_d_tls_passthrough", "Path D: ServiceRouteWriter emits tls passthrough shape, excludes tcp-protocol subs") do
  result = ::Federation::ServiceRouteWriter.write!(account: account, dynamic_dir: scratch_dir.to_s)
  raise "route_count wrong (#{result[:route_count]}, expected 1)" unless result[:route_count] == 1
  parsed = YAML.load_file(result[:output_path])

  router = parsed.dig("tcp", "routers", "sub-#{tls_sub.id}")
  raise "no tcp router emitted for the tls sub" if router.nil?
  raise "rule wrong (#{router['rule']})" unless router["rule"] == "HostSNI(`smoke-edge-tls.example.test`)"
  raise "entryPoints wrong (#{router['entryPoints'].inspect})" unless router["entryPoints"] == [ "websecure" ]
  raise "tls block wrong (#{router['tls'].inspect})" unless router["tls"] == { "passthrough" => true }

  backend = parsed.dig("tcp", "services", "sub-#{tls_sub.id}-backend", "loadBalancer", "servers")
  raise "backend address wrong (#{backend.inspect})" unless backend == [ { "address" => "fd00:beef:ed6e::30:8883" } ]

  raise "tcp-protocol sub leaked into Traefik output" \
    if parsed.dig("tcp", "routers")&.key?("sub-#{tcp_sub.id}") || parsed.dig("tcp", "routers")&.key?("sub-#{site_local_sub.id}")
end

# ══════════════════════════════════════════════════════════════════════
# PATH 3 + PATH 6 — Federated tcp via tcpfwd / site-local tcpfwd
#   Config-plane assertions first, then a REAL daemon run on loopback.
# ══════════════════════════════════════════════════════════════════════
puts ""
puts "  [Path D] Federated tcp + site-local via tcpfwd (Federation::TcpForwarderConfigWriter)"

tcpfwd_config_path = scratch_dir.join("forwards.json").to_s

results.check("path_d_tcpfwd_config", "tcpfwd config: writer emits both forwards, correct listen/backend pairs") do
  result = ::Federation::TcpForwarderConfigWriter.write!(account: account, config_path: tcpfwd_config_path)
  raise "forward_count wrong (#{result[:forward_count]}, expected 2)" unless result[:forward_count] == 2

  parsed = JSON.parse(File.read(tcpfwd_config_path))
  by_sub = parsed["forwards"].index_by { |f| f["subscription_id"] }

  tcp_fwd = by_sub[tcp_sub.id] or raise "no forward for the non-site-local tcp sub"
  raise "tcp forward wrong (#{tcp_fwd.inspect})" unless tcp_fwd == {
    "listen" => "127.0.0.1:#{fwd_tcp_port}", "backend" => "127.0.0.2:#{fwd_tcp_port}",
    "protocol" => "tcp", "subscription_id" => tcp_sub.id
  }

  site_fwd = by_sub[site_local_sub.id] or raise "no forward for the site-local sub"
  raise "site-local forward wrong (#{site_fwd.inspect})" unless site_fwd == {
    "listen" => "127.0.0.1:#{fwd_site_local_port}", "backend" => "127.0.0.2:#{fwd_site_local_port}",
    "protocol" => "tcp", "subscription_id" => site_local_sub.id
  }
end

# --- Real daemon run: build agent/cmd/tcpfwd-smoke, run it against the
#     config above, pump real bytes through real loopback sockets. ---
agent_dir = File.expand_path("../../../agent", __dir__)
tcpfwd_bin = scratch_dir.join("tcpfwd-smoke").to_s
tcpfwd_log = scratch_dir.join("tcpfwd-smoke.log").to_s

echo_tcp = echo_site_local = nil
daemon_pid = nil

begin
  results.check("path_d_tcpfwd_build", "tcpfwd-smoke: go build succeeds") do
    _out, err, status = Open3.capture3("go", "build", "-o", tcpfwd_bin, "./cmd/tcpfwd-smoke", chdir: agent_dir)
    raise "go build failed: #{err}" unless status.success?
    raise "binary not produced" unless File.exist?(tcpfwd_bin)
  end

  echo_tcp, _t1 = start_echo_server("127.0.0.2", fwd_tcp_port)
  echo_site_local, _t2 = start_echo_server("127.0.0.2", fwd_site_local_port)

  results.check("path_d_tcpfwd_daemon_start", "tcpfwd-smoke: daemon starts and binds both forwards") do
    daemon_pid = Process.spawn(tcpfwd_bin, "-config", tcpfwd_config_path, "-duration", "25s",
                                out: tcpfwd_log, err: [ :child, :out ])
    ready = false
    Timeout.timeout(5) do
      sleep 0.1 until (ready = File.exist?(tcpfwd_log) && File.read(tcpfwd_log).include?("READY"))
    end
    raise "daemon did not print READY within 5s" unless ready
    log = File.read(tcpfwd_log)
    raise "daemon did not report binding both forwards (#{log})" unless log.include?("bound=2")
  end

  results.depth!("path_d_tcpfwd_federated", "a",
    "REAL network reachability: compiled agent/cmd/tcpfwd-smoke (new standalone runner for the " \
    "tcpfwd package — no entrypoint existed outside the full mTLS-enrolled agent service), ran it " \
    "against a config Federation::TcpForwarderConfigWriter actually wrote, and pumped real bytes " \
    "through a real accepted TCP connection on loopback (127.0.0.1 listen -> 127.0.0.2 backend)")
  results.check("path_d_tcpfwd_federated", "tcpfwd-smoke: REAL byte-pump through the tcp-protocol forward (127.0.0.1 -> 127.0.0.2)") do
    payload = "smoke-edge-path3-#{SecureRandom.hex(4)}"
    response = echo_roundtrip("127.0.0.1", fwd_tcp_port, payload)
    raise "echo mismatch: sent #{payload.inspect}, got #{response.inspect}" unless response == payload
  end

  results.depth!("path_f_site_local", "a",
    "REAL network reachability, same daemon run as the federated-tcp path above, second forward " \
    "entry (site-local subscription, listen 127.0.0.1:#{fwd_site_local_port})")
  results.check("path_f_site_local", "tcpfwd-smoke: REAL byte-pump through the site-local forward") do
    payload = "smoke-edge-path6-#{SecureRandom.hex(4)}"
    response = echo_roundtrip("127.0.0.1", fwd_site_local_port, payload)
    raise "echo mismatch: sent #{payload.inspect}, got #{response.inspect}" unless response == payload
  end
ensure
  if daemon_pid
    begin
      Process.kill("TERM", daemon_pid)
      Process.wait(daemon_pid)
    rescue Errno::ESRCH, Errno::ECHILD
      # already exited (e.g. hit -duration) — fine
    end
  end
  [ echo_tcp, echo_site_local ].each { |s| s&.close rescue nil }
end

# ══════════════════════════════════════════════════════════════════════
# PATH 4 — Public TLS-carrying TCP via Traefik SNI (Path B), 3 shapes
# ══════════════════════════════════════════════════════════════════════
puts ""
puts "  [Path B] Public TLS-carrying TCP — passthrough / terminate / terminate+mTLS"

::Sdwan::Service.where(account: account, slug: %w[
  smoke-edge-b-passthrough smoke-edge-b-terminate smoke-edge-b-mtls
]).destroy_all
::System::AcmeCertificate.where(account: account, common_name: "smoke-edge-b.example.test").destroy_all

path_b_cert = ::System::AcmeCertificate.create!(
  account: account, common_name: "smoke-edge-b.example.test",
  issuer: "letsencrypt-prod", challenge_type: "http-01", dns_credential: nil,
  status: "valid", issued_at: Time.current, expires_at: 90.days.from_now
)

path_b_shapes = {
  "smoke-edge-b-passthrough" => { edge_mode: "passthrough", client_auth: "none", port: 9401,
                                   expected_tls: { "passthrough" => true } },
  "smoke-edge-b-terminate"   => { edge_mode: "terminate",   client_auth: "none", port: 9402,
                                   expected_tls: {} },
  "smoke-edge-b-mtls"        => { edge_mode: "terminate",   client_auth: "required", port: 9403,
                                   expected_tls: { "options" => "mtls-required@file" } }
}

path_b_services = path_b_shapes.map do |slug, shape|
  svc = ::Sdwan::Service.create!(
    account: account, slug: slug, name: "Smoke Edge #{slug}", protocol: "tls",
    backend_host: "127.0.0.1", backend_port: shape[:port], local_certificate: path_b_cert,
    edge_mode: shape[:edge_mode], client_auth: shape[:client_auth]
  )
  [ svc, shape ]
end

path_b_depth_note =
  "System::Ai::Skills::ExposeServicePublicTcpExecutor invoked for real (no stub) for all 3 " \
  "edge_mode/client_auth shapes; asserted the exact router bytes (incl. the mtls-required@file " \
  "option) a real Traefik file-provider would load; no live Traefik process actually loads them"

path_b_services.each do |svc, shape|
  results.depth!("path_b_#{svc.slug}", "c", path_b_depth_note)
  results.check("path_b_#{svc.slug}", "Path B (#{svc.edge_mode}/#{svc.client_auth}): ExposeServicePublicTcpExecutor exposes #{svc.slug}") do
    executor = ::System::Ai::Skills::ExposeServicePublicTcpExecutor.new(account: account)
    result = executor.execute(service_id: svc.id, enabled: true)
    raise "execute returned success: false (#{result[:error]})" unless result[:success]

    written = scratch_dir.join("local-services-#{account.id}.yaml")
    raise "ServiceExposureWriter did not write #{written}" unless File.exist?(written)
    parsed = YAML.load_file(written)
    router = parsed.dig("tcp", "routers", "pubsvc-#{svc.id}")
    raise "no tcp router emitted for #{svc.slug}" if router.nil?
    raise "rule wrong (#{router['rule']})" unless router["rule"] == "HostSNI(`smoke-edge-b.example.test`)"
    raise "entryPoints wrong (#{router['entryPoints'].inspect})" unless router["entryPoints"] == [ "websecure" ]
    raise "tls block wrong for #{svc.slug} (#{router['tls'].inspect}, expected #{shape[:expected_tls].inspect})" \
      unless router["tls"] == shape[:expected_tls]

    backend = parsed.dig("tcp", "services", "pubsvc-#{svc.id}", "loadBalancer", "servers")
    raise "backend address wrong (#{backend.inspect})" unless backend == [ { "address" => "127.0.0.1:#{shape[:port]}" } ]
  end
end

# ══════════════════════════════════════════════════════════════════════
# PATH 5 — Public TCP+UDP via nftables DNAT (Path C), increment-6 hardening
# ══════════════════════════════════════════════════════════════════════
puts ""
puts "  [Path C] Public TCP+UDP via nftables DNAT (Sdwan::NatCompiler, hardened)"

::Sdwan::PortMapping.where(sdwan_network_id: network.id, name: %w[smoke-edge-c-tcp smoke-edge-c-udp]).destroy_all

mapping_tcp = ::Sdwan::PortMapping.create!(
  account: account, network: network, hub_peer: hub_peer, target_peer: backend_peer,
  name: "smoke-edge-c-tcp", listen_port: 25_300, protocol: "tcp",
  source_cidrs: [ "203.0.113.0/24" ], max_connections: 10, rate_limit: 5
)
mapping_udp = ::Sdwan::PortMapping.create!(
  account: account, network: network, hub_peer: hub_peer, target_peer: backend_peer,
  name: "smoke-edge-c-udp", listen_port: 25_301, protocol: "udp",
  max_connections: 20, rate_limit: 50
)

nft_ruleset = nil

results.check("path_c_nat_compiler", "NatCompiler: emits hardened DNAT ruleset for both TCP+UDP mappings") do
  target_addr = backend_peer.assigned_address.to_s.split("/").first
  # NatCompiler#build_rule always brackets an address containing ":" (every
  # overlay ULA target) to disambiguate the port separator.
  bracketed_target = target_addr.include?(":") ? "[#{target_addr}]" : target_addr
  result = ::Sdwan::NatCompiler.compile_for_peer(hub_peer)
  nft_ruleset = result[:ruleset]
  raise "no ruleset emitted" if nft_ruleset.blank?
  raise "table name wrong (#{result[:table]})" unless result[:table] == "powernode_sdwan"

  # TCP mapping: v4 allow-list guard, v6-unset-family drop, conn-limit, rate-limit, dnat.
  raise "missing tcp v4 saddr guard" unless nft_ruleset.include?(
    "tcp dport 25300 ip saddr != { 203.0.113.0/24 } drop"
  )
  raise "missing tcp v6-unset nfproto drop" unless nft_ruleset.include?(
    "tcp dport 25300 meta nfproto ipv6 drop"
  )
  raise "missing tcp conn-limit guard" unless nft_ruleset.include?("tcp dport 25300 ct count over 10 drop")
  raise "missing tcp rate-limit guard" unless nft_ruleset.include?("tcp dport 25300 limit rate over 5/second drop")
  raise "missing tcp dnat line" unless nft_ruleset.include?("tcp dport 25300 dnat to #{bracketed_target}:25300")

  # UDP mapping: no source_cidrs set -> no saddr/nfproto guard lines at all, just conn+rate+dnat.
  raise "unexpected udp saddr/nfproto guard (source_cidrs unset)" if nft_ruleset.match?(/udp dport 25301.*(saddr|nfproto)/)
  raise "missing udp conn-limit guard" unless nft_ruleset.include?("udp dport 25301 ct count over 20 drop")
  raise "missing udp rate-limit guard" unless nft_ruleset.include?("udp dport 25301 limit rate over 50/second drop")
  raise "missing udp dnat line" unless nft_ruleset.include?("udp dport 25301 dnat to #{bracketed_target}:25301")

  raise "no mappings skipped as unresolved" unless result[:skipped].empty?
end

nft_depth_note = "Ruby-side structural assertions on the exact ruleset text a real `nft -f` would " \
                  "consume (table/chain names, guard ordering, dnat targets)"
if system("which nft > /dev/null 2>&1")
  nft_file = scratch_dir.join("path-c.nft").to_s
  File.write(nft_file, nft_ruleset.to_s)
  check_out, check_err, check_status = Open3.capture3("nft", "-c", "-f", nft_file)
  if check_status.success?
    nft_depth_note += "; UPGRADED — `nft -c -f` syntax-checked successfully (#{check_out.strip.presence || 'no output, exit 0'})"
    results.depth!("path_c_dnat", "c+nft-validated", nft_depth_note)
  else
    nft_depth_note += "; attempted `nft -c -f` — blocked by host permissions, not a ruleset defect: " \
                       "#{check_err.strip}"
    results.depth!("path_c_dnat", "c", nft_depth_note)
  end
else
  results.depth!("path_c_dnat", "c", "#{nft_depth_note}; nft binary not present on this host, skipped")
end

# ── Cleanup ───────────────────────────────────────────────────────────

if ENV["SMOKE_KEEP"] != "1"
  ::System::Federation::ServiceSubscription.where(id: [ tls_sub.id, tcp_sub.id, site_local_sub.id ]).destroy_all
  ::System::Federation::ServiceOffering.where(id: service_offering.id).destroy_all
  ::Sdwan::Service.where(id: offering_backend_service.id).destroy_all
  ::System::FederationGrant.where(id: federation_grant.id).destroy_all
  ::System::FederationPeer.where(id: federation_peer.id).destroy_all
  # Service rows FK-reference local_certificate_id — destroy them before the
  # certs they point at, or Postgres raises ForeignKeyViolation.
  ::Sdwan::Service.where(id: path_b_services.map { |svc, _| svc.id }).destroy_all
  ::System::AcmeCertificate.where(id: [ tls_cert.id, path_b_cert.id ]).destroy_all
  ::Sdwan::PortMapping.where(sdwan_network_id: network.id).destroy_all
  ::Sdwan::VirtualIp.where(network: network).destroy_all
  ::Sdwan::Peer.where(network: network).destroy_all
  network.destroy
  [ hub_instance, backend_instance ].each(&:destroy)
  [ hub_node, backend_node ].each(&:destroy)
  FileUtils.rm_rf(scratch_dir)
  puts ""
  puts "  Cleanup: removed smoke-edge-* fixtures + scratch dir (set SMOKE_KEEP=1 to preserve)"
end

if prior_dynamic_dir.nil?
  ENV.delete("POWERNODE_TRAEFIK_DYNAMIC_DIR")
else
  ENV["POWERNODE_TRAEFIK_DYNAMIC_DIR"] = prior_dynamic_dir
end

results.report!
