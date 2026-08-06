// Fleet topology data layer — assembles the provider → node → instance
// containment tree (plus SDWAN membership) from the existing system
// list APIs. No new backend endpoint: everything here is a read of a
// surface the Compute/SDWAN hubs already consume.
//
// Fetch budget (gap G3 calls for "at most a few fetches"):
//   4 fixed calls, issued in parallel —
//     nodes, node_templates, provider_connections, network topology
//   + a bounded fan-out for the two collections the API only exposes
//     nested: node instances (per node) and SDWAN peers (per network).
//     Both fan-outs are capped by the constants below and every call is
//     soft-fetched, so one 403/500 degrades that lane instead of the page.
//
// Everything degrades: no nodes → empty state; no templates → no module
// chips; no provider connections → grouping falls back down the ladder in
// `resolveGroup`; no SDWAN networks → zero peer fetches and no membership
// lane.

import { nodesApi } from '../../services/api/nodesApi';
import { templatesApi } from '../../services/api/templatesApi';
import { providersApi } from '../../services/api/providersApi';
import { sdwanApi } from '../../services/api/sdwanApi';
import { networkTopologyApi } from '../../services/api/networkTopologyApi';
import type {
  SystemNode,
  SystemNodeInstance,
  SystemNodeTemplate,
  SystemProviderConnection,
} from '../../types/system.types';
import type { NetworkTopologyResponse } from '../../types/network_topology.types';

// ─── Fetch bounds ───────────────────────────────────────────────────

/** Nodes pulled for the graph (also the instance fan-out cap). */
export const MAX_NODES = 24;
/** Templates pulled for module chips + platform grouping. */
export const MAX_TEMPLATES = 100;
/** SDWAN networks whose peer list is fetched for membership edges. */
export const MAX_NETWORKS_WITH_PEERS = 6;
/** Instances drawn under one node before the rest collapse into a "+N" chip. */
export const MAX_INSTANCES_PER_NODE = 6;

// ─── Snapshot shapes ────────────────────────────────────────────────

export type FleetGroupKind = 'provider' | 'platform' | 'template' | 'unassigned';

export interface FleetGroup {
  id: string;
  label: string;
  kind: FleetGroupKind;
  nodeIds: string[];
}

export interface FleetNodeRecord {
  node: SystemNode;
  groupId: string;
  /** Module names from the node's template (chips on the node card). */
  modules: string[];
  /** Instances drawn under this node (capped — see `hiddenInstanceCount`). */
  instances: SystemNodeInstance[];
  /** Instances this node has beyond the drawn ones. */
  hiddenInstanceCount: number;
  /** False when the instance fan-out was skipped for this node. */
  instancesLoaded: boolean;
}

export interface FleetNetworkRecord {
  id: string;
  label: string;
  cidr?: string;
  status?: string;
}

export interface FleetMembership {
  instanceId: string;
  networkId: string;
  status?: string;
}

export interface FleetTopologySnapshot {
  groups: FleetGroup[];
  nodes: FleetNodeRecord[];
  networks: FleetNetworkRecord[];
  memberships: FleetMembership[];
  /** Nodes returned by the API beyond `MAX_NODES` (banner copy). */
  truncatedNodeCount: number;
  totalNodeCount: number;
}

export const EMPTY_SNAPSHOT: FleetTopologySnapshot = {
  groups: [],
  nodes: [],
  networks: [],
  memberships: [],
  truncatedNodeCount: 0,
  totalNodeCount: 0,
};

// ─── Loader ─────────────────────────────────────────────────────────

/**
 * Swallow a per-lane failure and return the fallback. Mirrors
 * `overviewApi.softFetch` — an operator without `sdwan.*.read` still gets
 * a working graph, minus the SDWAN lane.
 */
async function softFetch<T>(promise: Promise<T>, fallback: T): Promise<T> {
  try {
    return await promise;
  } catch {
    return fallback;
  }
}

export async function loadFleetTopology(): Promise<FleetTopologySnapshot> {
  const [nodesResult, templates, connections, networkTopology] = await Promise.all([
    softFetch(
      nodesApi.getNodes({ per_page: MAX_NODES }).then((r) => ({
        nodes: r.nodes ?? [],
        total: r.meta?.total_count ?? (r.nodes ?? []).length,
      })),
      { nodes: [] as SystemNode[], total: 0 },
    ),
    softFetch(
      templatesApi.getTemplates({ per_page: MAX_TEMPLATES }).then((r) => r.templates ?? []),
      [] as SystemNodeTemplate[],
    ),
    softFetch(providersApi.getProviderConnections(), [] as SystemProviderConnection[]),
    softFetch<NetworkTopologyResponse | null>(networkTopologyApi.getTopology(), null),
  ]);

  const allNodes = nodesResult.nodes;
  const totalNodeCount = nodesResult.total;
  const drawnNodes = allNodes.slice(0, MAX_NODES);

  // Instances are only exposed nested under a node, so this is a bounded
  // parallel fan-out rather than one list call.
  const instanceLists = await Promise.all(
    drawnNodes.map((node) =>
      softFetch(
        nodesApi.getNodeInstances(node.id).then((r) => r.node_instances ?? []),
        [] as SystemNodeInstance[],
      ),
    ),
  );

  const networks = extractNetworks(networkTopology);
  const drawnInstanceIds = new Set(
    instanceLists.flat().map((instance) => instance.id),
  );
  const memberships = await loadMemberships(networks, drawnInstanceIds);

  const templateById = new Map(templates.map((t) => [t.id, t]));
  const providerByConnectionId = new Map(
    connections.map((c) => [c.id, c.provider_name || c.name] as const),
  );

  const groups: FleetGroup[] = [];
  const groupIndex = new Map<string, FleetGroup>();
  const nodeRecords: FleetNodeRecord[] = drawnNodes.map((node, i) => {
    const instances = instanceLists[i] ?? [];
    const template = node.node_template_id ? templateById.get(node.node_template_id) : undefined;
    const group = resolveGroup(node, instances, template, providerByConnectionId);

    let existing = groupIndex.get(group.id);
    if (!existing) {
      existing = { ...group, nodeIds: [] };
      groupIndex.set(group.id, existing);
      groups.push(existing);
    }
    existing.nodeIds.push(node.id);

    return {
      node,
      groupId: group.id,
      modules: (template?.modules ?? []).map((m) => m.name).filter(Boolean),
      instances: instances.slice(0, MAX_INSTANCES_PER_NODE),
      hiddenInstanceCount: Math.max(0, instances.length - MAX_INSTANCES_PER_NODE),
      instancesLoaded: true,
    };
  });

  return {
    groups,
    nodes: nodeRecords,
    networks,
    memberships,
    truncatedNodeCount: Math.max(0, totalNodeCount - drawnNodes.length),
    totalNodeCount,
  };
}

// ─── Helpers ────────────────────────────────────────────────────────

/**
 * SDWAN networks come from the shared topology endpoint (one call that
 * already carries label + CIDR + status). Its node ids are prefixed
 * `network-<uuid>` by `System::TopologyBuilder`; strip that to recover the
 * `Sdwan::Network` id the peers endpoint keys on.
 */
export function extractNetworks(
  topology: NetworkTopologyResponse | null,
): FleetNetworkRecord[] {
  return (topology?.nodes ?? [])
    .filter((n) => n.type === 'network')
    .map((n) => ({
      id: n.id.replace(/^network-/, ''),
      label: n.data.label,
      cidr: n.data.cidr_64,
      status: n.data.status,
    }));
}

/**
 * `Sdwan::Peer` carries `node_instance_id`, which is the only link between
 * a fleet instance and an overlay network. Bounded fan-out; memberships
 * whose instance isn't drawn are dropped (dangling edges break layout).
 */
async function loadMemberships(
  networks: FleetNetworkRecord[],
  drawnInstanceIds: Set<string>,
): Promise<FleetMembership[]> {
  if (networks.length === 0 || drawnInstanceIds.size === 0) return [];

  const peerLists = await Promise.all(
    networks.slice(0, MAX_NETWORKS_WITH_PEERS).map((network) =>
      softFetch(
        sdwanApi.getPeers(network.id).then((r) =>
          (r.peers ?? []).map((peer) => ({
            instanceId: peer.node_instance_id,
            networkId: network.id,
            status: peer.status as string | undefined,
          })),
        ),
        [] as FleetMembership[],
      ),
    ),
  );

  return peerLists
    .flat()
    .filter((m) => m.instanceId && drawnInstanceIds.has(m.instanceId));
}

/**
 * Grouping ladder — the fleet has no first-class "provider of a node"
 * field, so resolve the best available lane:
 *
 *   1. provider — an instance's `config.provider_connection_id` resolves
 *      through the provider-connections list to a provider name (cloud
 *      instances created through CreateInstanceModal carry this).
 *   2. platform — the node's template's NodePlatform (bare-metal fleets,
 *      where "where it runs" is the boot image, not a cloud account).
 *   3. template — last structural grouping available.
 *   4. unassigned — nothing known.
 */
export function resolveGroup(
  node: SystemNode,
  instances: SystemNodeInstance[],
  template: SystemNodeTemplate | undefined,
  providerByConnectionId: Map<string, string>,
): Omit<FleetGroup, 'nodeIds'> {
  for (const instance of instances) {
    const connectionId = readStringConfig(instance.config, 'provider_connection_id');
    const providerName = connectionId ? providerByConnectionId.get(connectionId) : undefined;
    if (providerName) {
      return { id: `provider:${providerName}`, label: providerName, kind: 'provider' };
    }
  }

  if (template?.node_platform_name) {
    return {
      id: `platform:${template.node_platform_name}`,
      label: template.node_platform_name,
      kind: 'platform',
    };
  }

  const templateName = node.node_template_name || template?.name;
  if (templateName) {
    return { id: `template:${templateName}`, label: templateName, kind: 'template' };
  }

  return { id: 'unassigned', label: 'Unassigned', kind: 'unassigned' };
}

function readStringConfig(
  config: Record<string, unknown> | undefined,
  key: string,
): string | undefined {
  const value = config?.[key];
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

// ─── Derived status ─────────────────────────────────────────────────

export type FleetNodeHealth = 'running' | 'partial' | 'idle' | 'empty' | 'disabled';

/**
 * Node health for the card's status dot. Derived from the instances we
 * drew when available, otherwise from the serializer's counts.
 */
export function nodeHealth(record: FleetNodeRecord): FleetNodeHealth {
  if (!record.node.enabled) return 'disabled';

  const total = record.node.instance_count ?? record.instances.length;
  if (total === 0) return 'empty';

  const running = record.instances.length > 0
    ? record.instances.filter((i) => i.status === 'running').length
    : (record.node.running_instances_count ?? 0);

  if (running === 0) return 'idle';
  return running >= total ? 'running' : 'partial';
}
