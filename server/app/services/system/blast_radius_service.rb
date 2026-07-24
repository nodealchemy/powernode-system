# frozen_string_literal: true

module System
  # Infrastructure blast-radius: given a fleet node identifier, derive what
  # actually depends on it across the parts of the platform's OWN data model
  # that are queryable today — the infra analogue of
  # Ai::Codebase::BlastRadiusService (server/app/services/ai/codebase/
  # blast_radius_service.rb), which answers the same "what depends on X"
  # question for the code graph. Campaign 019f9250 (Resilient Control Plane
  # v2), increment P0-d.
  #
  # Lives in the system extension (not core) because every entity it walks —
  # System::Node, System::NodeInstance, Sdwan::*, System::StorageAssignment,
  # System::InstancePool — is extension-owned; core has no System::/Sdwan::
  # references (Extension Isolation). It reuses ::FileManagement::Storage
  # (core) read-only, which extensions are allowed to depend on.
  #
  # Accepts three shapes of "fleet node" identifier, since this codebase
  # doesn't model them uniformly:
  #   1. A System::Node#name (e.g. "ops-hub") — the common case for anything
  #      onboarded through the platform's own provisioning.
  #   2. A System::NodeInstance#name, for callers that already have the more
  #      specific handle.
  #   3. A bare Proxmox (or other provider) cluster-node token (e.g. "dna",
  #      "rna") — these are NOT modeled as first-class Node/NodeInstance rows
  #      at all; they only ever appear as the leading path segment of
  #      NodeInstance#cloud_instance_id ("<node>/<kind>/<vmid>", set by
  #      System::Providers::ProxmoxProvider — see #parse_instance_id! there).
  #      Resolving this shape is a LIKE match on that config string, not a FK
  #      lookup, and is reported as such (never silently presented as if it
  #      were a first-class match).
  #
  # Read-only. Never mutates fleet state.
  class BlastRadiusService
    # Human-friendly bucket labels for a handful of dependent classes whose
    # default Rails #underscore/#pluralize would read awkwardly or collide.
    # Everything else in CASCADE_DEPENDENTS falls back to a derived label.
    DIRECT_LABEL_OVERRIDES = {
      "Sdwan::Peer"                  => "sdwan_peers",
      "Sdwan::HostBridge"            => "sdwan_host_bridges",
      "Sdwan::HostVrfAssignment"     => "sdwan_host_vrf_assignments",
      "System::NodeInstancePeer"     => "node_instance_peers",
      "System::StorageMigration"     => "storage_migrations",
      "System::StorageAssignment"    => "storage_assignments",
      "System::StorageCredential"    => "storage_credentials",
      "System::BootstrapToken"       => "bootstrap_tokens",
      "System::MountEncryptionKey"   => "mount_encryption_keys",
      "System::NodeModule"           => "node_modules",
      "System::ProviderVolume"       => "provider_volumes"
    }.freeze

    # Cap on items embedded per bucket (counts are always exact; this only
    # bounds the sample rows) so a heavily-populated fleet (e.g. a few hundred
    # CI-builder-pool instances sharing one Proxmox host) doesn't blow up the
    # response.
    ITEM_LIMIT = 25

    def initialize(account: nil)
      @account = account
    end

    # @param node [String] fleet node identifier — see class doc for the three
    #   accepted shapes.
    # @return [Hash] { success:, target:, dependents:, dns:, total_dependents: }
    #   or { success: false, error:, fuzzy_candidates: } when nothing resolves.
    def trace(node)
      resolution = resolve_target(node)
      return { success: false, error: resolution[:error], fuzzy_candidates: resolution[:fuzzy_candidates] } if resolution[:error]

      instance_ids = Array(resolution[:instance_ids])
      direct = direct_dependents(instance_ids)
      peer_ids = direct.fetch("sdwan_peers", {})[:ids] || []
      vips = virtual_ip_dependents(peer_ids)

      dependents = direct.merge(
        "instance_pools"             => instance_pool_dependents(instance_ids),
        "sdwan_virtual_ips"          => vips,
        "sdwan_services"             => service_dependents(vips[:ids]),
        "sdwan_port_mappings"        => port_mapping_dependents(peer_ids),
        "cross_node_storage_exports" => cross_node_storage_dependents(instance_ids)
      )

      {
        success: true,
        target: {
          query: node.to_s,
          kind: resolution[:kind],
          matched_via: resolution[:matched_via],
          node: resolution[:node] && { id: resolution[:node].id, name: resolution[:node].name },
          instance_ids: instance_ids,
          instance_count: instance_ids.size,
          historical_instance_count: resolution[:historical_instance_count]
        }.compact,
        dependents: dependents,
        dns: {
          modeled: false,
          note: "This platform has no first-class DNS record/zone model. The closest " \
                "proxies for \"what resolves to this node\" are sdwan_services (local " \
                "/svc/<slug> + public TLS-SNI exposure) and sdwan_virtual_ips (the " \
                "overlay address other peers route to) above; actual external DNS is " \
                "operator-managed outside Powernode."
        },
        total_dependents: dependents.values.sum { |b| b[:count] || 0 },
        caveats: Array(resolution[:caveats])
      }
    end

    private

    attr_reader :account

    # ---- Target resolution ------------------------------------------------

    def resolve_target(node)
      query = node.to_s.strip
      return { error: "node identifier must not be blank" } if query.blank?

      by_node = resolve_by_node_name(query)
      return by_node if by_node

      by_instance = resolve_by_instance_name(query)
      return by_instance if by_instance

      by_provider_token = resolve_by_provider_host_token(query)
      return by_provider_token if by_provider_token

      { error: "no System::Node, System::NodeInstance, or provider cluster-node token matched #{query.inspect}",
        fuzzy_candidates: fuzzy_candidates(query) }
    end

    def resolve_by_node_name(query)
      scope = scoped(::System::Node)
      node = scope.where("lower(name) = ?", query.downcase).first
      return nil unless node

      all_instances = ::System::NodeInstance.where(node_id: node.id)
      live = all_instances.where.not(status: "terminated")
      instance_ids = live.exists? ? live.pluck(:id) : all_instances.order(created_at: :desc).limit(1).pluck(:id)

      {
        kind: "node",
        node: node,
        instance_ids: instance_ids,
        matched_via: "System::Node#name (exact match)",
        historical_instance_count: all_instances.count,
        caveats: live.exists? ? [] : ["All #{all_instances.count} NodeInstance row(s) under this Node are terminated; " \
                                      "falling back to the most recent for traversal."]
      }
    end

    def resolve_by_instance_name(query)
      scope = scoped(::System::NodeInstance)
      instance = scope.where("lower(name) = ?", query.downcase).first
      return nil unless instance

      {
        kind: "node_instance",
        node: instance.node,
        instance_ids: [ instance.id ],
        matched_via: "System::NodeInstance#name (exact match)"
      }
    end

    # "dna" / "rna" — a Proxmox (or other provider) cluster-node token that is
    # never a first-class row, only the leading path segment of
    # NodeInstance#config["cloud_instance_id"] ("dna/qemu/104"). Matches are
    # deliberately restricted to that one config key (not a fuzzy string
    # search over all config) so this can't silently misfire on an unrelated
    # substring.
    def resolve_by_provider_host_token(query)
      all_matches = scoped(::System::NodeInstance)
                      .where("config->>'cloud_instance_id' ILIKE ?", "#{sanitize_like(query)}/%")
      return nil unless all_matches.exists?

      live = all_matches.where.not(status: "terminated")
      instance_ids = live.pluck(:id)

      caveats = []
      caveats << "#{all_matches.count} historical NodeInstance row(s) carry #{query.inspect} as their " \
                  "cloud_instance_id host prefix, but all are status=terminated — nothing is currently " \
                  "placed there. (This is expected for a provider cluster-node that exists but has no " \
                  "live-provisioned instances yet.)" if instance_ids.empty?

      {
        kind: "provider_host_token",
        node: nil,
        instance_ids: instance_ids,
        matched_via: "NodeInstance#config['cloud_instance_id'] prefix #{query.inspect}/* " \
                     "(a Proxmox/provider cluster-node placement string, not a first-class Node/NodeInstance name)",
        historical_instance_count: all_matches.count,
        caveats: caveats
      }
    end

    def fuzzy_candidates(query, limit: 5)
      like = "%#{sanitize_like(query)}%"
      {
        node_names: scoped(::System::Node).where("name ILIKE ?", like).limit(limit).pluck(:name),
        node_instance_names: scoped(::System::NodeInstance).where("name ILIKE ?", like).limit(limit).distinct.pluck(:name),
        instance_pool_names: scoped(::System::InstancePool).where("name ILIKE ?", like).limit(limit).pluck(:name)
      }
    end

    def sanitize_like(str)
      str.to_s.gsub(/[%_\\]/) { |c| "\\#{c}" }
    end

    def scoped(klass)
      return klass.all unless account && klass.column_names.include?("account_id")

      klass.where(account_id: account.id)
    end

    # ---- Dependent traversal ------------------------------------------------

    # Direct FK dependents of the resolved NodeInstance(s) — reuses
    # System::NodeInstance::CASCADE_DEPENDENTS (the same table the
    # cascade-destroy controller flow uses) as the single source of truth for
    # "what has a node_instance_id pointing at this instance", rather than
    # hand-duplicating that list. A future addition there (new FK dependent
    # type) is picked up here automatically.
    def direct_dependents(instance_ids)
      ::System::NodeInstance::CASCADE_DEPENDENTS.each_with_object({}) do |entry, result|
        label = DIRECT_LABEL_OVERRIDES[entry[:klass]] || entry[:klass].underscore.tr("/", "_").pluralize
        klass = entry[:klass].safe_constantize
        unless klass
          result[label] = empty_bucket.merge(error: "#{entry[:klass]} not resolvable")
          next
        end

        scope = instance_ids.present? ? klass.where(entry[:fk] => instance_ids) : klass.none
        scope = scope.where(account_id: account.id) if account && klass.column_names.include?("account_id")
        result[label] = bucket_from(scope)
      end
    end

    # Instance pools with at least one member among the resolved instances —
    # "instance pools hosted on it" for a provider-host-token query (e.g. the
    # ci-builders pools sharing a Proxmox host), or the pool a single instance
    # belongs to.
    def instance_pool_dependents(instance_ids)
      return empty_bucket if instance_ids.blank?

      pool_ids = ::System::NodeInstance.where(id: instance_ids)
                                        .where.not(instance_pool_id: nil)
                                        .distinct.pluck(:instance_pool_id)
      return empty_bucket if pool_ids.empty?

      pools = scoped(::System::InstancePool).where(id: pool_ids)
      items = pools.map do |pool|
        members = ::System::NodeInstance.where(instance_pool_id: pool.id)
        {
          id: pool.id, name: pool.name, target_size: pool.target_size, status: pool.status,
          member_count: members.count,
          member_status_breakdown: members.group(:status).count,
          members_on_target: members.where(id: instance_ids).count
        }
      end
      { count: items.size, ids: pool_ids, items: items }
    end

    # Sdwan::VirtualIp records currently (or on failover) held by one of the
    # resolved instances' peers. Loaded in Ruby rather than a Postgres
    # array-overlap SQL fragment: VirtualIp is an operator-declared resource
    # (small, bounded), unlike NodeInstance churn, so this stays cheap while
    # avoiding uuid[]-literal SQL-construction risk.
    def virtual_ip_dependents(peer_ids)
      return empty_bucket if peer_ids.blank?

      peer_id_set = peer_ids.to_set
      matches = scoped(::Sdwan::VirtualIp).select do |vip|
        Array(vip.holder_peer_ids).any? { |id| peer_id_set.include?(id) } ||
          Array(vip.failover_holder_peer_ids).any? { |id| peer_id_set.include?(id) }
      end
      bucket_from(matches)
    end

    def service_dependents(vip_ids)
      return empty_bucket if vip_ids.blank?

      bucket_from(scoped(::Sdwan::Service).where(backend_vip_id: vip_ids))
    end

    # A peer can be either the hub a DNAT rule is declared on (sdwan_peer_id)
    # or the forwarding target (target_peer_id) — both make this node a
    # dependency of the mapping.
    def port_mapping_dependents(peer_ids)
      return empty_bucket if peer_ids.blank?

      hub_scope = scoped(::Sdwan::PortMapping).where(sdwan_peer_id: peer_ids)
      target_scope = scoped(::Sdwan::PortMapping).where(target_peer_id: peer_ids)
      bucket_from(hub_scope.or(target_scope))
    end

    # FileManagement::Storage rows (core model) whose gateway_proxy or
    # self_hosted-NFS configuration names one of the resolved instances as the
    # physical export/gateway host (configuration["gateway_node_instance_id"]
    # / configuration["export_host_node_instance_id"] — not FK-enforced
    # columns, just documented config keys on the JSON blob; see
    # FileManagement::Storage::GATEWAY_PROXY_REQUIRED_CONFIG), then the
    # StorageAssignments on OTHER instances that consume that storage. This is
    # the "other nodes' NFS mounts pointing at it" case: same-node assignments
    # are already covered by the direct storage_assignments bucket, so they're
    # excluded here to avoid double-counting.
    def cross_node_storage_dependents(instance_ids)
      return empty_bucket if instance_ids.blank?

      storage_ids = scoped(::FileManagement::Storage)
                      .where(
                        "configuration->>'gateway_node_instance_id' IN (?) OR " \
                        "configuration->>'export_host_node_instance_id' IN (?)",
                        instance_ids, instance_ids
                      ).pluck(:id)
      return empty_bucket if storage_ids.empty?

      assignments = scoped(::System::StorageAssignment)
                      .where(file_storage_id: storage_ids)
                      .where.not(node_instance_id: instance_ids)

      bucket_from(assignments).merge(exporting_storage_ids: storage_ids)
    end

    # ---- Shared helpers -----------------------------------------------------

    def empty_bucket
      { count: 0, ids: [], items: [] }
    end

    def bucket_from(scope)
      records = scope.respond_to?(:limit) ? scope.limit(ITEM_LIMIT).to_a : Array(scope).first(ITEM_LIMIT)
      count = scope.respond_to?(:count) ? scope.count : Array(scope).size
      { count: count, ids: records.map(&:id), items: records.map { |r| summarize(r) } }
    end

    def summarize(record)
      case record
      when ::Sdwan::Peer
        { id: record.id, sdwan_network_id: record.sdwan_network_id, status: record.status,
          publicly_reachable: record.publicly_reachable, assigned_address: record.assigned_address,
          tags: record.tags, node_instance_id: record.node_instance_id }
      when ::Sdwan::HostBridge
        { id: record.id, bridge_name: record.bridge_name, kind: record.kind, state: record.state,
          node_instance_id: record.node_instance_id }
      when ::Sdwan::VirtualIp
        { id: record.id, name: record.name, cidr: record.cidr, state: record.state,
          holder_peer_ids: record.holder_peer_ids, failover_holder_peer_ids: record.failover_holder_peer_ids }
      when ::Sdwan::Service
        { id: record.id, slug: record.slug, name: record.name, protocol: record.protocol,
          local_enabled: record.local_enabled, public_enabled: record.public_enabled, status: record.status,
          backend_vip_id: record.backend_vip_id }
      when ::Sdwan::PortMapping
        { id: record.id, name: record.name, listen_port: record.listen_port, protocol: record.protocol,
          hub_peer_id: record.sdwan_peer_id, target_peer_id: record.target_peer_id,
          target_virtual_ip_id: record.target_virtual_ip_id }
      when ::System::StorageAssignment
        { id: record.id, mount_path: record.mount_path, status: record.status,
          node_instance_id: record.node_instance_id, file_storage_id: record.file_storage_id }
      when ::System::InstancePool
        { id: record.id, name: record.name, target_size: record.target_size, status: record.status }
      else
        record.attributes.slice(*%w[id name status state kind mount_path node_instance_id
                                     bridge_name external_id]).symbolize_keys
      end
    end
  end
end
