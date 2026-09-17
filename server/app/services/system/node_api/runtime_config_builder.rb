# frozen_string_literal: true

module System
  module NodeApi
    # Builds the per-runtime config payload returned by
    # Api::V1::System::NodeApi::RuntimeController#runtime_config
    # (GET /api/v1/system/node_api/runtime/:runtime/config).
    #
    # Extracted verbatim from the controller to keep it under the size
    # budget. One builder method per runtime; #build dispatches on the
    # runtime enum and returns the `data:` hash the controller renders.
    # The controller still owns the allow-list / module-assigned guards.
    class RuntimeConfigBuilder
      def self.build(runtime:, instance:)
        new(runtime: runtime, instance: instance).build
      end

      def initialize(runtime:, instance:)
        @runtime = runtime
        @instance = instance
      end

      def build
        base =
          case @runtime
          when "docker"
            docker_config
          when "k3s_server"
            k3s_server_config
          when "k3s_agent"
            k3s_agent_config
          else
            empty_config
          end
        # Boot-image identity is runtime-independent — surface the promoted
        # disk image for every runtime so the agent can compare it against the
        # git_sha it actually booted from (campaign 019f505f). Merged here (not
        # per-runtime) so a future dedicated boot-image fetch has one source.
        boot_image = boot_image_block
        boot_image.present? ? base.merge(boot_image: boot_image) : base
      end

      private

      # Promoted (currently-published) disk image identity for this node's
      # platform — Node → NodeTemplate → NodePlatform.disk_image_* columns set
      # by the DiskImage::PromotePublication executor. Empty when the platform
      # has no promoted image yet (or the links aren't populated) so the agent's
      # zero-value decode stays clean and the key is simply omitted.
      def boot_image_block
        platform = @instance.node&.node_platform
        return {} if platform&.disk_image_git_sha.blank?

        {
          git_sha: platform.disk_image_git_sha,
          oci_ref: platform.disk_image_oci_ref,
          sha256:  platform.disk_image_sha256
        }
      end

      def docker_config
        overrides = ::System::DockerDaemonOverridesResolver.resolve(
          node_instance: @instance
        )
        {
          runtime: @runtime,
          daemon_overrides: overrides,
          # ETag-style content hash — agent can short-circuit
          # on-disk writes when nothing changed. Phase 2 may add
          # If-None-Match handling for true 304 responses; for
          # now agents handle the diff client-side.
          content_hash: ::Digest::SHA256.hexdigest(overrides.to_json)
        }
      end

      # Phase O4 — K3s server bootstrap config. Currently carries
      # cni_plugin (flannel | ovn_kubernetes) so k3sd knows
      # whether to pass --flannel-backend=none --disable-network-policy
      # at server install time. Future K3s knobs (cluster-cidr,
      # service-cidr, etc.) belong in the same bootstrap_config
      # envelope.
      def k3s_server_config
        bootstrap_config = k3s_server_bootstrap_config(@instance)
        {
          runtime: @runtime,
          bootstrap_config: bootstrap_config,
          content_hash: ::Digest::SHA256.hexdigest(bootstrap_config.to_json)
        }
      end

      # IMP-a5f236e8cc56 — k3s_agent runtime config. Surfaces the
      # operator-set target_cluster_id from the calling node's ENABLED
      # k3s-agent NodeModuleAssignment#config, but only when that id
      # names a Devops::KubernetesCluster in the node's OWN account
      # whose status is not "error". Every other shape — no
      # assignment, a disabled one, a missing/blank config key, an
      # id naming a foreign-account cluster, or an error-state
      # cluster — surfaces an empty string rather than raising or
      # guessing, so join_request! keeps doing its own validation
      # (single-cluster auto-select, or the AmbiguousClusterError /
      # NoClusterAvailableError refusal) instead of this endpoint
      # vouching for an id it cannot back.
      #
      # Consulted ONLY on a fresh join (phase=join_request, driven by
      # k3sd.AgentManager.TargetClusterID). An already-joined worker's
      # membership is cached client-side
      # (AgentManager.state.joinedClusterID) and is never re-resolved
      # from this value, so changing target_cluster_id after a join
      # does not relocate it — only a fresh join (cleanup + reinstall)
      # consults it.
      def k3s_agent_config
        target_cluster_id = resolved_target_cluster_id
        {
          runtime: @runtime,
          target_cluster_id: target_cluster_id,
          content_hash: ::Digest::SHA256.hexdigest({ target_cluster_id: target_cluster_id }.to_json)
        }
      end

      def resolved_target_cluster_id
        node = @instance.node
        return "" if node.blank?

        # Deterministic winner if a node somehow carries more than one
        # NodeModule row named "k3s-agent" (module_assigned? in the
        # controller has the same by-name-only shape and doesn't need to
        # pick one — it only checks existence). Highest `priority` wins,
        # matching NodeModuleAssignment.by_priority and
        # DockerDaemonOverridesResolver's own priority-ordered resolution;
        # ties broken by the most-recently-created row (UUIDv7 ids sort by
        # creation time) so the result never depends on unspecified DB
        # ordering.
        assignment = node.node_module_assignments
                         .enabled
                         .joins(:node_module)
                         .where(system_node_modules: { name: "k3s-agent" })
                         .order(priority: :desc, id: :desc)
                         .first
        return "" if assignment.blank?

        candidate = assignment.config.is_a?(Hash) ? assignment.config["target_cluster_id"] : nil
        return "" if candidate.blank?

        cluster = ::Devops::KubernetesCluster.find_by(id: candidate, account_id: node.account_id)
        return "" if cluster.blank? || cluster.status == "error"

        cluster.id
      end

      # kubeadm runtime config delivery is a follow-up (k3s_agent got
      # its own handler above, IMP-a5f236e8cc56); return an empty
      # payload so the agent doesn't error out when probing newer
      # endpoints from older runtimes.
      def empty_config
        {
          runtime: @runtime,
          daemon_overrides: {},
          content_hash: ::Digest::SHA256.hexdigest("{}")
        }
      end

      # Phase O4 — derive the k3s_server bootstrap_config payload.
      # Looks up the cluster the host belongs to (via
      # Devops::KubernetesNode) and pulls cni_plugin from there. When
      # the host has no cluster yet — true for every host on its
      # first tick, since the agent installs (picking up
      # --flannel-backend=* / --disable-network-policy) BEFORE
      # KubernetesClusterProvisionerService#bootstrap! creates the
      # cluster row — falls back to the SAME network_profile
      # auto-default #bootstrap! will use when it later records
      # cni_plugin. The two call sites MUST agree here: K3s only
      # reads its CNI flags at install time and the cluster's
      # cni_plugin is immutable once bootstrapped, so predicting
      # "flannel" unconditionally would leave a heavyweight host
      # running Flannel forever while the DB claims ovn_kubernetes.
      #
      # K3s overlay (2026-05-19) — when the cluster carries a
      # pod_cidr (set at bootstrap when the SDWAN network has
      # pod_subnet_prefix + cni_plugin is flannel), also emit
      # flannel_iface + flannel_backend=host-gw + cluster_cidr so
      # the agent passes --flannel-iface + --flannel-backend +
      # --cluster-cidr at k3s install time. Zero-value strings
      # (empty) mean "k3s defaults" — the agent's InstallArgs is
      # zero-value safe.
      def k3s_server_bootstrap_config(instance)
        cluster = ::Devops::KubernetesNode
                    .where(node_instance_id: instance.id)
                    .joins(:kubernetes_cluster)
                    .first
                    &.kubernetes_cluster
        cni_plugin = cluster&.cni_plugin ||
                     ::System::KubernetesClusterProvisionerService.auto_default_cni_for(instance)

        payload = { cni_plugin: cni_plugin, flannel_iface: "", flannel_backend: "", cluster_cidr: "" }

        return payload unless cni_plugin == "flannel"
        return payload if cluster.blank?

        pod_cidr = cluster.metadata.is_a?(Hash) ? cluster.metadata["pod_cidr"] : nil
        return payload if pod_cidr.blank?

        # Wants the peer's NETWORK (for the flannel interface name), not
        # its address — see Sdwan::OverlayAddressResolver.
        peer = ::Sdwan::OverlayAddressResolver.attachment_peer_for(instance)
        return payload unless peer&.network

        payload.merge(
          # Resolved through the single source, not re-derived: this call site
          # carried its own "wg-sdwan-<handle>" copy and therefore named a
          # device the host does not have whenever a HostVrfAssignment exists
          # (IMP-54fdf40fbf9d). flannel binding to a missing interface is a
          # silent cluster-networking failure, not a loud one.
          flannel_iface: ::Sdwan::HostVrfAssignment.wg_iface_name_for(
            network: peer.network, node_instance: instance
          ),
          flannel_backend: "host-gw",
          cluster_cidr: pod_cidr
        )
      end
    end
  end
end
