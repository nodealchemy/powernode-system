import React, { useEffect, useMemo, useState } from 'react';
import {
  ReactFlow,
  Background,
  Controls,
  MarkerType,
  BaseEdge,
  getSmoothStepPath,
  type Node,
  type Edge,
  type NodeProps,
  type EdgeProps,
  Handle,
  Position,
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import './SystemTopology.css';
import { Server, Globe2, Network as NetworkIcon, Shield } from 'lucide-react';
import { networkTopologyApi } from '../../services/api/networkTopologyApi';
import type {
  NetworkTopologyResponse,
  TopologyNode,
  TopologyEdge,
  TopologyNodeData,
  HandleCounts,
} from '../../types/network_topology.types';

/**
 * SystemTopology — system-wide @xyflow/react visualization of the
 * SDWAN + federation landscape for an account.
 *
 * Layout (computed server-side, Cisco/AWS/draw.io layered hierarchy):
 *   - Tier 1 (top):    Self platform at (0, TIER_SELF_Y)
 *   - Tier 2 (middle): SDWAN networks as a horizontal row at TIER_NETWORK_Y
 *   - Tier 3 (bottom): Federation peers grouped into vertical lanes under
 *                      their primary bridged network at TIER_PEER_Y;
 *                      unbridged peers land in an overflow lane on the right
 *
 * Edges use a custom 'dodging-smooth' type — smoothstep routing
 * (orthogonal right-angle bends with rounded corners, the
 * Visio/Lucidchart/draw.io convention) with a per-edge offset hash
 * so parallel edges fan out at the elbow instead of stacking on top
 * of each other. Each node's source handle sits on Position.Bottom
 * and target handle on Position.Top so edges flow cleanly downward.
 *
 * Edge types:
 *   - membership    (self → network — dashed)
 *   - bridge        (peer → network — animated when active)
 *   - grant_summary (self → peer — label shows grant count)
 *
 * Plan reference: Decentralized Federation §K.5 + P4.5.7 + P4.5.8.
 */
interface SystemTopologyProps {
  refreshKey?: number;
}

export const SystemTopology: React.FC<SystemTopologyProps> = ({ refreshKey }) => {
  const [data, setData] = useState<NetworkTopologyResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    networkTopologyApi
      .getTopology()
      .then((d) => {
        if (!cancelled) setData(d);
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'Failed to load topology');
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [refreshKey]);

  const { nodes, edges } = useMemo(() => buildFlow(data), [data]);

  if (loading) {
    return <div className="p-4 text-theme-secondary">Loading topology…</div>;
  }
  if (error) {
    return (
      <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>
    );
  }
  if (!data) {
    return null;
  }

  const empty = data.stats.peer_count === 0 && data.stats.network_count === 0;
  if (empty) {
    return (
      <div className="p-12 text-center text-theme-secondary text-sm">
        No SDWAN networks or federation peers yet. The topology populates as you create them.
      </div>
    );
  }

  return (
    <div
      className="system-topology bg-theme-surface border border-theme rounded-lg overflow-hidden"
      style={{ height: 640 }}
    >
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={NODE_TYPES}
        edgeTypes={EDGE_TYPES}
        fitView
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable
        proOptions={{ hideAttribution: true }}
        minZoom={0.2}
        maxZoom={2}
      >
        <Background gap={24} />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  );
};

// ─── Multi-handle renderer ──────────────────────────────────────────
//
// xyflow expects each connectable point on a node to be its own
// <Handle> with a unique `id`. The backend stamps handle_counts on
// every node and source_handle/target_handle on every edge, so the
// renderer just maps those counts to evenly-spread Handle dots.
//
// Layout formula: spread N handles at `(i+1)/(N+1)` along the edge
// — for N=1 that's 50%, for N=4 that's 20/40/60/80%. Source-top
// handles get an additional 8px upward lift so they don't collide
// with target-top handles on peer nodes (which carry both).

const handlePct = (i: number, n: number) => `${((i + 1) / (n + 1)) * 100}%`;

const MultiHandles: React.FC<{ counts?: HandleCounts }> = ({ counts }) => {
  if (!counts) return null;
  const handles: React.ReactNode[] = [];
  for (let i = 0; i < counts.target_top; i++) {
    handles.push(
      <Handle
        key={`tt-${i}`}
        id={`t_top_${i}`}
        type="target"
        position={Position.Top}
        style={{ left: handlePct(i, counts.target_top) }}
      />,
    );
  }
  for (let i = 0; i < counts.target_bottom; i++) {
    handles.push(
      <Handle
        key={`tb-${i}`}
        id={`t_bot_${i}`}
        type="target"
        position={Position.Bottom}
        style={{ left: handlePct(i, counts.target_bottom) }}
      />,
    );
  }
  for (let i = 0; i < counts.source_top; i++) {
    handles.push(
      <Handle
        key={`st-${i}`}
        id={`s_top_${i}`}
        type="source"
        position={Position.Top}
        style={{ left: handlePct(i, counts.source_top), top: '-8px' }}
      />,
    );
  }
  for (let i = 0; i < counts.source_bottom; i++) {
    handles.push(
      <Handle
        key={`sb-${i}`}
        id={`s_bot_${i}`}
        type="source"
        position={Position.Bottom}
        style={{ left: handlePct(i, counts.source_bottom) }}
      />,
    );
  }
  return <>{handles}</>;
};

// ─── Custom node renderers ──────────────────────────────────────────

const SelfNode: React.FC<NodeProps> = ({ data }) => {
  const d = data as unknown as TopologyNodeData;
  return (
    <div className="px-4 py-3 bg-theme-info/10 border-2 border-theme-info rounded-lg shadow-sm min-w-[180px] text-center">
      <MultiHandles counts={d.handle_counts} />
      <Server className="w-5 h-5 mx-auto mb-1 text-theme-info" />
      <div className="font-semibold text-sm text-theme-info">{d.label}</div>
      {d.subtitle && <div className="text-xs text-theme-secondary mt-0.5">{d.subtitle}</div>}
    </div>
  );
};

const NetworkNode: React.FC<NodeProps> = ({ data }) => {
  const d = data as unknown as TopologyNodeData;
  return (
    <div className="px-3 py-2 bg-theme-surface border border-theme rounded-lg shadow-sm min-w-[160px]">
      <MultiHandles counts={d.handle_counts} />
      <div className="flex items-center gap-2">
        <NetworkIcon className="w-4 h-4 text-theme-secondary" />
        <span className="font-medium text-sm text-theme-primary">{d.label}</span>
      </div>
      <div className="text-xs text-theme-secondary mt-1 font-mono">{d.cidr_64}</div>
      <div className="flex items-center gap-2 text-[10px] text-theme-secondary mt-1">
        <span className="px-1.5 py-0.5 bg-theme-background-secondary rounded">
          {d.routing_protocol}
        </span>
        <span>{d.status}</span>
      </div>
    </div>
  );
};

const PlatformPeerNode: React.FC<NodeProps> = ({ data }) => {
  const d = data as unknown as TopologyNodeData;
  const statusColor = peerStatusColor(d.status);
  return (
    <div className="px-3 py-2 bg-theme-surface border-2 border-theme rounded-lg shadow-sm min-w-[180px]">
      <MultiHandles counts={d.handle_counts} />
      <div className="flex items-center gap-2">
        <Globe2 className="w-4 h-4 text-theme-secondary" />
        <span className="font-medium text-sm text-theme-primary">{d.label}</span>
        <span className={`w-2 h-2 rounded-full ${statusColor}`} title={d.status ?? ''} />
      </div>
      <div className="text-xs text-theme-secondary mt-1">platform peer</div>
      <div className="flex items-center gap-2 text-[10px] text-theme-secondary mt-1">
        {d.spawn_role && (
          <span className="px-1.5 py-0.5 bg-theme-background-secondary rounded">
            {d.spawn_role}
          </span>
        )}
        {d.active_bridge_count !== undefined && d.active_bridge_count > 0 && (
          <span>{d.active_bridge_count} bridge{d.active_bridge_count === 1 ? '' : 's'}</span>
        )}
        {d.grant_count !== undefined && d.grant_count > 0 && (
          <span className="flex items-center gap-0.5">
            <Shield className="w-3 h-3" />
            {d.grant_count}
          </span>
        )}
      </div>
    </div>
  );
};

const SdwanOnlyPeerNode: React.FC<NodeProps> = ({ data }) => {
  const d = data as unknown as TopologyNodeData;
  return (
    <div className="px-3 py-2 bg-theme-background-secondary border border-theme rounded-lg min-w-[150px]">
      <MultiHandles counts={d.handle_counts} />
      <div className="flex items-center gap-2">
        <NetworkIcon className="w-3.5 h-3.5 text-theme-secondary" />
        <span className="text-sm text-theme-primary">{d.label}</span>
      </div>
      <div className="text-[10px] text-theme-secondary mt-0.5">data-plane peer</div>
    </div>
  );
};

const NODE_TYPES = {
  self: SelfNode,
  network: NetworkNode,
  'peer-platform': PlatformPeerNode,
  'peer-sdwan': SdwanOnlyPeerNode,
} as const;

// ─── Custom edge renderer: dodging smoothstep ───────────────────────
//
// Stable per-edge offset hashed from the edge id, mod 7 buckets and
// centered around 0 → each edge gets one of {-30, -20, -10, 0, +10,
// +20, +30}px elbow offset. With xyflow's default 20px setback, the
// resulting absolute offset stays within {-10 … +50}, well inside the
// node lane width. Parallel edges fan out instead of stacking;
// crossing edges shift their bend so the eye can follow each one.

const DODGE_BUCKETS = 7;
const DODGE_STEP_PX = 10;

function edgeDodgeOffset(id: string): number {
  // FNV-1a 32-bit hash — stable and well-distributed across short
  // edge id strings ("bridge-<uuid>", "grant_summary-self-<uuid>", etc.)
  let h = 0x811c9dc5;
  for (let i = 0; i < id.length; i++) {
    h ^= id.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  const bucket = h % DODGE_BUCKETS;
  return (bucket - Math.floor(DODGE_BUCKETS / 2)) * DODGE_STEP_PX;
}

const DodgingSmoothEdge: React.FC<EdgeProps> = ({
  id,
  sourceX,
  sourceY,
  sourcePosition,
  targetX,
  targetY,
  targetPosition,
  data,
  label,
  labelStyle,
  labelBgStyle,
  style,
  markerEnd,
}) => {
  // Backend-computed center_y wins (per-type lane assignment).
  // Falls back to a hash-based dodge around the natural midpoint
  // for edges without one (e.g., future edge types not yet in
  // CENTER_Y_BANDS server-side).
  const backendCenterY = (data as { center_y?: number } | undefined)?.center_y;
  const centerY =
    backendCenterY ?? (sourceY + targetY) / 2 + edgeDodgeOffset(id);
  const [path, labelX, labelY] = getSmoothStepPath({
    sourceX,
    sourceY,
    sourcePosition,
    targetX,
    targetY,
    targetPosition,
    borderRadius: 10,
    centerY,
  });
  return (
    <BaseEdge
      id={id}
      path={path}
      label={label}
      labelX={labelX}
      labelY={labelY}
      labelStyle={labelStyle as React.CSSProperties}
      labelBgStyle={labelBgStyle as React.CSSProperties}
      style={style}
      markerEnd={markerEnd as string | undefined}
    />
  );
};

const EDGE_TYPES = {
  'dodging-smooth': DodgingSmoothEdge,
} as const;

// ─── Flow builder ───────────────────────────────────────────────────

function buildFlow(data: NetworkTopologyResponse | null): {
  nodes: Node[];
  edges: Edge[];
} {
  if (!data) return { nodes: [], edges: [] };

  const nodes: Node[] = data.nodes.map((n: TopologyNode) => ({
    id: n.id,
    type: n.type,
    position: n.position,
    data: n.data as unknown as Record<string, unknown>,
  }));

  const edges: Edge[] = data.edges.map((e: TopologyEdge) => {
    const styling = edgeStyling(e);
    return {
      id: e.id,
      source: e.source,
      target: e.target,
      sourceHandle: e.source_handle,
      targetHandle: e.target_handle,
      data: e.data as unknown as Record<string, unknown>,
      // 'dodging-smooth' = smoothstep with a per-edge offset hash so
      // parallel edges fan out at the elbow. See DodgingSmoothEdge
      // above. Combined with top/bottom handles on each tier, edges
      // flow cleanly down the hierarchy without stacking.
      type: 'dodging-smooth',
      animated: !!e.animated,
      label: e.data.label,
      labelStyle: { fontSize: 10, fill: 'var(--color-text-secondary)' },
      labelBgStyle: { fill: 'var(--color-surface)', fillOpacity: 0.92 },
      style: styling.style,
      markerEnd: {
        type: MarkerType.ArrowClosed,
        color: styling.markerColor,
        width: 14,
        height: 14,
      },
    };
  });

  return { nodes, edges };
}

function edgeStyling(edge: TopologyEdge) {
  switch (edge.type) {
    case 'membership':
      return { style: { stroke: '#64748b', strokeWidth: 1.5, strokeDasharray: '6 4' }, markerColor: '#64748b' };
    case 'bridge':
      return {
        style: {
          stroke: edge.animated ? '#10b981' : '#94a3b8',
          strokeWidth: 2,
        },
        markerColor: edge.animated ? '#10b981' : '#94a3b8',
      };
    case 'grant_summary':
      return {
        style: { stroke: '#a855f7', strokeWidth: 1.5, strokeDasharray: '4 2' },
        markerColor: '#a855f7',
      };
    default:
      return { style: {}, markerColor: '#64748b' };
  }
}

function peerStatusColor(status?: string): string {
  // -solid variants render at full saturation; the bare names are
  // ~10-15% alpha tinted backgrounds (intended for card tints, not
  // status dots which need to read at 8px).
  switch (status) {
    case 'active':
      return 'bg-theme-success-solid';
    case 'enrolled':
      return 'bg-theme-info-solid';
    case 'degraded':
      return 'bg-theme-warning-solid';
    case 'suspended':
    case 'revoked':
      return 'bg-theme-error-solid';
    default:
      return 'bg-theme-background-tertiary';
  }
}
