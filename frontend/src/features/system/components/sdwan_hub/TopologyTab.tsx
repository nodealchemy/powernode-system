import React, { useEffect, useState } from 'react';
import { SystemTopology } from '../network/SystemTopology';
import { networkTopologyApi } from '../../services/api/networkTopologyApi';
import type { TopologyStats } from '../../types/network_topology.types';

/**
 * TopologyTab — system-wide SDWAN + federation graph rendered under
 * the SDWAN hub at `/app/system/sdwan/topology`.
 *
 * Composes:
 *   - Stats row (counts: networks, peers, bridges, grants)
 *   - SystemTopology canvas (@xyflow/react with self/network/peer/bridge nodes)
 *   - Legend (color + line semantics)
 *
 * Plan reference: Decentralized Federation §K.5 + P4.5.8.
 */
export const TopologyTab: React.FC = () => {
  const [stats, setStats] = useState<TopologyStats | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    networkTopologyApi
      .getTopology()
      .then((d) => {
        if (!cancelled) setStats(d.stats);
      })
      .catch(() => {
        /* SystemTopology renders its own error state; stats row stays empty */
      });
    return () => {
      cancelled = true;
    };
  }, [refreshKey]);

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <p className="text-sm text-theme-secondary">
          System-wide federation + SDWAN graph. Solid green edges are active bridges; dashed
          purple edges are grant summaries from this platform to each peer.
        </p>
        <button
          type="button"
          onClick={() => setRefreshKey((k) => k + 1)}
          className="text-xs px-2 py-1 border border-theme rounded text-theme-secondary hover:text-theme-primary"
        >
          Refresh
        </button>
      </div>

      {stats && <StatsRow stats={stats} />}

      <SystemTopology refreshKey={refreshKey} />

      <Legend />
    </div>
  );
};

const StatsRow: React.FC<{ stats: TopologyStats }> = ({ stats }) => (
  <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
    <StatCard label="Networks" value={stats.network_count} />
    <StatCard
      label="Peers"
      value={stats.peer_count}
      sublabel={`${stats.platform_peer_count} platform · ${stats.sdwan_only_peer_count} data-plane`}
    />
    <StatCard
      label="Bridges"
      value={stats.bridge_count}
      sublabel={`${stats.active_bridge_count} active`}
    />
    <StatCard label="Active grants" value={stats.grant_count} />
  </div>
);

const StatCard: React.FC<{ label: string; value: number; sublabel?: string }> = ({
  label,
  value,
  sublabel,
}) => (
  <div className="bg-theme-surface border border-theme rounded-lg p-3">
    <div className="text-xs text-theme-secondary">{label}</div>
    <div className="text-2xl font-semibold text-theme mt-1">{value}</div>
    {sublabel && <div className="text-[10px] text-theme-secondary mt-0.5">{sublabel}</div>}
  </div>
);

const Legend: React.FC = () => (
  <div className="flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-theme-secondary pt-1">
    <LegendItem swatch="bg-theme-info/10 border border-theme-info" label="Self" />
    <LegendItem swatch="bg-theme-surface border border-theme" label="SDWAN network" />
    <LegendItem swatch="bg-theme-surface border-2 border-theme" label="Platform peer" />
    <LegendItem swatch="bg-theme-background-secondary border border-theme" label="Data-plane peer" />
    <LegendItem line="green" label="Active bridge" />
    <LegendItem line="gray-dashed" label="Self ↔ network membership" />
    <LegendItem line="purple-dashed" label="Grant summary (self → peer)" />
  </div>
);

const LegendItem: React.FC<{ swatch?: string; line?: string; label: string }> = ({
  swatch,
  line,
  label,
}) => (
  <span className="flex items-center gap-1.5">
    {swatch && <span className={`inline-block w-3 h-3 rounded ${swatch}`} />}
    {line && <span className="inline-block w-5 text-theme-secondary">{lineDecoration(line)}</span>}
    <span>{label}</span>
  </span>
);

function lineDecoration(kind: string): string {
  switch (kind) {
    case 'green':
      return '━━';
    case 'gray-dashed':
      return '┄┄';
    case 'purple-dashed':
      return '┅┅';
    default:
      return '─';
  }
}
