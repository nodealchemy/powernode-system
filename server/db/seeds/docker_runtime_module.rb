# frozen_string_literal: true

# System extension — Docker runtime module catalog seed.
#
# Creates the subscription-variety NodeModule that ships the Docker Engine
# binary stack (docker-ce, docker-ce-cli, containerd, buildx, compose
# plugin) plus the "Container Runtimes" category. Modeled on the
# `sdwan-overlay` precedent — runtime config (`/etc/docker/daemon.json`,
# TLS material, listen address) is delivered via a separate config-variety
# module that operators layer per-instance rather than baked into this
# subscription module.
#
# Idempotent. Re-running updates `description` + reconciles
# `package_spec`/`protected_spec` but never duplicates rows.
#
# Phase B (Docker + K8s plan, slice 1).
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/docker_runtime_module.rb')"

require "base64"

puts "\n  Seeding Docker runtime module catalog..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting Docker runtime seed"
  return
end

# JSONB array of base64-encoded rsync-glob lines (NodeModule SPEC_FIELDS contract).
encode_spec_lines = ->(*lines) { lines.map { |l| Base64.strict_encode64(l) } }

# ── Category ────────────────────────────────────────────────────────────────
# subscription-variety priority offset 0 — placed at position 70 between
# Network Overlay (60) and userland (90+) so a node bringing up Docker
# already has SDWAN routing in place when the daemon binds to its overlay
# /128.
container_runtimes_cat = System::NodeModuleCategory.find_or_initialize_by(
  account: account,
  name: "Container Runtimes"
)
if container_runtimes_cat.new_record?
  container_runtimes_cat.assign_attributes(
    variety: "subscription",
    position: 70,
    enabled: true,
    public: true,
    description: "Docker, K3s, and kubeadm container runtimes. " \
                 "Daemon configuration (TLS, listen address) ships via " \
                 "a sibling config-variety module per instance."
  )
  container_runtimes_cat.save!
  puts "    ✓ Created NodeModuleCategory 'Container Runtimes'"
else
  puts "    = Category 'Container Runtimes' already present"
end

# ── Module ──────────────────────────────────────────────────────────────────
docker_module = System::NodeModule.find_or_initialize_by(
  account: account,
  name: "docker-engine"
)

description = <<~DESC.strip
  Docker Engine binary install — docker-ce, docker-ce-cli, containerd.io,
  docker-buildx-plugin, docker-compose-plugin. Daemon configuration
  (`/etc/docker/daemon.json`, TLS server keypair, listen address on the
  SDWAN overlay /128) is delivered via the sibling `docker-engine-config`
  config-variety module per instance — do NOT bake instance-specific
  values into this subscription module.

  Persistence: dockerd writes to `/var/lib/docker/`, which lives in
  `/persist/var/lib/docker/` via the agent's EnsurePersistentVar bind
  mount. Image cache + container state survive reboots when the
  Node has `tmpfs_store: false` (the default).

  Auto-registration: when this module is assigned to a NodeInstance,
  `System::DockerDaemonProvisionerService` creates a managed
  `Devops::DockerHost` row pointing at the instance's overlay /128.
  Platform → daemon API calls flow over the encrypted SDWAN overlay
  with mTLS — daemon never binds to a public socket.
DESC

attrs = {
  variety: "subscription",
  category: container_runtimes_cat,
  enabled: true,
  public: true,
  lock_spec: true,
  priority: 100,
  description: description
}

# Always reconcile package_spec + protected_spec so future package
# additions reach existing modules. Operators who want to pin a custom
# package list should fork the module via NodeModule.duplicate rather
# than editing the seed.
attrs[:package_spec] = encode_spec_lines.call(
  "docker-ce",
  "docker-ce-cli",
  "containerd.io",
  "docker-buildx-plugin",
  "docker-compose-plugin"
)
# `/etc/docker/` holds daemon.json + tls/{ca,cert,key}.pem; sensitive.
# `/var/lib/docker/` holds the entire image graph + container state +
# overlay2 layers; not "sensitive" in the secret-leakage sense, but
# claiming it stops other modules from accidentally writing artifacts
# under it (e.g. a userland module dropping a config file there during
# rsync application).
attrs[:protected_spec] = encode_spec_lines.call(
  "+ /etc/docker/", "+ /etc/docker/*",
  "+ /var/lib/docker/", "+ /var/lib/docker/*"
)

docker_module.assign_attributes(attrs)
docker_module.save!

if docker_module.previously_new_record?
  puts "    ✓ Created NodeModule 'docker-engine' (subscription, Container Runtimes category)"
else
  puts "    = Module 'docker-engine' already present (id=#{docker_module.id})"
end

puts "  Done seeding Docker runtime module."
