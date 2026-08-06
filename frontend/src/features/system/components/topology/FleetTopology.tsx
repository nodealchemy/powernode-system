import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ReactFlow,
  Background,
  Controls,
  BaseEdge,
  getSmoothStepPath,
  type EdgeProps,
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import './FleetTopology.css';
import { useAuth } from '@/shared/hooks/useAuth';
import { wsManager } from '@/shared/services/WebSocketManager';
import { FLEET_NODE_TYPES } from './FleetTopologyNodes';
import { buildFleetFlow } from './fleetTopologyLayout';
import {
  EMPTY_SNAPSHOT,
  loadFleetTopology,
  type FleetTopologySnapshot,
} from './fleetTopologyData';

/**
 * FleetTopology — @xyflow/react containment graph of the fleet
 * (gap G3 + G9).
 *
 * Layout (client-side; see fleetTopologyLayout.ts):
 *   Tier 1 (top):    provider / platform groups
 *   Tier 2:          System::Node cards — status dot + module chips
 *   Tier 3:          each node's System::NodeInstance rows
 *   Tier 4 (bottom): SDWAN networks, with membership edges from the
 *                    instances that peer into them
 *
 * Edges use the same 'dodging-smooth' renderer convention as
 * SystemTopology: smoothstep routing with a per-family lane (`center_y`)
 * and a per-edge offset hash so parallel edges fan out at the elbow
 * instead of stacking.
 *
 * Live (G9): subscribes to SystemFleetChannel and refetches — a whole
 * snapshot, not an incremental patch — when an instance-lifecycle or
 * drift event lands. Bursts coalesce through a debounce so a rolling
 * upgrade doesn't refetch once per instance.
 */
interface FleetTopologyProps {
  refreshKey?: number;
  /** Height of the canvas shell; the page sets this from its layout. */
  height?: number;
  /** Called after every successful load so a host page can show counts. */
  onSnapshot?: (snapshot: FleetTopologySnapshot) => void;
}

/** Event kinds that invalidate the graph. */
const LIVE_EVENT_PATTERN = /^system\.instance_|drift/;
/** Burst window — a rolling upgrade emits one event per instance. */
const REFETCH_DEBOUNCE_MS = 1500;

export const FleetTopology: React.FC<FleetTopologyProps> = ({
  refreshKey,
  height = 640,
  onSnapshot,
}) => {
  const { currentUser } = useAuth();
  const accountId = (currentUser as { account?: { id?: string } } | null)?.account?.id;

  const [snapshot, setSnapshot] = useState<FleetTopologySnapshot | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  // Bumped by the live channel; folded into the fetch effect's deps so a
  // live event and a manual refresh take the identical code path.
  const [liveKey, setLiveKey] = useState(0);

  // Held in a ref so a host page that passes an inline callback doesn't
  // re-trigger the fetch effect on every one of its own renders.
  const onSnapshotRef = useRef(onSnapshot);
  useEffect(() => {
    onSnapshotRef.current = onSnapshot;
  }, [onSnapshot]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    loadFleetTopology()
      .then((data) => {
        if (cancelled) return;
        setSnapshot(data);
        onSnapshotRef.current?.(data);
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'Failed to load fleet topology');
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [refreshKey, liveKey]);

  // ─── Live subscription (G9) ───────────────────────────────────────
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const scheduleRefetch = useCallback(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => {
      debounceRef.current = null;
      setLiveKey((k) => k + 1);
    }, REFETCH_DEBOUNCE_MS);
  }, []);

  useEffect(() => {
    if (!accountId) return;

    const unsubscribe = wsManager.subscribe({
      channel: 'SystemFleetChannel',
      params: { account_id: accountId },
      onMessage: (data: unknown) => {
        const message = data as { type?: string; kind?: string } | null;
        if (!message || message.type === 'connection_established' || message.type === 'pong') return;
        if (typeof message.kind === 'string' && LIVE_EVENT_PATTERN.test(message.kind)) {
          scheduleRefetch();
        }
      },
    });

    return () => {
      unsubscribe();
      if (debounceRef.current) {
        clearTimeout(debounceRef.current);
        debounceRef.current = null;
      }
    };
  }, [accountId, scheduleRefetch]);

  const { nodes, edges } = useMemo(
    () => buildFleetFlow(snapshot ?? EMPTY_SNAPSHOT),
    [snapshot],
  );

  // Only the first load blanks the canvas — a live refetch keeps the
  // previous graph on screen so the view doesn't flash on every event.
  if (loading && !snapshot) {
    return <div className="p-4 text-theme-secondary">Loading fleet topology…</div>;
  }
  if (error && !snapshot) {
    return (
      <div className="p-3 bg-theme-danger-bg text-theme-danger-fg rounded text-sm">{error}</div>
    );
  }
  if (!snapshot) {
    return null;
  }
  // Keyed on fleet nodes, not on the built flow: an account with SDWAN
  // networks but no nodes would otherwise render a lone network card with
  // nothing attached, which reads as a broken graph rather than an empty
  // fleet.
  if (snapshot.nodes.length === 0) {
    return (
      <div className="p-12 text-center text-theme-secondary text-sm">
        No nodes yet. The fleet graph populates as you create nodes and provision instances.
      </div>
    );
  }

  return (
    <div
      className="fleet-topology bg-theme-surface border border-theme rounded-lg overflow-hidden"
      style={{ height }}
    >
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={FLEET_NODE_TYPES}
        edgeTypes={EDGE_TYPES}
        fitView
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable
        proOptions={{ hideAttribution: true }}
        minZoom={0.15}
        maxZoom={2}
      >
        <Background gap={24} />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  );
};

// ─── Custom edge renderer: dodging smoothstep ───────────────────────
//
// Lifted from SystemTopology's DodgingSmoothEdge. Stable per-edge offset
// hashed from the edge id, mod 7 buckets and centred around 0 → each edge
// gets one of {-30 … +30}px elbow offset. The layout stamps a per-family
// `center_y` lane; the hash only breaks ties inside a lane.

const DODGE_BUCKETS = 7;
const DODGE_STEP_PX = 10;

export function edgeDodgeOffset(id: string): number {
  // FNV-1a 32-bit — stable and well-distributed over short id strings.
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
  style,
  markerEnd,
}) => {
  const laneCenterY = (data as { center_y?: number } | undefined)?.center_y;
  const centerY = (laneCenterY ?? (sourceY + targetY) / 2) + edgeDodgeOffset(id);
  const [path] = getSmoothStepPath({
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
      style={style}
      markerEnd={markerEnd as string | undefined}
    />
  );
};

const EDGE_TYPES = {
  'dodging-smooth': DodgingSmoothEdge,
} as const;
