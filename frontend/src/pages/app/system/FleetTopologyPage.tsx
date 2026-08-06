import React, { useCallback, useMemo, useState } from 'react';
import { RefreshCw } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { FleetTopology } from '@system/features/system/components/topology/FleetTopology';
import type { FleetTopologySnapshot } from '@system/features/system/components/topology/fleetTopologyData';

/**
 * Fleet Topology — the fleet's containment graph at
 * `/app/system/topology` (gap G3).
 *
 * Thin shell: stats row + legend around the <FleetTopology> canvas, which
 * owns its own fetching, live SystemFleetChannel subscription, and
 * loading/error/empty states. Same split as the SDWAN hub's TopologyTab
 * around <SystemTopology>.
 */
export default function FleetTopologyPage(): React.JSX.Element {
  const [refreshKey, setRefreshKey] = useState(0);
  const [snapshot, setSnapshot] = useState<FleetTopologySnapshot | null>(null);

  const handleSnapshot = useCallback((next: FleetTopologySnapshot) => {
    setSnapshot(next);
  }, []);

  const pageActions: PageAction[] = useMemo(
    () => [
      {
        id: 'refresh',
        label: 'Refresh',
        // PageContainer renders a *string* icon as literal text — only a
        // component reference becomes an icon here (nav entries are the
        // string-name surface, not page actions).
        icon: RefreshCw,
        variant: 'secondary',
        onClick: () => setRefreshKey((k) => k + 1),
      },
    ],
    [],
  );

  const instanceCount = snapshot
    ? snapshot.nodes.reduce(
        (sum, record) => sum + (record.node.instance_count ?? record.instances.length),
        0,
      )
    : 0;

  return (
    <PageContainer
      title="Fleet Topology"
      description="Provider and platform groups, the nodes under them, each node's instances, and the SDWAN networks those instances peer into. Updates live from the fleet event channel."
      breadcrumbs={[{ label: 'System', href: '/app/system' }, { label: 'Topology' }]}
      actions={pageActions}
    >
      <div className="space-y-3">
        {snapshot && <StatsRow snapshot={snapshot} instanceCount={instanceCount} />}

        {snapshot && snapshot.truncatedNodeCount > 0 && (
          <div className="text-xs px-3 py-2 rounded bg-theme-warning-bg text-theme-warning-fg">
            Showing the first {snapshot.nodes.length} of {snapshot.totalNodeCount} nodes. Use the
            Compute hub for the full list.
          </div>
        )}

        <FleetTopology refreshKey={refreshKey} onSnapshot={handleSnapshot} />

        <Legend />
      </div>
    </PageContainer>
  );
}

const StatsRow: React.FC<{ snapshot: FleetTopologySnapshot; instanceCount: number }> = ({
  snapshot,
  instanceCount,
}) => (
  <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
    <StatCard label="Groups" value={snapshot.groups.length} sublabel="provider / platform lanes" />
    <StatCard label="Nodes" value={snapshot.nodes.length} sublabel={`${snapshot.totalNodeCount} total`} />
    <StatCard label="Instances" value={instanceCount} />
    <StatCard
      label="SDWAN networks"
      value={snapshot.networks.length}
      sublabel={`${snapshot.memberships.length} memberships`}
    />
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
    <LegendItem swatch="bg-theme-info-bg border border-theme-info-border" label="Provider / platform group" />
    <LegendItem swatch="bg-theme-surface border-2 border-theme" label="Node" />
    <LegendItem swatch="bg-theme-background-secondary border border-theme" label="Instance" />
    <LegendItem swatch="bg-theme-surface border border-theme" label="SDWAN network" />
    <LegendItem dot="bg-theme-success-solid" label="Running" />
    <LegendItem dot="bg-theme-warning-solid" label="Partially running" />
    <LegendItem dot="bg-theme-error-solid" label="Disabled / error" />
  </div>
);

const LegendItem: React.FC<{ swatch?: string; dot?: string; label: string }> = ({
  swatch,
  dot,
  label,
}) => (
  <span className="flex items-center gap-1.5">
    {swatch && <span className={`inline-block w-3 h-3 rounded ${swatch}`} />}
    {dot && <span className={`inline-block w-2 h-2 rounded-full ${dot}`} />}
    <span>{label}</span>
  </span>
);
