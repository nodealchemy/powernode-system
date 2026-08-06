// Pure layout for the fleet graph.
//
// `SystemTopology` gets its coordinates from the server (the SDWAN
// topology endpoint stamps `position` on every node). The fleet graph has
// no such endpoint, so the same layered-hierarchy convention is computed
// here instead — same tiers-flow-downward shape, same "one lane per
// family" edge routing, just client-side.
//
// Tiers (top → bottom):
//   1. group     — provider / platform lane (see resolveGroup's ladder)
//   2. node      — System::Node card
//   3. instance   — System::NodeInstance under its node
//   4. network   — SDWAN network the instances peer into
//
// Columns: each drawn instance owns one COLUMN_WIDTH slot; a node is
// centred over its instances' slots; a group is centred over its nodes.
// A node with no instances still reserves one slot so the row stays even.

import type { CSSProperties } from 'react';
import { MarkerType, type Edge, type Node } from '@xyflow/react';
import type { FleetNodeHealth, FleetTopologySnapshot } from './fleetTopologyData';
import { nodeHealth } from './fleetTopologyData';

// ─── Geometry ───────────────────────────────────────────────────────

export const COLUMN_WIDTH = 210;
export const NODE_GAP = 36;
export const GROUP_GAP = 90;

export const GROUP_WIDTH = 220;
export const NODE_WIDTH = 200;
export const INSTANCE_WIDTH = 180;
export const NETWORK_WIDTH = 190;

export const TIER_GROUP_Y = 0;
export const TIER_NODE_Y = 150;
export const TIER_INSTANCE_Y = 330;
export const TIER_NETWORK_Y = 540;

// ─── Node data shapes ───────────────────────────────────────────────

export interface FleetGroupNodeData {
  label: string;
  kind: string;
  node_count: number;
  instance_count: number;
}

export interface FleetNodeCardData {
  label: string;
  node_id: string;
  health: FleetNodeHealth;
  enabled: boolean;
  instance_count: number;
  running_count: number;
  template_name?: string;
  modules: string[];
  hidden_instance_count: number;
}

export interface FleetInstanceNodeData {
  label: string;
  instance_id: string;
  node_id: string;
  status: string;
  variety: string;
  address?: string;
  boot_image_drifted: boolean;
}

export interface FleetNetworkNodeData {
  label: string;
  cidr?: string;
  status?: string;
  member_count: number;
}

export type FleetEdgeKind = 'contains' | 'hosts' | 'sdwan';

// ─── Builder ────────────────────────────────────────────────────────

export interface FleetFlow {
  nodes: Node[];
  edges: Edge[];
}

/**
 * xyflow stores every node's payload in one `Record<string, unknown>`
 * slot, so each renderer's typed shape narrows back out at the boundary —
 * the same cast SystemTopology's `buildFlow` makes, done once here.
 */
const asFlowData = (data: object): Record<string, unknown> =>
  data as unknown as Record<string, unknown>;

export function buildFleetFlow(snapshot: FleetTopologySnapshot): FleetFlow {
  const nodes: Node[] = [];
  const edges: Edge[] = [];

  const recordById = new Map(snapshot.nodes.map((r) => [r.node.id, r]));
  let cursorX = 0;

  for (const group of snapshot.groups) {
    const groupStartX = cursorX;
    let groupInstanceCount = 0;
    let placedNodes = 0;

    for (const nodeId of group.nodeIds) {
      const record = recordById.get(nodeId);
      if (!record) continue;

      const subtreeStartX = cursorX;
      const slots = Math.max(1, record.instances.length);

      record.instances.forEach((instance, i) => {
        const instanceData: FleetInstanceNodeData = {
          label: instance.name,
          instance_id: instance.id,
          node_id: record.node.id,
          status: instance.status,
          variety: instance.variety,
          address:
            instance.vpn_ip_address ||
            instance.private_ip_address ||
            instance.public_ip_address,
          boot_image_drifted: Boolean(instance.boot_image_drifted),
        };
        nodes.push({
          id: instanceNodeId(instance.id),
          type: 'fleet-instance',
          position: {
            x: subtreeStartX + i * COLUMN_WIDTH + (COLUMN_WIDTH - INSTANCE_WIDTH) / 2,
            y: TIER_INSTANCE_Y,
          },
          data: asFlowData(instanceData),
        });

        edges.push(
          containmentEdge(
            `hosts-${record.node.id}-${instance.id}`,
            fleetNodeId(record.node.id),
            instanceNodeId(instance.id),
            'hosts',
          ),
        );
      });

      groupInstanceCount += record.node.instance_count ?? record.instances.length;

      const subtreeWidth = slots * COLUMN_WIDTH;
      const cardData: FleetNodeCardData = {
        label: record.node.name,
        node_id: record.node.id,
        health: nodeHealth(record),
        enabled: record.node.enabled,
        instance_count: record.node.instance_count ?? record.instances.length,
        running_count: record.node.running_instances_count ?? 0,
        template_name: record.node.node_template_name,
        modules: record.modules,
        hidden_instance_count: record.hiddenInstanceCount,
      };
      nodes.push({
        id: fleetNodeId(record.node.id),
        type: 'fleet-node',
        position: {
          x: subtreeStartX + subtreeWidth / 2 - NODE_WIDTH / 2,
          y: TIER_NODE_Y,
        },
        data: asFlowData(cardData),
      });

      edges.push(
        containmentEdge(
          `contains-${group.id}-${record.node.id}`,
          groupNodeId(group.id),
          fleetNodeId(record.node.id),
          'contains',
        ),
      );

      cursorX = subtreeStartX + subtreeWidth + NODE_GAP;
      placedNodes += 1;
    }

    if (placedNodes === 0) continue;

    const groupSpan = cursorX - NODE_GAP - groupStartX;
    const groupData: FleetGroupNodeData = {
      label: group.label,
      kind: group.kind,
      node_count: placedNodes,
      instance_count: groupInstanceCount,
    };
    nodes.push({
      id: groupNodeId(group.id),
      type: 'fleet-group',
      position: {
        x: groupStartX + groupSpan / 2 - GROUP_WIDTH / 2,
        y: TIER_GROUP_Y,
      },
      data: asFlowData(groupData),
    });

    cursorX += GROUP_GAP - NODE_GAP;
  }

  // SDWAN lane — a row centred under the whole fleet. Only networks that
  // at least one drawn instance peers into get an edge; unattached
  // networks still render so the operator can see they exist.
  const totalWidth = Math.max(cursorX - GROUP_GAP, COLUMN_WIDTH);
  const memberCounts = new Map<string, number>();
  for (const membership of snapshot.memberships) {
    memberCounts.set(membership.networkId, (memberCounts.get(membership.networkId) ?? 0) + 1);
  }

  snapshot.networks.forEach((network, i) => {
    const laneWidth = snapshot.networks.length * COLUMN_WIDTH;
    const laneStart = totalWidth / 2 - laneWidth / 2;
    const networkData: FleetNetworkNodeData = {
      label: network.label,
      cidr: network.cidr,
      status: network.status,
      member_count: memberCounts.get(network.id) ?? 0,
    };
    nodes.push({
      id: networkNodeId(network.id),
      type: 'fleet-network',
      position: {
        x: laneStart + i * COLUMN_WIDTH + (COLUMN_WIDTH - NETWORK_WIDTH) / 2,
        y: TIER_NETWORK_Y,
      },
      data: asFlowData(networkData),
    });
  });

  const drawnNetworkIds = new Set(snapshot.networks.map((n) => n.id));
  for (const membership of snapshot.memberships) {
    if (!drawnNetworkIds.has(membership.networkId)) continue;
    edges.push({
      ...containmentEdge(
        `sdwan-${membership.instanceId}-${membership.networkId}`,
        instanceNodeId(membership.instanceId),
        networkNodeId(membership.networkId),
        'sdwan',
      ),
      animated: membership.status === 'active',
    });
  }

  return { nodes, edges };
}

// ─── Edge helpers ───────────────────────────────────────────────────

/**
 * Edges reuse SystemTopology's 'dodging-smooth' convention: smoothstep
 * routing with a per-edge offset hash so parallel edges fan out at the
 * elbow instead of stacking. Each family gets its own lane band via
 * `center_y` so containment and SDWAN edges never share a bend line.
 */
function containmentEdge(
  id: string,
  source: string,
  target: string,
  kind: FleetEdgeKind,
): Edge {
  const styling = EDGE_STYLING[kind];
  return {
    id,
    source,
    target,
    type: 'dodging-smooth',
    data: { kind, center_y: styling.centerY },
    style: styling.style,
    markerEnd: {
      type: MarkerType.ArrowClosed,
      color: styling.markerColor,
      width: 12,
      height: 12,
    },
  };
}

const EDGE_STYLING: Record<
  FleetEdgeKind,
  { style: CSSProperties; markerColor: string; centerY: number }
> = {
  contains: {
    style: { stroke: '#64748b', strokeWidth: 1.5, strokeDasharray: '6 4' },
    markerColor: '#64748b',
    centerY: (TIER_GROUP_Y + TIER_NODE_Y) / 2 + 30,
  },
  hosts: {
    style: { stroke: '#94a3b8', strokeWidth: 1.5 },
    markerColor: '#94a3b8',
    centerY: (TIER_NODE_Y + TIER_INSTANCE_Y) / 2 + 30,
  },
  sdwan: {
    style: { stroke: '#10b981', strokeWidth: 2, strokeDasharray: '4 3' },
    markerColor: '#10b981',
    centerY: (TIER_INSTANCE_Y + TIER_NETWORK_Y) / 2 + 30,
  },
};

// ─── Id helpers ─────────────────────────────────────────────────────
//
// Prefixed so a NodeInstance id and its Node id can never collide in the
// flow's id space, and so `NODE_TYPES` lookups stay unambiguous.

export const groupNodeId = (id: string): string => `group-${id}`;
export const fleetNodeId = (id: string): string => `node-${id}`;
export const instanceNodeId = (id: string): string => `instance-${id}`;
export const networkNodeId = (id: string): string => `network-${id}`;
