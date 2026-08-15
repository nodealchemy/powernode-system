# frozen_string_literal: true

require "json"
require "digest"
require "ipaddr"

module System
  # Phase 2 — Kubernetes (K3s) cluster auto-registration.
  #
  # Parallel to System::DockerDaemonProvisionerService. Differences:
  #
  # - Trust model: K3s ships its own CA + signs its own certs. The
  #   platform doesn't issue cert material; instead the agent reports
  #   what it created (kubeconfig + tokens) and the platform records
  #   it. Phase 3 kubeadm is similar — kubeadm bootstraps its own PKI.
  #
  # - Topology: 1:N from cluster to NodeInstance. The first server's
  #   bootstrap creates a Devops::KubernetesCluster row + a
  #   Devops::KubernetesNode (role: server). Subsequent k3s-server
  #   joins (HA) and k3s-agent joins each create a new
  #   Devops::KubernetesNode under the same cluster.
  #
  # Service surface:
  #
  #   .bootstrap!(node_instance:, kubeconfig:, server_token:,
  #               agent_token:, k8s_version:)
  #     → idempotent; creates the cluster on first call, no-op on
  #       repeat. Returns the Devops::KubernetesCluster.
  #
  #   .join_request!(node_instance:)
  #     → caller is a k3s-agent or HA k3s-server asking for the
  #       cluster details. Returns api_endpoint + appropriate token.
  #       Raises NoClusterAvailableError if no cluster exists in the
  #       account yet.
  #
  #   .register_node_join!(node_instance:, role:, k8s_version:)
  #     → caller has joined; idempotently create the
  #       Devops::KubernetesNode row.
  #
  #   .mark_node_ready!(node_instance:, k8s_version:)
  #     → flip status to active (mirrors Docker's mark_daemon_ready).
  #
  #   .mark_node_stopped!(node_instance:)
  #     → flip status to disconnected.
  class KubernetesClusterProvisionerService
    class ProvisionError < StandardError; end
    class MissingSdwanPeerError < ProvisionError; end
    class NoClusterAvailableError < ProvisionError; end
    # Raised when a join_request omits target_cluster_id but the account has
    # more than one active cluster. Auto-select among many is refused — a node
    # joining the wrong cluster is an isolation breach.
    class AmbiguousClusterError < ProvisionError; end
    # Phase O4 — raised when an operator-supplied cni_plugin disagrees
    # with the bootstrap NodeInstance's network_profile, OR when a
    # joining NodeInstance has a network_profile that conflicts with
    # the existing cluster's CNI choice. Mixed-profile clusters are
    # not supported because CNI is uniform per cluster.
    class CniProfileMismatchError < ProvisionError; end

    K3S_API_PORT = 6443

    # Phase O4 — auto-default mapping from a host's network_profile to
    # the CNI plugin its cluster should boot with. heavyweight hosts
    # have the headroom for OVN-controller + OVN-K8s; lightweight hosts
    # do not, so they stay on K3s's bundled Flannel.
    NETWORK_PROFILE_TO_CNI = {
      "heavyweight" => "ovn_kubernetes",
      "lightweight" => "flannel"
    }.freeze
    DEFAULT_CNI_PLUGIN = "flannel"

    def self.bootstrap!(**kwargs) = new(**kwargs).bootstrap!
    def self.join_request!(node_instance:, target_cluster_id: nil)
      new(node_instance: node_instance, target_cluster_id: target_cluster_id).join_request!
    end

    def self.register_node_join!(node_instance:, role:, k8s_version: nil, target_cluster_id: nil)
      new(node_instance: node_instance, role: role, k8s_version: k8s_version,
          target_cluster_id: target_cluster_id).register_node_join!
    end

    def self.mark_node_ready!(node_instance:, k8s_version: nil)
      new(node_instance: node_instance, k8s_version: k8s_version).mark_node_ready!
    end

    def self.mark_node_stopped!(node_instance:)
      new(node_instance: node_instance).mark_node_stopped!
    end

    # Phase O4 — single source of truth for the network_profile → CNI
    # auto-default, shared with RuntimeConfigBuilder. The agent installs
    # K3s (picking up --flannel-backend=* / --disable-network-policy)
    # BEFORE any Devops::KubernetesCluster row exists — bootstrap! is
    # the call that creates it — so RuntimeConfigBuilder must predict
    # the same auto-default #bootstrap! will later record, or the
    # installed CNI and the recorded cni_plugin permanently disagree
    # (K3s only reads its CNI flags at install time; the cluster row's
    # cni_plugin is immutable once bootstrapped).
    def self.auto_default_cni_for(node_instance)
      profile = node_instance.respond_to?(:network_profile) ? node_instance.network_profile.to_s : ""
      NETWORK_PROFILE_TO_CNI.fetch(profile, DEFAULT_CNI_PLUGIN)
    end

    def initialize(node_instance: nil, kubeconfig: nil, server_token: nil,
                   agent_token: nil, k8s_version: nil, role: nil,
                   target_cluster_id: nil, cni_plugin: nil)
      @node_instance = node_instance
      @kubeconfig = kubeconfig
      @server_token = server_token
      @agent_token = agent_token
      @k8s_version = k8s_version
      @role = role
      @target_cluster_id = target_cluster_id
      # Operator-explicit CNI override. When nil, the auto-default is
      # derived from the bootstrap NodeInstance's network_profile.
      @cni_plugin = cni_plugin
    end

    # ──────────────────────────────────────────────────────────────────
    # bootstrap! — first k3s-server in a cluster
    # ──────────────────────────────────────────────────────────────────

    def bootstrap!
      raise ArgumentError, "node_instance required" unless @node_instance
      raise ArgumentError, "kubeconfig required for bootstrap" if @kubeconfig.blank?
      raise ArgumentError, "server_token required for bootstrap" if @server_token.blank?

      @account = @node_instance.account
      account = @account # local alias for readability in this method
      overlay_address = resolve_overlay_address!

      # Idempotent: if this NodeInstance is already a server in some
      # cluster, return that cluster. Operators can re-trigger bootstrap
      # to refresh stored credentials without duplicating rows.
      existing_node = ::Devops::KubernetesNode.find_by(node_instance_id: @node_instance.id)
      if existing_node && existing_node.server?
        update_credentials!(existing_node.kubernetes_cluster)
        record_bootstrap_event!(existing_node.kubernetes_cluster,
                                phase: "bootstrap", status: "credentials_refreshed",
                                message: "node_instance=#{@node_instance.id}")
        return existing_node.kubernetes_cluster
      end

      # Phase 2.5 hardening (slice 3) — allocate a single-holder VIP
      # so the cluster's api_endpoint survives bootstrap-node loss.
      # When subsequent k3s-server NodeInstances join (HA control
      # plane), they're added as VIP failover candidates. Bootstrap
      # node loss becomes a vip.failover! event, not a cluster-
      # destruction event.
      bootstrap_peer = ::Sdwan::OverlayAddressResolver.addressed_peer_for(@node_instance)
      cluster_name = cluster_name_for(@node_instance)
      api_vip = nil
      api_endpoint_address = overlay_address
      if bootstrap_peer&.network
        api_vip = allocate_api_vip!(
          network: bootstrap_peer.network,
          bootstrap_peer: bootstrap_peer,
          cluster_name: cluster_name
        )
        api_endpoint_address = api_vip.cidr.split("/").first
      else
        Rails.logger.warn(
          "[KubernetesClusterProvisionerService] bootstrap peer has no " \
          "Sdwan::Network — falling back to /128 api_endpoint for cluster " \
          "#{cluster_name}; api_endpoint will not survive bootstrap-node loss"
        )
      end

      metadata = {
        "bootstrap_node_instance_id" => @node_instance.id,
        "bootstrap_overlay_address" => overlay_address,
        "bootstrapped_at" => Time.current.utc.iso8601
      }
      if api_vip
        metadata["api_vip_id"] = api_vip.id
        metadata["api_vip_cidr"] = api_vip.cidr
      end

      # Phase O4 — pick the CNI for this cluster. Operator-explicit
      # always wins; otherwise auto-default from the bootstrap
      # NodeInstance's network_profile (heavyweight → ovn_kubernetes,
      # lightweight → flannel). The resolver also raises
      # CniProfileMismatchError if the operator's explicit choice
      # disagrees with the bootstrap host's profile, surfacing the
      # contradiction loudly instead of silently misconfiguring K3s.
      resolved_cni_plugin = resolve_bootstrap_cni_plugin!(@node_instance, @cni_plugin)

      # K3s overlay (2026-05-19) — when flannel is the CNI and the
      # bootstrap peer's SDWAN network has pod_subnet_prefix set,
      # stamp the cluster row with the pod CIDR + sdwan_network_id so
      # the bootstrap_config endpoint can emit --flannel-iface +
      # --flannel-backend=host-gw + --cluster-cidr at install time.
      # ovn-Kubernetes ignores pod_subnet_prefix (its pod-network
      # layer is OVN-driven) — emit a warning when the field is set
      # on an ovn-K8s path so operators don't silently assume the
      # value is in effect.
      pod_overlay_active = false
      if bootstrap_peer&.network&.pod_subnet_prefix.present?
        if resolved_cni_plugin == "flannel"
          metadata["pod_cidr"] = bootstrap_peer.network.pod_subnet_prefix
          metadata["sdwan_network_id"] = bootstrap_peer.sdwan_network_id
          pod_overlay_active = true
        elsif resolved_cni_plugin == "ovn_kubernetes" && defined?(::System::Fleet::EventBroadcaster)
          begin
            ::System::Fleet::EventBroadcaster.emit!(
              account: account,
              kind: "system.cluster_bootstrap.pod_subnet_prefix_ignored",
              severity: :medium,
              source: "kubernetes_cluster_provisioner",
              payload: {
                cluster_name: cluster_name,
                node_instance_id: @node_instance.id,
                cni_plugin: resolved_cni_plugin,
                network_id: bootstrap_peer.sdwan_network_id,
                pod_subnet_prefix: bootstrap_peer.network.pod_subnet_prefix,
                note: "pod_subnet_prefix is flannel-only in v1; ovn-Kubernetes uses its own pod-network logic"
              }
            )
          rescue StandardError => e
            Rails.logger.warn("[KubernetesClusterProvisionerService] warning-event emit failed: #{e.class}: #{e.message}")
          end
        end
      end

      cluster = nil
      ActiveRecord::Base.transaction do
        cluster = ::Devops::KubernetesCluster.create!(
          account: account,
          name: cluster_name,
          flavor: "k3s",
          environment: "production",
          status: "bootstrapping",
          cni_plugin: resolved_cni_plugin,
          api_endpoint: "https://[#{api_endpoint_address}]:#{K3S_API_PORT}",
          k8s_version: @k8s_version,
          encrypted_kubeconfig: @kubeconfig,
          encrypted_server_token: @server_token,
          encrypted_agent_token: @agent_token.presence || @server_token,
          metadata: metadata
        )

        ::Devops::KubernetesNode.create!(
          kubernetes_cluster: cluster,
          node_instance: @node_instance,
          name: kubelet_name_for(@node_instance),
          role: "server",
          status: "active",
          k8s_version: @k8s_version,
          last_heartbeat_at: Time.current
        )

        cluster.update!(node_count: 1)

        # K3s overlay — emit a SubnetAdvertisement row for the cluster's
        # pod CIDR sourced from this network. Mirrors the pattern used by
        # Sdwan::Peer#sync_subnet_advertisements_from_lan_subnets so the
        # routing pipeline + governance scans treat pod CIDRs the same
        # way as declared LAN subnets + VIPs.
        if pod_overlay_active
          ::Sdwan::SubnetAdvertisement.create!(
            peer: bootstrap_peer,
            network: bootstrap_peer.network,
            account_id: account.id,
            prefix: bootstrap_peer.network.pod_subnet_prefix,
            source: "pod_subnet",
            origin_peer_id: bootstrap_peer.id,
            first_seen_at: Time.current,
            last_seen_at: Time.current
          )
        end
      end

      Rails.logger.info(
        "[KubernetesClusterProvisionerService] bootstrapped cluster " \
        "cluster_id=#{cluster.id} node_instance_id=#{@node_instance.id} " \
        "endpoint=#{cluster.api_endpoint} vip_id=#{api_vip&.id || 'none'} " \
        "cni_plugin=#{cluster.cni_plugin} pod_overlay=#{pod_overlay_active}"
      )
      record_bootstrap_event!(cluster,
                              phase: "bootstrap", status: "completed",
                              message: "node_instance=#{@node_instance.id} " \
                                       "cni=#{cluster.cni_plugin} " \
                                       "pod_overlay=#{pod_overlay_active}")
      cluster
    end

    # ──────────────────────────────────────────────────────────────────
    # join_request! — k3s-agent asks "what cluster should I join?"
    # ──────────────────────────────────────────────────────────────────

    def join_request!
      raise ArgumentError, "node_instance required" unless @node_instance

      account = @node_instance.account

      # Multi-cluster awareness (Phase 2.5): when target_cluster_id is
      # provided, resolve to that specific cluster. Otherwise fall
      # back to single-cluster behavior (most recent active cluster
      # in the account) — refusing to auto-select among several.
      # Shared with register_node_join! so a ready re-fire can never
      # resolve a different cluster than the join it followed.
      cluster = resolve_membership_cluster!(account)

      unless cluster
        raise NoClusterAvailableError,
              "no Kubernetes cluster available in account #{account.id} — " \
              "bootstrap a k3s-server first"
      end

      {
        cluster_id: cluster.id,
        api_endpoint: cluster.api_endpoint,
        agent_token: cluster.encrypted_agent_token,
        ca_pem: extract_ca_pem(cluster.encrypted_kubeconfig)
      }
    end

    # Record a refused ambiguous join (no target_cluster_id + >1 active cluster)
    # for operator visibility before raising. Best-effort: an emit failure must
    # not mask the AmbiguousClusterError.
    def emit_ambiguous_join_refused!(count)
      Rails.logger.warn(
        "[KubernetesClusterProvisionerService] refused ambiguous join for node_instance " \
        "#{@node_instance&.id}: account #{@node_instance&.account_id} has #{count} active " \
        "clusters and no target_cluster_id was provided"
      )
      ::System::Fleet::EventBroadcaster.emit!(
        account: @node_instance.account,
        kind: "system.k3s_ambiguous_cluster_join_refused",
        severity: :high,
        source: "kubernetes_cluster_provisioner",
        payload: {
          active_cluster_count: count,
          node_instance_id: @node_instance.id
        },
        node_instance_id: @node_instance.id
      )
    rescue StandardError => e
      Rails.logger.warn("[KubernetesClusterProvisionerService] refusal event emit failed: #{e.class}: #{e.message}")
    end

    # Shared multi-cluster-safe cluster resolution for join_request! and
    # register_node_join! — the two callers must never disagree, or a
    # node could join one cluster and then get silently re-registered
    # against another on its next ready re-fire. When @target_cluster_id
    # is present, resolve to that specific cluster (raising if unknown or
    # errored). Otherwise fall back to single-cluster auto-select,
    # refusing (AmbiguousClusterError) when the account has more than one
    # non-error cluster — guessing "most recent" would silently move a
    # node's membership onto the wrong cluster.
    def resolve_membership_cluster!(account)
      if @target_cluster_id.present?
        c = ::Devops::KubernetesCluster
              .where(account_id: account.id, id: @target_cluster_id)
              .first
        unless c
          raise NoClusterAvailableError,
                "target cluster #{@target_cluster_id} not found in account #{account.id} — " \
                "verify cluster_id, or omit target_cluster_id to auto-select most recent"
        end
        if c.status == "error"
          raise NoClusterAvailableError,
                "target cluster #{@target_cluster_id} is in error state; refusing to join"
        end
        return c
      end

      candidates = ::Devops::KubernetesCluster
                     .where(account_id: account.id)
                     .where.not(status: "error")
                     .order(created_at: :desc)
                     .to_a
      # Refuse to auto-select among multiple clusters — a node joining (or
      # re-registering against) the wrong cluster is an isolation breach.
      # The caller must pass target_cluster_id. A single active cluster
      # is unambiguous and is still resolved without one.
      if candidates.size > 1
        emit_ambiguous_join_refused!(candidates.size)
        raise AmbiguousClusterError,
              "account #{account.id} has #{candidates.size} active clusters; " \
              "pass target_cluster_id to choose one (auto-select refused)"
      end
      candidates.first
    end

    # ──────────────────────────────────────────────────────────────────
    # register_node_join! — agent confirms it joined
    # ──────────────────────────────────────────────────────────────────

    def register_node_join!
      raise ArgumentError, "node_instance required" unless @node_instance
      raise ArgumentError, "role required (server|agent)" unless @role

      account = @node_instance.account

      # Same multi-cluster-safe resolution as join_request! — phase=ready
      # re-fires this on every k3s version bump / rolling upgrade / state
      # loss, so this MUST resolve the node's actual cluster (via
      # target_cluster_id, sourced from the agent's own cached
      # join/bootstrap cluster_id) rather than re-guessing "most recent
      # cluster in the account" and silently relocating an already-joined
      # node the moment a second cluster exists.
      cluster = resolve_membership_cluster!(account)
      raise NoClusterAvailableError, "no cluster to register against" unless cluster

      # Phase O4 — refuse to add a node whose network_profile mismatches
      # the cluster's CNI. CNI is uniform per cluster (the K3s server
      # boots with one and only one CNI install-flag set), so a
      # heavyweight host trying to join a Flannel cluster — or vice
      # versa — would either install the wrong agent-side networking
      # stack or fail to cordon at the kube-proxy boundary. Reject at
      # the API layer so the operator gets a clear error before the
      # agent commits to an inconsistent runtime state.
      enforce_cni_profile_compatibility!(cluster, @node_instance)

      node = ::Devops::KubernetesNode.find_by(node_instance_id: @node_instance.id)
      created_new_node = false
      if node
        previous_cluster = node.kubernetes_cluster
        node.update!(
          kubernetes_cluster: cluster,
          role: @role,
          k8s_version: @k8s_version,
          last_heartbeat_at: Time.current
        )
        # Deliberate retarget (explicit target_cluster_id pointing
        # somewhere other than the node's current membership) is the
        # only way `cluster` can now differ from the prior one —
        # auto-select refuses among multiple candidates above. Keep
        # both clusters' node_count honest when it happens.
        if previous_cluster && previous_cluster.id != cluster.id
          previous_cluster.decrement!(:node_count) if previous_cluster.node_count.to_i > 0
          cluster.increment!(:node_count)
        end
      else
        node = ::Devops::KubernetesNode.create!(
          kubernetes_cluster: cluster,
          node_instance: @node_instance,
          name: kubelet_name_for(@node_instance),
          role: @role,
          status: "joining",
          k8s_version: @k8s_version,
          last_heartbeat_at: Time.current
        )
        cluster.increment!(:node_count)
        created_new_node = true
      end

      # Phase 2.5 (slice 3) — HA control plane awareness. When a
      # second+ k3s-server joins, register it as a VIP failover
      # candidate so cluster api_endpoint survives bootstrap node
      # loss. Skip for agent role (workers don't answer
      # kube-apiserver).
      add_to_vip_failover_candidates!(cluster) if @role == "server"

      record_bootstrap_event!(cluster,
                              phase: "register_node_join",
                              status: created_new_node ? "created" : "updated",
                              message: "node_instance=#{@node_instance.id} role=#{@role}")
      node
    end

    # ──────────────────────────────────────────────────────────────────
    # mark_node_ready! — agent reports kubelet/server is up
    # ──────────────────────────────────────────────────────────────────

    def mark_node_ready!
      raise ArgumentError, "node_instance required" unless @node_instance

      node = ::Devops::KubernetesNode.find_by(node_instance_id: @node_instance.id)
      raise NoClusterAvailableError, "no cluster membership for this NodeInstance" unless node

      node.update!(
        status: "active",
        k8s_version: @k8s_version || node.k8s_version,
        last_heartbeat_at: Time.current
      )

      # If this was the bootstrap server flipping to active, promote
      # the cluster status from bootstrapping to active too.
      cluster = node.kubernetes_cluster
      cluster_was_promoted = false
      if cluster.bootstrapping? && node.server? && node.active?
        cluster.update!(status: "active")
        cluster_was_promoted = true
      end

      record_bootstrap_event!(cluster,
                              phase: "mark_node_ready",
                              status: cluster_was_promoted ? "node_ready_cluster_promoted" : "node_ready",
                              message: "node_instance=#{@node_instance.id} role=#{node.role}")
      node
    end

    # ──────────────────────────────────────────────────────────────────
    # mark_node_stopped! — agent reports clean shutdown
    # ──────────────────────────────────────────────────────────────────

    def mark_node_stopped!
      raise ArgumentError, "node_instance required" unless @node_instance

      node = ::Devops::KubernetesNode.find_by(node_instance_id: @node_instance.id)
      return nil unless node

      node.update!(status: "disconnected", last_heartbeat_at: Time.current)
      record_bootstrap_event!(node.kubernetes_cluster,
                              phase: "mark_node_stopped", status: "disconnected",
                              message: "node_instance=#{@node_instance.id} role=#{node.role}")
      node
    end

    # ──────────────────────────────────────────────────────────────────
    # Internals
    # ──────────────────────────────────────────────────────────────────

    private

    def resolve_overlay_address!
      # Shared seam picks the oldest addressed peer and strips the CIDR
      # prefix length; the error type stays ours for callers rescuing it.
      address = ::Sdwan::OverlayAddressResolver.address_for(@node_instance)
      unless address
        raise MissingSdwanPeerError,
              "NodeInstance #{@node_instance.id} has no SDWAN peer with an " \
              "assigned overlay address — assign an Sdwan::Peer before " \
              "bootstrapping a k3s cluster"
      end
      address
    end

    # Phase O4 — pick the CNI for a brand-new cluster from the
    # bootstrap NodeInstance's network_profile. When the operator
    # supplies an explicit cni_plugin, validate it and use it directly.
    # When the operator supplies one that disagrees with the bootstrap
    # host's profile, raise CniProfileMismatchError so the contradiction
    # surfaces before the K3s server boots with mismatched flags.
    #
    # Returns one of Devops::KubernetesCluster::CNI_PLUGINS.
    def resolve_bootstrap_cni_plugin!(node_instance, explicit_plugin)
      profile = node_instance.respond_to?(:network_profile) ? node_instance.network_profile.to_s : ""

      if explicit_plugin.present?
        explicit = explicit_plugin.to_s
        unless ::Devops::KubernetesCluster::CNI_PLUGINS.include?(explicit)
          raise CniProfileMismatchError,
                "cni_plugin '#{explicit}' is not one of " \
                "#{::Devops::KubernetesCluster::CNI_PLUGINS.inspect}"
        end

        # Cross-check: explicit choice must agree with the bootstrap
        # host's profile. Operators promoting a heavyweight host can
        # still pick flannel deliberately (downgrade path), but going
        # the other way (lightweight host + ovn_kubernetes) would
        # exceed the host's hardware floor for OVN-controller, so
        # reject loudly.
        if explicit == "ovn_kubernetes" && profile == "lightweight"
          raise CniProfileMismatchError,
                "cni_plugin 'ovn_kubernetes' is not compatible with bootstrap " \
                "NodeInstance #{node_instance.id} (network_profile=lightweight). " \
                "OVN-Kubernetes requires the heavyweight network_profile (≥4GB " \
                "RAM headroom for ovn-controller + ovn-northd). Promote the host " \
                "to heavyweight first, or pick cni_plugin: 'flannel'."
        end

        return explicit
      end

      self.class.auto_default_cni_for(node_instance)
    end

    # Phase O4 — refuse to add a node whose network_profile is
    # incompatible with the cluster's CNI. Specifically: a lightweight-
    # profile host cannot join an `ovn_kubernetes` cluster because the
    # OVN-controller daemon will not fit on the host. Heavyweight hosts
    # joining a `flannel` cluster ARE allowed (downgrade path is safe —
    # they just don't run the OVS+OVN stack). Hosts with no profile
    # information default to lightweight semantics, which is the safe
    # interpretation.
    def enforce_cni_profile_compatibility!(cluster, node_instance)
      cluster_cni = cluster.cni_plugin.to_s
      profile     = node_instance.respond_to?(:network_profile) ? node_instance.network_profile.to_s : ""

      return unless cluster_cni == "ovn_kubernetes"
      return unless profile == "lightweight"

      raise CniProfileMismatchError,
            "NodeInstance #{node_instance.id} (network_profile=lightweight) " \
            "cannot join cluster #{cluster.id} (cni_plugin=ovn_kubernetes). " \
            "Mixed-profile clusters are not supported because CNI is uniform " \
            "per cluster — promote the NodeInstance to network_profile=" \
            "heavyweight first, or join a cni_plugin=flannel cluster."
    end

    def update_credentials!(cluster)
      attrs = { k8s_version: @k8s_version || cluster.k8s_version }
      attrs[:encrypted_kubeconfig] = @kubeconfig if @kubeconfig.present?
      attrs[:encrypted_server_token] = @server_token if @server_token.present?
      attrs[:encrypted_agent_token] = @agent_token if @agent_token.present?
      cluster.update!(attrs) if attrs.any? { |k, v| v.present? && cluster.send(k) != v }

      # Phase 2.5 (slice 3) — keep VIP holder pointed at the current
      # bootstrap peer. Rare in practice (re-bootstrap is usually on
      # the same node), but covers the case where an operator
      # re-bootstraps from a different NodeInstance + the original
      # bootstrap node has been terminated.
      refresh_vip_holder!(cluster)
    end

    def add_to_vip_failover_candidates!(cluster)
      vip_id = (cluster.metadata || {})["api_vip_id"]
      return if vip_id.blank?

      vip = ::Sdwan::VirtualIp.find_by(id: vip_id)
      return unless vip

      joiner_peer = ::Sdwan::OverlayAddressResolver.addressed_peer_for(@node_instance)
      return unless joiner_peer

      already_primary = Array(vip.holder_peer_ids).include?(joiner_peer.id)
      already_failover = Array(vip.failover_holder_peer_ids).include?(joiner_peer.id)
      return if already_primary || already_failover

      vip.update!(
        failover_holder_peer_ids: Array(vip.failover_holder_peer_ids) + [ joiner_peer.id ]
      )
    end

    def refresh_vip_holder!(cluster)
      vip_id = (cluster.metadata || {})["api_vip_id"]
      return if vip_id.blank?

      vip = ::Sdwan::VirtualIp.find_by(id: vip_id)
      return unless vip

      new_peer = ::Sdwan::OverlayAddressResolver.addressed_peer_for(@node_instance)
      return unless new_peer

      current_primary = Array(vip.holder_peer_ids).first
      return if current_primary == new_peer.id

      old_failover = Array(vip.failover_holder_peer_ids)
      new_failover = (old_failover + [ current_primary ].compact).uniq - [ new_peer.id ]

      vip.update!(
        holder_peer_ids: [ new_peer.id ],
        failover_holder_peer_ids: new_failover
      )
    end

    # Best-effort CA extraction from a kubeconfig YAML string. The
    # platform doesn't strictly need it (kubectl bundled with k3s
    # uses the kubeconfig directly), but exposing it lets non-kubectl
    # clients (Helm, Argo CD) trust the API server. We don't parse
    # YAML here — that requires the `psych` gem at parse time which
    # is heavy. Phase 3 will add a kubeconfig parser; for now we
    # return nil and clients must use the kubeconfig.
    def extract_ca_pem(_kubeconfig_yaml)
      nil
    end

    def cluster_name_for(node_instance)
      base = node_instance.name.presence || "instance-#{node_instance.id[0, 8]}"
      "#{base}-k8s"
    end

    def kubelet_name_for(node_instance)
      node_instance.name.presence || "instance-#{node_instance.id[0, 8]}"
    end

    # Allocates a single-holder Sdwan::VirtualIp for the cluster's
    # api_endpoint. Deterministic CIDR derivation from the network's
    # /64 + a 16-bit hash of the cluster name — collision risk is
    # acceptable across human-named clusters; re-bootstrapping the
    # same name yields the same VIP (idempotent via
    # find_or_create_by!).
    #
    # The VIP becomes immediately advertised:
    #   - Static-routing networks: agent's vip_applier writes it to lo
    #     on the holder peer (Sdwan::TopologyCompiler#vips_held_by)
    #   - iBGP-routing networks: BGP config compiler adds the /128 to
    #     the holder's network statements
    def allocate_api_vip!(network:, bootstrap_peer:, cluster_name:)
      vip_cidr = derive_vip_cidr(network: network, cluster_name: cluster_name)

      ::Sdwan::VirtualIp.find_or_create_by!(
        account_id: @account.id,
        sdwan_network_id: network.id,
        name: "#{cluster_name}-api"
      ) do |vip|
        vip.cidr = vip_cidr
        vip.holder_peer_ids = [ bootstrap_peer.id ]
        vip.failover_holder_peer_ids = []
        # Explicit state — the model has no auto-transition callback;
        # default is "pending". For our use case, the VIP is
        # immediately routable as soon as the bootstrap peer is the
        # primary holder, so go straight to "active".
        vip.state = "active"
        vip.description = "Kubernetes API endpoint for cluster #{cluster_name}"
      end
    end

    # Derive a deterministic /128 VIP address inside the network's
    # /64. Uses IPAddr arithmetic so the resulting address is always
    # a normalized, validator-passing IPv6 string regardless of the
    # input network's notation (`fd00::/64`, `fd00:0:0:0::/64`, etc.).
    #
    # Strategy: take the lower 64 bits of the host portion as
    # `0xdeadbeef00000000 | (cluster_hash & 0xffff)` so VIPs are
    # easily recognizable in packet captures (`dead:beef:0000:xxxx`)
    # and human-debuggable.
    def derive_vip_cidr(network:, cluster_name:)
      base = ::IPAddr.new(network.cidr_64.to_s)
      cluster_hash = ::Digest::SHA256.digest(cluster_name).bytes.first(2)
      suffix_16 = (cluster_hash[0] << 8) | cluster_hash[1]
      # Top 64 bits = network; bottom 64 bits = 0xdead_beef_0000_xxxx
      host_low = 0xdead_beef_0000_0000 | (suffix_16 & 0xffff)
      vip_int = (base.to_i & ((2**128 - 1) ^ ((1 << 64) - 1))) | host_low
      "#{::IPAddr.new(vip_int, ::Socket::AF_INET6)}/128"
    end

    # Append-only diagnostic event log on cluster.metadata["bootstrap_events"].
    # Capped at most-recent 50 entries to bound JSONB size — older events
    # fall off the head. Used by the smoke-test helpers' wait_for_cluster_active!
    # to surface a meaningful failure trace on timeout, and by operators
    # for post-mortem analysis of stuck clusters.
    #
    # Best-effort: any failure here is logged and swallowed. The event log
    # is instrumentation, not load-bearing — a failed metadata write must
    # never cascade up into the bootstrap/join lifecycle. Concurrent
    # writers race on last-write-wins; the cap-at-50 invariant is per-call,
    # not cluster-wide.
    EVENT_LOG_CAP = 50
    BOOTSTRAP_EVENT_KEY = "bootstrap_events"

    def record_bootstrap_event!(cluster, phase:, status:, message: nil)
      return unless cluster&.persisted?

      cluster.reload
      events = Array((cluster.metadata || {})[BOOTSTRAP_EVENT_KEY])
      entry = {
        "ts"     => Time.current.utc.iso8601,
        "phase"  => phase.to_s,
        "status" => status.to_s
      }
      entry["message"] = message if message.present?
      events << entry
      events = events.last(EVENT_LOG_CAP)
      cluster.update!(metadata: (cluster.metadata || {}).merge(BOOTSTRAP_EVENT_KEY => events))
    rescue StandardError => e
      Rails.logger.warn(
        "[KubernetesClusterProvisionerService] event recording failed: " \
        "#{e.class}: #{e.message} (cluster_id=#{cluster&.id} phase=#{phase})"
      )
    end
  end
end
