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
        case @runtime
        when "docker"
          docker_config
        when "k3s_server"
          k3s_server_config
        else
          empty_config
        end
      end

      private

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
      # Devops::KubernetesNode) and pulls cni_plugin from there.
      # Falls back to "flannel" (the K3s default, safe for any
      # unenrolled host) when the host has no cluster yet.
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
        cni_plugin = cluster&.cni_plugin || "flannel"

        payload = { cni_plugin: cni_plugin, flannel_iface: "", flannel_backend: "", cluster_cidr: "" }

        return payload unless cni_plugin == "flannel"
        return payload if cluster.blank?

        pod_cidr = cluster.metadata.is_a?(Hash) ? cluster.metadata["pod_cidr"] : nil
        return payload if pod_cidr.blank?

        peer = ::Sdwan::Peer.where(node_instance_id: instance.id).first
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
