# frozen_string_literal: true

# System extension — inference runtime module catalog seed (ollama).
#
# Creates the subscription-variety NodeModule that runs an ollama inference server
# on a GPU node, exposing an HTTP API (:11434) that other node instances consume
# over the SDWAN overlay (published via ServiceDiscoveryComposer, consumed via an
# ollama Ai::Provider). The agent-container workloads carry NO model/GPU — they
# call this shared backend, which is what makes high agent density feasible.
#
# Part of the AI/MCP workload substrate, L1 (shared GPU inference). See
# docs/design/ai-mcp-workload-substrate.md.
#
# Requires the `gpu-nvidia-runtime` module on the same node (the deploy
# orchestration, system_deploy_inference_server, assigns both). Idempotent.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/inference_runtime_module.rb')"

require "base64"

puts "\n  Seeding inference runtime module catalog (ollama)..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting inference runtime seed"
  return
end

encode_spec_lines = ->(*lines) { lines.map { |l| Base64.strict_encode64(l) } }

# ── Category ────────────────────────────────────────────────────────────────
# Position 80 — after Container Runtimes (70); an inference server depends on GPU
# userland (Accelerators, 65) + optionally a container runtime being in place.
inference_cat = System::NodeModuleCategory.find_or_initialize_by(
  account: account,
  name: "Inference Runtimes"
)
if inference_cat.new_record?
  inference_cat.assign_attributes(
    variety: "subscription",
    position: 80,
    enabled: true,
    public: true,
    description: "AI inference servers (ollama, vLLM, TGI) serving models over an " \
                 "HTTP API. Published cluster-wide via service discovery; consumed " \
                 "by agent/MCP instances as a shared backend."
  )
  inference_cat.save!
  puts "    ✓ Created NodeModuleCategory 'Inference Runtimes'"
else
  puts "    = Category 'Inference Runtimes' already present"
end

# ── Module ──────────────────────────────────────────────────────────────────
ollama_module = System::NodeModule.find_or_initialize_by(
  account: account,
  name: "inference-ollama"
)

description = <<~DESC.strip
  Ollama inference server. Serves models over HTTP on :11434 (the ollama API).
  Requires the `gpu-nvidia-runtime` module on the same node for GPU acceleration
  (the deploy orchestration assigns both); runs CPU-only if no GPU is present.

  Publication: `system_deploy_inference_server` selects a GPU node
  (system_find_node_with_gpu), assigns this + the GPU module, then
  service_discovery_compose publishes :11434 behind an SDWAN VIP + ServiceOffering,
  and points an ollama Ai::Provider at the VIP so platform agents AND other node
  instances consume it.

  Models live under `/var/lib/ollama/models` (persisted). Operators tune the
  default model / context / GPU layers via config["inference"].
DESC

attrs = {
  variety: "subscription",
  category: inference_cat,
  enabled: true,
  public: true,
  lock_spec: true,
  priority: 100,
  description: description
}

attrs[:package_spec] = encode_spec_lines.call("ollama")
attrs[:protected_spec] = encode_spec_lines.call(
  "+ /etc/ollama/", "+ /etc/ollama/*",
  "+ /var/lib/ollama/", "+ /var/lib/ollama/*"
)
# The inference contract the deploy orchestration + service discovery read:
#   api_port      → backend_port for service_discovery_compose / the Ai::Provider URL
#   runtime       → which inference server (ollama today; vllm/tgi later)
#   default_model → seeded/pulled model
#   vram_required_mb → scheduler hint (must fit the GPU node's gpu_memory_mb)
attrs[:config] = {
  "inference" => {
    "runtime"          => "ollama",
    "api_port"         => 11_434,
    "api_health_path"  => "/api/version",
    "default_model"    => "llama3.1:8b",
    "vram_required_mb"  => 6_144,
    "requires_module"  => "gpu-nvidia-runtime",
    "model_dir"        => "/var/lib/ollama/models"
  }
}

ollama_module.assign_attributes(attrs)
ollama_module.save!

if ollama_module.previously_new_record?
  puts "    ✓ Created NodeModule 'inference-ollama' (subscription, Inference Runtimes category)"
else
  puts "    = Module 'inference-ollama' already present (id=#{ollama_module.id})"
end

puts "  Done seeding inference runtime module (ollama)."
