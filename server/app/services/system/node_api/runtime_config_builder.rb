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

      # k3s_agent + kubeadm runtime config delivery is a
      # follow-up; return an empty payload so the agent doesn't
      # error out when probing newer endpoints from older
      # runtimes.
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
          flannel_iface: "wg-sdwan-#{peer.network.network_handle}",
          flannel_backend: "host-gw",
          cluster_cidr: pod_cidr
        )
      end
    end
  end
end
