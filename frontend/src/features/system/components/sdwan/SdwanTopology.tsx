import React, { useEffect, useMemo, useState } from 'react';
import { ReactFlow, Background, Controls, MarkerType, type Node, type Edge } from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import { sdwanApi } from '../../services/api/sdwanApi';
import type { SdwanTopologyResponse, SdwanCompiledPeerView } from '../../types/sdwan.types';

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
 * Keeps the diagram read-only — slice 4 may add direct manipulation
 * (drag-to-attach), but the data model is "membership, not edges,"
 * so dragging a spoke into a hub corresponds to *flipping a flag*,
 * not creating a separate edge resource.
 */
export const SdwanTopology: React.FC<SdwanTopologyProps> = ({ networkId, refreshKey }) => {
  const [data, setData] = useState<SdwanTopologyResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    sdwanApi.getTopology(networkId)
      .then((d) => { if (!cancelled) setData(d); })
      .catch((err) => {
        if (!cancelled) setError(err instanceof Error ? err.message : 'Failed to load topology');
      })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [networkId, refreshKey]);

  const { nodes, edges } = useMemo(() => buildFlow(data), [data]);

  if (loading) return <div className="p-4 text-theme-secondary">Loading topology…</div>;
  if (error)   return <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>;
  if (!data || data.peer_count === 0) {
    return (
      <div className="p-12 text-center text-theme-secondary text-sm">
        No peers attached. Topology renders once at least one peer joins the network.
      </div>
    );
  }

  return (
    <div className="bg-theme-primary border border-theme-border rounded" style={{ height: 480 }}>
      <ReactFlow
        nodes={nodes}
        edges={edges}
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
  );
};

function buildFlow(data: SdwanTopologyResponse | null): { nodes: Node[]; edges: Edge[] } {
  if (!data) return { nodes: [], edges: [] };

  const peers = data.peers;
  const hubs = peers.filter((p) => isHub(p));
  const spokes = peers.filter((p) => !isHub(p));

  // Layout: hubs in a vertical line at center; spokes radially around them.
  const nodes: Node[] = [];
  hubs.forEach((p, i) => {
    nodes.push({
      id: p.peer_id,
      position: { x: 0, y: i * 140 - (hubs.length - 1) * 70 },
      data: { label: peerLabel(p, true) },
      style: peerStyle(true),
      type: 'default',
    });
  });
  const radius = Math.max(180, spokes.length * 28);
  spokes.forEach((p, i) => {
    const angle = (i / Math.max(spokes.length, 1)) * 2 * Math.PI;
    nodes.push({
      id: p.peer_id,
      position: { x: radius * Math.cos(angle), y: radius * Math.sin(angle) },
      data: { label: peerLabel(p, false) },
      style: peerStyle(false),
      type: 'default',
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
        labelStyle: { fontSize: 10, fill: 'currentColor' },
      });
    }
  }
  return { nodes, edges };
}

function isHub(p: SdwanCompiledPeerView): boolean {
  // The compiled view doesn't directly carry the publicly_reachable flag
  // (that's a peer-row property). We infer hub-ness from edge symmetry:
  // hubs see every other peer, spokes see only hubs. If this peer's
  // own peers list size > 1, it's a hub (sees multiple); otherwise spoke.
  // For 1-peer networks this returns false (the single peer has no edges)
  // — fine, the diagram just shows it standalone.
  return p.peers.length > 1;
}

function peerLabel(p: SdwanCompiledPeerView, hub: boolean): string {
  const suffix = p.interface.address.split(':').slice(-2).join(':').replace('/128', '');
  return `${hub ? '🌐 ' : ''}…${suffix}`;
}

function peerStyle(hub: boolean): Record<string, string | number> {
  return {
    background: hub ? 'var(--theme-accent-bg, #1e3a8a)' : 'var(--theme-secondary-bg, #1f2937)',
    color: 'var(--theme-primary, #fff)',
    border: hub ? '2px solid var(--theme-accent, #3b82f6)' : '1px solid var(--theme-border, #374151)',
    borderRadius: 6,
    padding: 8,
    fontSize: 12,
    minWidth: 140,
    textAlign: 'center',
  };
}
