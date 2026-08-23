# frozen_string_literal: true

# System extension — SDWAN IPFIX flow-exporter module catalog seed.
# IMP-5a018031cc29.
#
# WHY THIS EXISTS
# ---------------
# The IPFIX pipe was complete on the CONSUMING side and had no producer:
#
#   * Sdwan::TopologyCompiler.ipfix_payload_for stamps an `ipfix:` exporter
#     block on every ovs-kind HostBridge as soon as the account holds one
#     active Sdwan::IpfixCollector, and the agent's OvsBridgeApplier wires
#     OVS's native exporter to it.
#   * Sdwan::IpfixIngestService + the flow_samples endpoint accept decoded
#     batches, Sdwan::FlowSampleRetentionService ages them out, and
#     System::Fleet::Sensors::SdwanServiceHealthSensor reads them.
#
# Between the two sits a sidecar that decodes the IPFIX wire format and POSTs
# JSON — named in IpfixIngestService's own header and configured, as a COMMENT
# ONLY, in Api::V1::System::Sdwan::FlowSamplesController. Nothing in the repo
# deployed it: no module seed, no agent component, no provisioner. So
# `create_ipfix_collector` registered an endpoint that nothing exported to, and
# the sensor conceded as much ("collectors are optional operator-run sidecars,
# so that is most of them").
#
# WHY A MODULE AND NOT THE AGENT
# ------------------------------
# The exporter is an ordinary userland daemon: a package, a config file and a
# systemd unit. That is exactly what the NodeModule lane ships, and it already
# carries canary / promote / rollback, which an agent binary change does not.
# It also mirrors `sdwan_overlay_module.rb`, the binary-install seed for the
# WireGuard data plane, so the two halves of the SDWAN host story are delivered
# the same way. Folding an IPFIX decoder into the Go agent would put a binary
# wire-format parser on the boot-critical path for a purely observational
# feature — the worst trade available.
#
# WHAT THIS SEED DOES AND DOES NOT DO
# -----------------------------------
# It defines the CATALOG ROW: name, category, packages, protected paths and the
# service the module runs. The module's rootfs blob — the vector binary and its
# TOML — is produced by the module build pipeline from the module's own source;
# this seed never builds or publishes anything (see the runbook note below).
#
# It does NOT ship an ingest credential, and must not: the exporter
# authenticates to the flow_samples endpoint with a bearer token carrying
# `system.sdwan.ipfix.ingest`, and a token in a seed would be a secret in
# source. The operator provisions it. Until it is provisioned the module is
# deployed and silent — which Sdwan::FlowExportCoverage reports as `stalled`,
# NOT as "reporting nothing".
#
# OPERATOR: BUILD + PUBLISH
# -------------------------
# This seed lands the definition only. Building and publishing the artifact is
# a separate, deliberate operator action, because publishing AUTO-PROMOTES on
# this platform and a dispatched batch cannot be recalled:
#
#   1. seed the catalog row (idempotent, no build):
#        cd server && bundle exec rails runner \
#          "load Rails.root.join('../extensions/system/server/db/seeds/sdwan_flow_exporter_module.rb')"
#   2. author/refresh the module source (vector.toml + manifest.yaml) in the
#      module's own repo, then dispatch ONE build for it:
#        platform.system_dispatch_module_build_batch (module: sdwan-flow-exporter)
#   3. canary it, verify flow_samples arrive, then promote:
#        platform.system_module_mark_canary → platform.system_promote_module_version
#   4. attach the ingest credential on the canary host before promoting.
#
# Assignment to hosts is NOT an operator step: Sdwan::FlowExporterDeployer runs
# from Sdwan::Executors::CreateIpfixCollector and attaches this module where the
# collector target resolves, reporting the hosts that cannot export at all.
#
# Until step 2 completes the module has no published version, so nothing runs
# on the host even though the assignment exists. Sdwan::FlowExportCoverage
# reports exactly that as `unbuilt` — deliberately NOT as `stalled`, which is
# reserved for a producer that was working and stopped.
#
# TWO SEED PROPERTIES WORTH KNOWING BEFORE RE-RUNNING
# ---------------------------------------------------
#   * It seeds into `Account.first`, matching sdwan_overlay_module.rb and the
#     single-account (core mode) install this platform targets. On a
#     multi-account deployment every other account gets
#     `module_present: false` from the deployer — a loud refusal naming this
#     file, not silence — until the seed is run for that account too.
#   * Re-running RECONCILES the spec fields, so it will re-enable a module an
#     operator disabled and overwrite a hand-tuned package/priority. Same
#     contract as sdwan_overlay_module.rb; operators pinning a custom package
#     list should fork the module rather than edit this row. Nothing on the
#     collector-create path invokes this seed — Sdwan::FlowExporterDeployer
#     only READS the catalog row — so an operator edit is never clobbered
#     behind their back.

require "base64"

puts "\n  Seeding SDWAN IPFIX flow-exporter module catalog..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting flow-exporter seed"
  return
end

encode_spec_lines = ->(*lines) { lines.map { |l| Base64.strict_encode64(l) } }

# ── Category ────────────────────────────────────────────────────────────────
# Same category as sdwan-overlay: this is the observational half of the same
# host-side overlay story. find_or_initialize_by so seed order does not matter.
network_overlay_cat = System::NodeModuleCategory.find_or_initialize_by(
  account: account,
  name: "Network Overlay"
)
if network_overlay_cat.new_record?
  network_overlay_cat.assign_attributes(
    variety: "subscription",
    position: 60,
    enabled: true,
    public: true,
    description: "SDWAN/VPN overlay networking — WireGuard data plane + " \
                 "nftables enforcement, runtime topology delivered via the " \
                 "platform's SDWAN control plane."
  )
  network_overlay_cat.save!
  puts "    ✓ Created NodeModuleCategory 'Network Overlay'"
end

# ── Module ──────────────────────────────────────────────────────────────────
module_name = "sdwan-flow-exporter"
service_name = "sdwan-flow-exporter"

exporter = System::NodeModule.find_or_initialize_by(account: account, name: module_name)

description = <<~DESC.strip
  SDWAN IPFIX flow exporter. Runs vector as a host-local IPFIX collector: it
  decodes the flow records OVS exports (per Sdwan::IpfixCollector's target
  endpoint) and POSTs decoded JSON batches to the platform's
  /api/v1/system/sdwan/ipfix_collectors/:id/flow_samples ingest endpoint.

  Only heavyweight (OVS) hosts can produce IPFIX — a Linux bridge has no
  exporter — so this module is attached to OVS-capable nodes only.
  Sdwan::FlowExportCoverage reports lightweight hosts as `unsupported`, never
  as configured-and-silent.

  The ingest bearer token is NOT shipped with this module; the operator
  provisions it alongside the module's /etc/vector/sdwan-flow-exporter.toml.
  Attachment to the right hosts IS automatic — Sdwan::FlowExporterDeployer
  runs from the collector-create path.
DESC

manifest = {
  "schema_version" => 1,
  "name" => module_name,
  "display_name" => "SDWAN IPFIX flow exporter",
  "description" => "Host-local IPFIX decoder that forwards OVS flow records to the platform.",
  "license" => "MIT",
  "package_spec" => [ "vector" ],
  "protected_spec" => [ "/etc/vector/**" ],
  "dependencies" => {
    "requires" => [ "powernode/system-base@^1.0" ],
    "provides" => [ "sdwan.flow-export", "telemetry.ipfix-collector" ]
  },
  "services" => [
    {
      "name" => service_name,
      "start_command" => "/usr/bin/vector --config /etc/vector/sdwan-flow-exporter.toml",
      "restart_policy" => "always",
      "user" => "root",
      "exposed_ports" => [ { "port" => 4739, "protocol" => "udp", "name" => "ipfix" } ]
    }
  ],
  "reboot_required" => false,
  "skills" => []
}

attrs = {
  variety: "subscription",
  category: network_overlay_cat,
  enabled: true,
  public: true,
  lock_spec: true,
  # Above sdwan-overlay (100) so the exporter's config wins over anything the
  # overlay module might ship into /etc/vector — it does not today, and this
  # keeps it that way if it ever does.
  priority: 110,
  description: description,
  manifest_yaml: manifest.to_yaml,
  # vector reads only /etc/vector; claim it so no other module's blob can ship
  # a competing exporter config (which would silently repoint flow telemetry).
  package_spec: encode_spec_lines.call("vector"),
  protected_spec: encode_spec_lines.call("+ /etc/vector/", "+ /etc/vector/*")
}

exporter.assign_attributes(attrs)
exporter.save!

if exporter.previously_new_record?
  puts "    ✓ Created NodeModule '#{module_name}' (subscription, Network Overlay category)"
else
  puts "    = Module '#{module_name}' already present (id=#{exporter.id})"
end

# ── Declared service ────────────────────────────────────────────────────────
# A module with no services never restarts anything on the host — an inert
# deploy story that looks exactly like a working one. Declare the unit here so
# the platform-side row exists the moment the catalog row does, matching the
# manifest above (the on-node agent reads manifest_yaml directly).
service = System::ModuleService.find_or_initialize_by(node_module: exporter, name: service_name)
service.assign_attributes(
  account_id: account.id,
  start_command: "/usr/bin/vector --config /etc/vector/sdwan-flow-exporter.toml",
  restart_policy: "always",
  system_user: "root",
  exposed_ports: [ { "port" => 4739, "protocol" => "udp", "name" => "ipfix" } ]
)
service.save!

puts "    ✓ Declared service '#{service_name}' on '#{module_name}'"
puts "  Done seeding SDWAN IPFIX flow-exporter module."
