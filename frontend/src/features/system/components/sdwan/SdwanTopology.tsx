import React, { useEffect, useMemo, useState } from 'react';
import { ReactFlow, Background, Controls, Handle, Position, MarkerType, type Node, type Edge } from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import { Globe, Server } from 'lucide-react';
import { sdwanApi } from '../../services/api/sdwanApi';
import type { SdwanTopologyResponse, SdwanCompiledPeerView, SdwanPeer } from '../../types/sdwan.types';

interface SdwanTopologyProps {
  networkId: string;
  refreshKey?: number;
}

/**
 * SdwanTopology — react-flow visualization of an SDWAN network's
 * peer membership and tunnel edges. Hubs render at the center;
 * spokes orbit them. Edge labels carry the AllowedIPs preview so
 * operators can confirm the routing math at a glance.
 *
 * Hub/spoke is a peer-row property (`Sdwan::Peer#publicly_reachable`),
 * not something derivable from the compiled topology view — that view
 * (`Sdwan::TopologyCompiler#compile_peer_view`) carries only
 * `peer_id` + `interface` + the compiled WireGuard edge list, with no
 * role flag or hostname. So this component also fetches the network's
 * peer roster (the same `sdwanApi.getPeers` the Peers tab already
 * uses) and correlates by `peer_id` to read the real flag plus
 * whatever operator-declared endpoint hostname exists, instead of
 * guessing hub-ness from edge-count symmetry or fabricating a label
 * from an IPv6 address fragment.
 *
 * Keeps the diagram read-only — slice 4 may add direct manipulation
 * (drag-to-attach), but the data model is "membership, not edges,"
 * so dragging a spoke into a hub corresponds to *flipping a flag*,
 * not creating a separate edge resource.
 */
export const SdwanTopology: React.FC<SdwanTopologyProps> = ({ networkId, refreshKey }) => {
  const [data, setData] = useState<SdwanTopologyResponse | null>(null);
  const [peerRows, setPeerRows] = useState<SdwanPeer[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    Promise.all([
      sdwanApi.getTopology(networkId),
      // Peer-role/hostname data degrades gracefully — a failure here
      // shouldn't block the diagram (which the topology fetch already
      // guards below); peers just render without a resolved role or
      // hostname until the roster loads.
      sdwanApi.getPeers(networkId).catch(() => ({ peers: [] as SdwanPeer[] })),
    ])
      .then(([topology, peersResult]) => {
        if (cancelled) return;
        setData(topology);
        setPeerRows(peersResult.peers);
      })
      .catch((err) => {
        if (!cancelled) setError(err instanceof Error ? err.message : 'Failed to load topology');
      })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [networkId, refreshKey]);

  const peersById = useMemo(() => new Map(peerRows.map((p) => [p.id, p])), [peerRows]);
  const { nodes, edges } = useMemo(() => buildFlow(data, peersById), [data, peersById]);

  if (loading) return <div className="p-4 text-theme-secondary">Loading topology…</div>;
  if (error)   return <div className="p-3 bg-theme-danger-bg text-theme-danger-fg rounded text-sm">{error}</div>;
  if (!data || data.peer_count === 0) {
    return (
      <div className="p-12 text-center text-theme-secondary text-sm">
        No peers attached. Topology renders once at least one peer joins the network.
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <div className="bg-theme-interactive-primary border border-theme rounded" style={{ height: 480 }}>
        <ReactFlow
          nodes={nodes}
          edges={edges}
          nodeTypes={NODE_TYPES}
          fitView
          nodesDraggable={false}
          nodesConnectable={false}
          elementsSelectable={false}
          proOptions={{ hideAttribution: true }}
        >
          <Background />
          <Controls showInteractive={false} />
        </ReactFlow>
      </div>
      <Legend />
    </div>
  );
};

// ─── Custom node renderers ──────────────────────────────────────────
// Distinct styling for hub vs spoke, theme-token only (mirrors the
// custom-node approach in components/network/SystemTopology.tsx).

interface PeerNodeData {
  label: string;
  [key: string]: unknown;
}

const HubNode: React.FC<{ data: PeerNodeData }> = ({ data }) => (
  <div className="px-3 py-2 rounded-lg border-2 border-theme-info-border bg-theme-surface shadow-sm min-w-[150px] text-center">
    <Handle type="target" position={Position.Top} className="!bg-theme-info-bg" />
    <div className="flex items-center justify-center gap-1.5">
      <Globe size={14} className="text-theme-info-fg" />
      <span className="text-xs font-medium text-theme-primary">{data.label}</span>
    </div>
    <div className="text-[10px] text-theme-secondary mt-0.5">hub</div>
    <Handle type="source" position={Position.Bottom} className="!bg-theme-info-bg" />
  </div>
);

const SpokeNode: React.FC<{ data: PeerNodeData }> = ({ data }) => (
  <div className="px-3 py-2 rounded-lg border border-theme bg-theme-surface shadow-sm min-w-[140px] text-center">
    <Handle type="target" position={Position.Top} className="!bg-theme-background-secondary" />
    <div className="flex items-center justify-center gap-1.5">
      <Server size={14} className="text-theme-secondary" />
      <span className="text-xs text-theme-primary">{data.label}</span>
    </div>
    <div className="text-[10px] text-theme-secondary mt-0.5">spoke</div>
    <Handle type="source" position={Position.Bottom} className="!bg-theme-background-secondary" />
  </div>
);

const NODE_TYPES = {
  hub: HubNode,
  spoke: SpokeNode,
} as const;

const Legend: React.FC = () => (
  <div className="flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-theme-secondary px-1">
    <span className="flex items-center gap-1.5">
      <Globe size={12} className="text-theme-info-fg" />
      <span>Hub — publicly reachable, other peers dial in</span>
    </span>
    <span className="flex items-center gap-1.5">
      <Server size={12} className="text-theme-secondary" />
      <span>Spoke — outbound only</span>
    </span>
  </div>
);

// ─── Flow builder ───────────────────────────────────────────────────

function buildFlow(
  data: SdwanTopologyResponse | null,
  peersById: Map<string, SdwanPeer>
): { nodes: Node[]; edges: Edge[] } {
  if (!data) return { nodes: [], edges: [] };

  const peers = data.peers;
  const hubs = peers.filter((p) => isHub(p, peersById));
  const spokes = peers.filter((p) => !isHub(p, peersById));

  // Layout: hubs in a vertical line at center; spokes radially around them.
  const nodes: Node[] = [];
  hubs.forEach((p, i) => {
    nodes.push({
      id: p.peer_id,
      type: 'hub',
      position: { x: 0, y: i * 140 - (hubs.length - 1) * 70 },
      data: { label: peerLabel(p, peersById) },
    });
  });
  const radius = Math.max(180, spokes.length * 28);
  spokes.forEach((p, i) => {
    const angle = (i / Math.max(spokes.length, 1)) * 2 * Math.PI;
    nodes.push({
      id: p.peer_id,
      type: 'spoke',
      position: { x: radius * Math.cos(angle), y: radius * Math.sin(angle) },
      data: { label: peerLabel(p, peersById) },
    });
  });

  // Edges: each peer's compiled `peers` list is exactly the wireguard
  // [Peer] sections it would receive. We render them directly.
  const edges: Edge[] = [];
  for (const p of peers) {
    for (const e of p.peers) {
      const id = `${p.peer_id}->${e.peer_id}`;
      edges.push({
        id,
        source: p.peer_id,
        target: e.peer_id,
        markerEnd: { type: MarkerType.ArrowClosed },
        animated: false,
        label: e.allowed_ips.length > 1 ? `${e.allowed_ips[0]} +${e.allowed_ips.length - 1}` : e.allowed_ips[0],
        labelStyle: { fontSize: 10, fill: 'var(--color-text-secondary)' },
        labelBgStyle: { fill: 'var(--color-surface)', fillOpacity: 0.92 },
        style: { stroke: 'var(--color-border)' },
      });
    }
  }
  return { nodes, edges };
}

// Real flag from the peer roster (Sdwan::Peer#publicly_reachable via
// GET .../peers), correlated by peer_id. Unknown peers (roster still
// loading, or a fetch failure degraded to []) render as spokes rather
// than guessing from edge-count shape.
function isHub(p: SdwanCompiledPeerView, peersById: Map<string, SdwanPeer>): boolean {
  return peersById.get(p.peer_id)?.publicly_reachable === true;
}

// Prefer the peer's operator-declared hostname (whichever endpoint
// host column is populated — v6 preferred, matching the compiler's
// own v6-preferred effective-endpoint resolution) over a synthesized
// address fragment. Spokes are outbound-only and rarely carry one, so
// they typically fall through to the address-derived short form.
function peerLabel(p: SdwanCompiledPeerView, peersById: Map<string, SdwanPeer>): string {
  const peer = peersById.get(p.peer_id);
  const hostname = peer?.endpoint_host_v6 || peer?.endpoint_host_v4 || peer?.endpoint_host;
  if (hostname) return hostname;
  return shortAddress(peer?.assigned_address ?? p.interface.address);
}

// Fallback only — trims the prefix length and keeps the last two
// hextets, enough to tell peers on a shared /64 apart without
// overflowing the node width.
function shortAddress(address: string): string {
  const withoutPrefix = address.replace(/\/\d+$/, '');
  const tail = withoutPrefix.split(':').slice(-2).join(':');
  return `…${tail}`;
}
