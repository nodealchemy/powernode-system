# frozen_string_literal: true

# System extension — K3s NodeModule catalog seed (Phase 2 Slice 2).
#
# Creates the two subscription-variety modules that ship the K3s
# binaries plus their containing category. Mirrors the
# docker_runtime_module.rb / sdwan_overlay_module.rb shape — package
# install layer only; runtime topology (cluster identity, kubeconfig,
# join tokens) is delivered via a separate config-variety module per
# instance plus the runtime/handshake endpoint.
#
# Two modules:
#   k3s-server  — control plane: kube-apiserver, controller-manager,
#                 scheduler, embedded etcd (single-node) or external
#                 etcd (multi-node HA, Phase 3+). systemd unit:
#                 k3s.service.
#   k3s-agent   — worker: kubelet + containerd + flannel/cilium CNI.
#                 systemd unit: k3s-agent.service. Joins via
#                 K3S_URL + K3S_TOKEN env vars sourced from the cluster
#                 row's encrypted_agent_token.
#
# Phase 3 will add kubeadm-controlplane + kubeadm-worker modules
# alongside these (NOT replacing — operators choose at cluster create
# time which flavor to use).
#
# Idempotent. Re-running updates description + reconciles
# package_spec/protected_spec but never duplicates rows.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/k3s_modules.rb')"

require "base64"

puts "\n  Seeding K3s module catalog..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting K3s module seed"
  return
end

encode_spec_lines = ->(*lines) { lines.map { |l| Base64.strict_encode64(l) } }

# ── Category ────────────────────────────────────────────────────────
# Reuse the 'Container Runtimes' category established by the
# docker_runtime_module seed. K3s shares the same conceptual home —
# both are container runtime stacks delivered via subscription
# variety, both bind their daemon API to the SDWAN overlay.
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

# ── k3s-server module ───────────────────────────────────────────────
k3s_server = System::NodeModule.find_or_initialize_by(
  account: account,
  name: "k3s-server"
)

server_description = <<~DESC.strip
  K3s server (control plane) — kube-apiserver, controller-manager,
  scheduler, embedded etcd. Provided by the upstream Rancher k3s
  package. Single-node clusters work standalone; multi-server HA
  joins additional k3s-server NodeInstances against the bootstrap
  server's K3S_TOKEN.

  Persistence: k3s state lives under `/var/lib/rancher/k3s/`, which
  resolves into `/persist/var/lib/rancher/k3s/` via the agent's
  EnsurePersistentVar bind mount. etcd database, server certs,
  kubeconfig + tokens all survive reboots when the Node has
  `tmpfs_store: false` (the default).

  Auto-registration: when this module is assigned to a NodeInstance,
  the agent's k3s reconciler installs k3s, captures the kubeconfig +
  server-join token, posts them via runtime/handshake
  (runtime: 'k3s_server'). Platform creates a managed
  Devops::KubernetesCluster row pointing at the instance's overlay
  /128 on port 6443.

  Daemon API binds to the SDWAN overlay only — no public 6443
  exposure. Operators reach the cluster via the platform's tunneled
  kubectl proxy.
DESC

k3s_server.assign_attributes(
  variety: "subscription",
  category: container_runtimes_cat,
  enabled: true,
  public: true,
  lock_spec: true,
  priority: 100,
  description: server_description,
  package_spec: encode_spec_lines.call(
    # k3s ships as a single binary via the official Rancher repo. The
    # `curl | sh` install script writes /usr/local/bin/k3s + a systemd
    # unit; we shell out to that script in the reconciler. The package
    # itself is "k3s" only — containerd + runc are bundled inside the
    # k3s binary.
    "k3s"
  ),
  # Claim the k3s state directories — they hold etcd data, server
  # certs, and the cluster join token. No other module's blob should
  # be writing into these paths.
  protected_spec: encode_spec_lines.call(
    "+ /etc/rancher/k3s/", "+ /etc/rancher/k3s/*",
    "+ /var/lib/rancher/k3s/", "+ /var/lib/rancher/k3s/*"
  )
)
k3s_server.save!
puts(k3s_server.previously_new_record? \
  ? "    ✓ Created NodeModule 'k3s-server' (subscription, Container Runtimes)" \
  : "    = Module 'k3s-server' already present (id=#{k3s_server.id[0, 8]})")

# ── k3s-agent module ────────────────────────────────────────────────
k3s_agent = System::NodeModule.find_or_initialize_by(
  account: account,
  name: "k3s-agent"
)

agent_description = <<~DESC.strip
  K3s agent (worker) — kubelet + containerd + CNI. Joins an existing
  K3s cluster via K3S_URL (the cluster's api_endpoint) + K3S_TOKEN
  (cluster's agent-join token). One k3s-agent per worker
  NodeInstance.

  Persistence: kubelet state under `/var/lib/rancher/k3s/agent/`
  + containerd state under `/var/lib/containerd/` both resolve into
  `/persist/var/...` for survival across reboots.

  Auto-registration: assigning this module to a NodeInstance whose
  Node has at least one Devops::KubernetesCluster (managed) triggers
  the agent's k3s reconciler to fetch the join token from the cluster
  row's encrypted_agent_token, install k3s in agent mode, and
  register a Devops::KubernetesNode entry with role='agent'.

  IMPORTANT: assigning k3s-agent without first having a server
  available is a no-op — the reconciler waits until a cluster exists
  in the same account.
DESC

k3s_agent.assign_attributes(
  variety: "subscription",
  category: container_runtimes_cat,
  enabled: true,
  public: true,
  lock_spec: true,
  priority: 100,
  description: agent_description,
  package_spec: encode_spec_lines.call(
    "k3s"
  ),
  protected_spec: encode_spec_lines.call(
    "+ /etc/rancher/k3s/", "+ /etc/rancher/k3s/*",
    "+ /var/lib/rancher/k3s/", "+ /var/lib/rancher/k3s/*",
    "+ /var/lib/containerd/", "+ /var/lib/containerd/*"
  )
)
k3s_agent.save!
puts(k3s_agent.previously_new_record? \
  ? "    ✓ Created NodeModule 'k3s-agent' (subscription, Container Runtimes)" \
  : "    = Module 'k3s-agent' already present (id=#{k3s_agent.id[0, 8]})")

puts "  Done seeding K3s modules."
