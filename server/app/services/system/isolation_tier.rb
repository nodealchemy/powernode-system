# frozen_string_literal: true

module System
  # AI/MCP workload substrate L0 — the isolation-tier seam.
  #
  # Isolation has two separable costs: the ABSTRACTION (cheap, painful to
  # retrofit) and the RUNTIMES (heavy, per-host infra). This module is the
  # abstraction: a first-class deployment dimension that every agent deployment
  # declares (even `native`), mapping a tier to a container runtime
  # (Docker `--runtime`) / Kubernetes `RuntimeClass`. The concrete runtimes
  # (gVisor's runsc, Kata/Firecracker microVMs) are provisioned per-host
  # incrementally; this seam lets deployments request a tier today and have the
  # runtime light up later without re-plumbing.
  #
  # Reuses the NodeInstance.config profile pattern: the resolved tier +
  # docker_runtime are recorded on the member so the on-node agent selects the
  # container runtime at deploy time.
  module IsolationTier
    DEFAULT = "native"

    # tier => { docker_runtime, k8s_runtime_class, strength, overhead, requires }
    # docker_runtime: the OCI runtime name to pass as Docker `--runtime`.
    # k8s_runtime_class: the Kubernetes RuntimeClass name (nil = cluster default).
    # requires: host components that must be present before the tier is usable.
    TIERS = {
      "native" => {
        docker_runtime: "runc", k8s_runtime_class: nil,
        strength: "process", overhead: "none", requires: []
      },
      "gvisor" => {
        docker_runtime: "runsc", k8s_runtime_class: "gvisor",
        strength: "userspace-kernel", overhead: "low", requires: %w[runsc]
      },
      "kata" => {
        docker_runtime: "kata-runtime", k8s_runtime_class: "kata",
        strength: "microvm", overhead: "medium", requires: %w[kata-runtime vmm]
      },
      "firecracker" => {
        docker_runtime: "kata-fc", k8s_runtime_class: "kata-fc",
        strength: "microvm", overhead: "medium", requires: %w[firecracker kata-runtime]
      },
      "vm" => {
        # Not a container runtime — a full guest VM via the NodeInstance VM
        # provisioning path. Carried here so the dimension is total.
        docker_runtime: nil, k8s_runtime_class: nil,
        strength: "full-vm", overhead: "high", requires: %w[hypervisor]
      }
    }.freeze

    module_function

    def names
      TIERS.keys
    end

    def valid?(tier)
      TIERS.key?(tier.to_s)
    end

    # Normalize to a known tier; blank -> DEFAULT. Raises on an unknown tier.
    def normalize(tier)
      t = tier.to_s.strip
      t = DEFAULT if t.empty?
      raise ArgumentError, "unknown isolation_tier '#{tier}' (valid: #{names.join(', ')})" unless valid?(t)
      t
    end

    def descriptor(tier)
      TIERS.fetch(normalize(tier))
    end

    def docker_runtime(tier)
      descriptor(tier)[:docker_runtime]
    end

    def k8s_runtime_class(tier)
      descriptor(tier)[:k8s_runtime_class]
    end

    # Resolved, string-keyed isolation profile to record on a deployment/member
    # so the on-node agent can select the container runtime at deploy time.
    def profile(tier)
      t = normalize(tier)
      d = TIERS.fetch(t)
      {
        "tier" => t,
        "docker_runtime" => d[:docker_runtime],
        "k8s_runtime_class" => d[:k8s_runtime_class],
        "strength" => d[:strength]
      }
    end

    # Discovery payload: every tier + its mapping + host requirements.
    def catalog
      TIERS.map do |name, d|
        {
          "tier" => name,
          "docker_runtime" => d[:docker_runtime],
          "k8s_runtime_class" => d[:k8s_runtime_class],
          "strength" => d[:strength],
          "overhead" => d[:overhead],
          "requires" => d[:requires],
          "default" => name == DEFAULT
        }
      end
    end

    # Does this tier need a real OCI runtime binary provisioned on the host?
    # native -> runc (built into dockerd) and vm -> full guest (no container
    # runtime) need nothing extra; gvisor/kata/firecracker do.
    def requires_runtime?(tier)
      return false unless valid?(tier)
      rt = TIERS.fetch(tier.to_s)[:docker_runtime]
      rt.present? && rt != "runc"
    end

    # The isolation runtimes a NODE must provision, derived from the instance's
    # recorded isolation profile (NodeInstance.config["isolation"]). Returns the
    # tier names that need a runtime (e.g. ["gvisor"]) — the agent feeds these to
    # the dockerd reconcile's RequestedRuntimes.
    def required_runtimes_for(instance)
      cfg = instance&.config
      iso = cfg.is_a?(Hash) ? cfg["isolation"] : nil
      tier = iso.is_a?(Hash) ? iso["tier"].to_s : ""
      requires_runtime?(tier) ? [tier] : []
    end
  end
end
