# frozen_string_literal: true

# System extension — SDWAN overlay module catalog seed.
#
# Creates the single subscription-variety module that ships the SDWAN binaries
# (wireguard, wireguard-tools, nftables) plus its containing category. Runtime
# topology is delivered via /api/v1/system/node_api/config/sdwan — this module
# is intentionally *just* the binary install. No config-variety or
# instance-variety counterparts: per the SDWAN plan (Section F), runtime state
# does NOT flow through the rsync union-mount artifact pipeline.
#
# Idempotent. Re-running updates description but never duplicates rows.
#
# Slice 1 of the SDWAN plan (we-are-continuing-development-spicy-bear.md).
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/sdwan_overlay_module.rb')"

require "base64"

puts "\n  Seeding SDWAN overlay module catalog..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting SDWAN seed"
  return
end

# Encodes one rsync-glob line per element. NodeModule's *_spec columns are
# JSONB arrays of base64-encoded strings (see NodeModule SPEC_FIELDS docs).
encode_spec_lines = ->(*lines) { lines.map { |l| Base64.strict_encode64(l) } }

# ── Category ────────────────────────────────────────────────────────────────
# subscription-variety (priority offset 0). The triplet (config + instance
# siblings) is intentionally NOT created — SDWAN runtime topology doesn't
# need higher-priority union-mount overrides.
network_overlay_cat = System::NodeModuleCategory.find_or_initialize_by(
  account: account,
  name: "Network Overlay"
)
if network_overlay_cat.new_record?
  network_overlay_cat.assign_attributes(
    variety: "subscription",
    position: 60,         # places it between system-base (10) and userland (90+)
    enabled: true,
    public: true,
    description: "SDWAN/VPN overlay networking — WireGuard data plane + " \
                 "nftables enforcement, runtime topology delivered via the " \
                 "platform's SDWAN control plane."
  )
  network_overlay_cat.save!
  puts "    ✓ Created NodeModuleCategory 'Network Overlay'"
else
  puts "    = Category 'Network Overlay' already present"
end

# ── Module ──────────────────────────────────────────────────────────────────
sdwan_module = System::NodeModule.find_or_initialize_by(
  account: account,
  name: "sdwan-overlay"
)

description = <<~DESC.strip
  SDWAN overlay binary install. Ships wireguard-tools, wireguard (DKMS fallback
  for older kernels), and nftables. Runtime topology — peers, keys, AllowedIPs,
  firewall rules — is delivered to the on-node agent via
  /api/v1/system/node_api/config/sdwan on every heartbeat tick. This module is
  the binary install layer only; do NOT add per-network or per-instance
  override modules — the variety triplet does not apply to SDWAN.
DESC

attrs = {
  variety: "subscription",
  category: network_overlay_cat,
  enabled: true,
  public: true,
  lock_spec: true,
  priority: 100,
  description: description
}

# Spec fields are populated only on first create — we don't want to clobber
# operator-tuned values on re-seed. Subsequent revisions update via migrations
# or a deliberate admin action.
# Always reconcile package_spec + protected_spec so that adding the
# slice 9c FRR/iBGP requirements (or future package additions) reaches
# pre-existing modules from earlier slices. The encode_spec_lines call
# is deterministic — operators who pin a custom package list should fork
# the module rather than relying on this catalog seed to leave their
# spec untouched.
attrs[:package_spec] = encode_spec_lines.call(
  "wireguard",
  "wireguard-tools",
  "nftables",
  # Slice 9c — FRR (Free Range Routing) is the iBGP daemon for networks
  # with routing_protocol=ibgp. Agent's frr_applier writes to
  # /etc/frr/frr.conf and reloads FRR. Networks in static mode don't
  # enable FRR even when the package is installed (frr.service stays
  # masked or the agent simply never writes a config).
  "frr",
  "frr-pythontools"
)
# Claim /etc/wireguard/ + /etc/frr/ as sensitive — they hold per-peer
# private keys (WG) and BGP daemon config (which carries the AS topology
# of the entire account fabric). No other module's blob should ship
# anything inside them.
attrs[:protected_spec] = encode_spec_lines.call(
  "+ /etc/wireguard/", "+ /etc/wireguard/*",
  "+ /etc/frr/",       "+ /etc/frr/*"
)

sdwan_module.assign_attributes(attrs)
sdwan_module.save!

if sdwan_module.previously_new_record?
  puts "    ✓ Created NodeModule 'sdwan-overlay' (subscription, Network Overlay category)"
else
  puts "    = Module 'sdwan-overlay' already present (id=#{sdwan_module.id})"
end

puts "  Done seeding SDWAN overlay module."
