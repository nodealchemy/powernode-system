# frozen_string_literal: true

# System extension — GPU/accelerator runtime module catalog seed.
#
# Creates the subscription-variety NodeModule that enables NVIDIA GPU access on a
# node — the host NVIDIA driver + CUDA userland + nvidia-container-toolkit — so the
# GPU is usable by BOTH native processes and OCI containers. This is the supported,
# host-driver-shared model (no vGPU/passthrough reconfiguration); it is exactly how
# a server like DNA already serves a GPU to multiple containers.
#
# Part of the AI/MCP workload substrate, L1 (shared GPU inference). See
# docs/design/ai-mcp-workload-substrate.md.
#
# Idempotent. Re-running reconciles description/package_spec/config; never dupes.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/gpu_nvidia_runtime_module.rb')"

require "base64"

puts "\n  Seeding GPU/accelerator runtime module catalog..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting GPU runtime seed"
  return
end

# JSONB array of base64-encoded rsync-glob lines (NodeModule SPEC_FIELDS contract).
encode_spec_lines = ->(*lines) { lines.map { |l| Base64.strict_encode64(l) } }

# ── Category ────────────────────────────────────────────────────────────────
# Position 65 — between Network Overlay (60) and Container Runtimes (70), so GPU
# userland + the container toolkit are in place before a runtime/inference module
# binds and asks dockerd for the "nvidia" runtime.
accel_cat = System::NodeModuleCategory.find_or_initialize_by(
  account: account,
  name: "Accelerators"
)
if accel_cat.new_record?
  accel_cat.assign_attributes(
    variety: "subscription",
    position: 65,
    enabled: true,
    public: true,
    description: "GPU/accelerator drivers + container runtime hooks (NVIDIA CUDA, " \
                 "nvidia-container-toolkit). Enables GPU access for containerized " \
                 "and native inference workloads."
  )
  accel_cat.save!
  puts "    ✓ Created NodeModuleCategory 'Accelerators'"
else
  puts "    = Category 'Accelerators' already present"
end

# ── Module ──────────────────────────────────────────────────────────────────
gpu_module = System::NodeModule.find_or_initialize_by(
  account: account,
  name: "gpu-nvidia-runtime"
)

description = <<~DESC.strip
  NVIDIA GPU enablement — host driver + CUDA userland + nvidia-container-toolkit,
  so the node's GPU is usable by native processes AND OCI containers (the
  supported, host-driver-shared model — NO vGPU/passthrough reconfiguration).

  After assignment, the on-node agent registers the "nvidia" container runtime
  with dockerd and reports the node's GPU inventory into
  `NodeInstance.config["gpu"]` (`{count, type, memory_mb}`), which
  `system_find_node_with_gpu` and the inference scheduler consume.

  Persistence: driver/toolkit install is system-level; CUDA caches under
  `/usr/local/cuda`. Sensitive runtime config under `/etc/nvidia*` is claimed via
  protected_spec so userland modules can't write into it.

  Sharing model: one GPU is shared across containers via the host driver
  (driver time-slicing / MPS) — many lightweight inference/agent containers on one
  server, no per-container GPU. This is the density model the substrate relies on.
DESC

attrs = {
  variety: "subscription",
  category: accel_cat,
  enabled: true,
  public: true,
  lock_spec: true,
  priority: 100,
  description: description
}

# Illustrative package set (the real artifact is built via CI); the driver version
# is operator-tunable via config["gpu_runtime"]["driver_package"].
attrs[:package_spec] = encode_spec_lines.call(
  "nvidia-driver-server",
  "nvidia-container-toolkit",
  "cuda-toolkit"
)
attrs[:protected_spec] = encode_spec_lines.call(
  "+ /etc/nvidia/", "+ /etc/nvidia/*",
  "+ /etc/nvidia-container-runtime/", "+ /etc/nvidia-container-runtime/*",
  "+ /usr/local/cuda/", "+ /usr/local/cuda/*"
)
attrs[:config] = {
  "gpu_runtime" => {
    "vendor"             => "nvidia",
    "driver_package"     => "nvidia-driver-server", # operator-overridable per node
    "container_runtime"  => "nvidia",               # registers a dockerd "nvidia" runtime
    "capabilities"       => %w[compute utility],
    "reports_gpu_inventory" => true                 # agent fills NodeInstance.config["gpu"] from nvidia-smi
  }
}

gpu_module.assign_attributes(attrs)
gpu_module.save!

if gpu_module.previously_new_record?
  puts "    ✓ Created NodeModule 'gpu-nvidia-runtime' (subscription, Accelerators category)"
else
  puts "    = Module 'gpu-nvidia-runtime' already present (id=#{gpu_module.id})"
end

puts "  Done seeding GPU/accelerator runtime module."
