import {
  useState, useEffect, useCallback, useImperativeHandle, forwardRef, useMemo,
} from 'react';
import type { ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Server, Package, FileText, Activity, Boxes,
  Play, CheckCircle, XCircle, Clock,
  RefreshCw, ArrowRight, Layers, Globe, Droplet,
  Network as NetworkIcon, Shield as ShieldIcon, Gauge, ShieldAlert, GitCompareArrows,
} from 'lucide-react';
import { Card } from '@/shared/components/ui/Card';
import { Button } from '@/shared/components/ui/Button';
import { StatTile, MeterBar } from '@/shared/components/charts';
import { apiClient } from '@/shared/services/apiClient';
import { systemApi } from '../services/systemApi';
import { cveApi } from '../services/api/cveApi';
import { extractData } from '../services/api/helpers';
import type { ApiEnvelope } from '../services/api/types';
import { FleetTopology } from './topology/FleetTopology';
import type { FleetTopologySnapshot } from './topology/fleetTopologyData';
import type { SystemOverviewStats, SystemRecentActivity } from '../types/system.types';

/**
 * SystemOverview — the extension's Fleet Command surface (gap G2).
 *
 * Reading order, top to bottom:
 *   1. Status strip — the four numbers an operator checks first: how much is
 *      running, how much has drifted, how much is exposed, how much spare
 *      capacity is warm.
 *   2. FleetTopology (gap G3) — the centrepiece. The strip says *how much*;
 *      the graph says *where*.
 *   3. StatTiles — the catalog/inventory counts, from the shared chart kit
 *      (`@/shared/components/charts`, gap G19) so this page and the core
 *      dashboards share one tile vocabulary.
 *   4. Quick actions + recent activity — tightened to one row each.
 *
 * Every fetch is fail-soft. Only the primary stats aggregate can produce the
 * page-level error state; the drift / CVE / pool lanes each degrade to "—"
 * on failure (a missing `system.cve.read` must not blank the fleet picture),
 * and recent activity degrades to an empty list.
 */

// ─── Canonical routes ───────────────────────────────────────────────
//
// Every hub path here is the post-Phase-B.5 canonical form registered in
// `register.ts`. The pre-rebuild page linked at the *legacy* standalone
// paths (`/app/system/nodes`, `/app/system/templates`, …) which now only
// resolve through a redirect, and `/app/system/puppet` resolved nowhere
// at all — the registered path is `/system/puppet-modules`.
const ROUTES = {
  topology: '/app/system/topology',
  nodes: '/app/system/compute/nodes',
  providers: '/app/system/compute/providers',
  volumes: '/app/system/compute/volumes',
  templates: '/app/system/catalog/templates',
  modules: '/app/system/catalog/modules',
  platforms: '/app/system/catalog/platforms',
  puppetModules: '/app/system/catalog/puppet-modules',
  tasks: '/app/system/operations/tasks',
  fleet: '/app/system/operations/fleet',
  cve: '/app/system/operations/cve',
  instancePools: '/app/system/instance-pools',
  sdwan: '/app/system/sdwan',
  sdwanNetworks: '/app/system/sdwan/networks',
  sdwanHostBridges: '/app/system/sdwan/host_bridges',
  sdwanOvn: '/app/system/sdwan/ovn',
  sdwanIpfix: '/app/system/sdwan/ipfix',
} as const;

export interface SystemOverviewHandle {
  refresh: () => Promise<void>;
}

interface SystemOverviewProps {
  className?: string;
}

/** Aggregate pool readiness across every pool the operator can see. */
interface PoolReadiness {
  ready: number;
  target: number;
  pools: number;
}

/** Subset of `InstancePool#to_summary` this page reads. */
interface PoolSummaryRow {
  ready_count?: number;
  target_size?: number;
}

/**
 * Swallow a per-lane failure and return the fallback — same contract as
 * `overviewApi.softFetch`. `null` means "this lane is unavailable" and the
 * strip renders an em-dash rather than a misleading zero.
 */
async function softFetch<T>(promise: Promise<T>, fallback: T): Promise<T> {
  try {
    return await promise;
  } catch {
    return fallback;
  }
}

/** Open CVE exposure count. Read-only surface; remediation is agent-driven. */
async function loadOpenCveCount(): Promise<number | null> {
  return softFetch(
    cveApi.list({ state: 'open', per_page: 1 }).then((r) => r.meta?.total_count ?? 0),
    null,
  );
}

/**
 * Pool readiness. `systemApi` exposes no instance-pool helper, so this reads
 * the endpoint directly with the same envelope helpers every other lane uses.
 */
async function loadPoolReadiness(): Promise<PoolReadiness | null> {
  return softFetch(
    apiClient
      .get<ApiEnvelope<{ pools: PoolSummaryRow[] }>>('/system/instance_pools', {
        params: { status: 'active' },
      })
      .then((response) => {
        const pools = extractData(response).pools ?? [];
        return {
          ready: pools.reduce((sum, p) => sum + (p.ready_count ?? 0), 0),
          target: pools.reduce((sum, p) => sum + (p.target_size ?? 0), 0),
          pools: pools.length,
        };
      }),
    null,
  );
}

// ─── Status strip ───────────────────────────────────────────────────

type SignalTone = 'success' | 'warning' | 'error' | 'info' | 'neutral';

const SIGNAL_TONE_CLASSES: Record<SignalTone, { fg: string; bg: string }> = {
  success: { fg: 'text-theme-success-fg', bg: 'bg-theme-success-bg' },
  warning: { fg: 'text-theme-warning-fg', bg: 'bg-theme-warning-bg' },
  error: { fg: 'text-theme-error-fg', bg: 'bg-theme-error-bg' },
  info: { fg: 'text-theme-info-fg', bg: 'bg-theme-info-bg' },
  neutral: { fg: 'text-theme-secondary', bg: 'bg-theme-surface' },
};

interface SignalProps {
  label: string;
  /** `null` renders an em-dash — the lane failed or has not landed yet. */
  value: number | null;
  unit?: string;
  sub: string;
  icon: ReactNode;
  tone: SignalTone;
  onClick: () => void;
}

function Signal({ label, value, unit, sub, icon, tone, onClick }: SignalProps) {
  const { fg, bg } = SIGNAL_TONE_CLASSES[tone];
  return (
    <button
      type="button"
      onClick={onClick}
      data-testid="fleet-signal"
      className="flex items-center gap-3 p-3 rounded-lg text-left w-full hover:bg-theme-surface-hover transition-colors"
    >
      <div className={`w-10 h-10 rounded-lg flex items-center justify-center shrink-0 ${bg} ${fg}`}>
        {icon}
      </div>
      <div className="min-w-0">
        <p className="text-xs font-medium uppercase tracking-wide text-theme-secondary truncate">
          {label}
        </p>
        <p className="flex items-baseline gap-1">
          <span className={`text-2xl font-bold ${value === null ? 'text-theme-tertiary' : fg}`}>
            {value === null ? '—' : value.toLocaleString()}
          </span>
          {unit && value !== null && (
            <span className="text-sm font-medium text-theme-secondary">{unit}</span>
          )}
        </p>
        <p className="text-xs text-theme-tertiary truncate">{sub}</p>
      </div>
    </button>
  );
}

// ─── Recent activity helpers ────────────────────────────────────────

const ACTIVITY_STATUS_CLASSES: Record<string, string> = {
  complete: 'bg-theme-success-bg text-theme-success-fg',
  running: 'bg-theme-info-bg text-theme-info-fg',
  failed: 'bg-theme-error-bg text-theme-error-fg',
  aborted: 'bg-theme-error-bg text-theme-error-fg',
};

const activityStatusClasses = (status: string): string =>
  ACTIVITY_STATUS_CLASSES[status] ?? 'bg-theme-warning-bg text-theme-warning-fg';

const activityIcon = (status: string) => {
  switch (status) {
    case 'complete':
      return <CheckCircle className="w-4 h-4 text-theme-success-fg" />;
    case 'running':
      return <Play className="w-4 h-4 text-theme-info-fg" />;
    case 'failed':
    case 'aborted':
      return <XCircle className="w-4 h-4 text-theme-error-fg" />;
    default:
      return <Clock className="w-4 h-4 text-theme-warning-fg" />;
  }
};

// ─── Component ──────────────────────────────────────────────────────

export const SystemOverview = forwardRef<SystemOverviewHandle, SystemOverviewProps>(
  ({ className = '' }, ref) => {
    const navigate = useNavigate();
    const [stats, setStats] = useState<SystemOverviewStats | null>(null);
    const [recentActivity, setRecentActivity] = useState<SystemRecentActivity[]>([]);
    const [openCves, setOpenCves] = useState<number | null>(null);
    const [poolReadiness, setPoolReadiness] = useState<PoolReadiness | null>(null);
    const [fleetSnapshot, setFleetSnapshot] = useState<FleetTopologySnapshot | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    // Bumped on every load so the embedded topology refetches in lockstep
    // with the strip — one operator "Refresh" moves the whole page.
    const [refreshKey, setRefreshKey] = useState(0);

    const loadData = useCallback(async () => {
      try {
        setLoading(true);
        setError(null);
        // Only the stats aggregate is allowed to fail the page. The other
        // three lanes are soft — a 403 on CVE or pools costs that number,
        // not the fleet picture.
        const [statsData, activityData, cveCount, pools] = await Promise.all([
          systemApi.getOverviewStats(),
          softFetch(systemApi.getRecentActivity(5), [] as SystemRecentActivity[]),
          loadOpenCveCount(),
          loadPoolReadiness(),
        ]);
        setStats(statsData);
        setRecentActivity(activityData);
        setOpenCves(cveCount);
        setPoolReadiness(pools);
        setRefreshKey((k) => k + 1);
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to load system data');
      } finally {
        setLoading(false);
      }
    }, []);

    useEffect(() => {
      loadData();
    }, [loadData]);

    useImperativeHandle(ref, () => ({
      refresh: loadData,
    }));

    // Drift comes from the topology snapshot rather than a second fetch:
    // the graph already loaded every instance it drew, and `boot_image_drifted`
    // is stamped on each one. Until the graph reports, the lane reads "—".
    const driftedInstances = useMemo(() => {
      if (!fleetSnapshot) return null;
      return fleetSnapshot.nodes.reduce(
        (sum, record) => sum + record.instances.filter((i) => i.boot_image_drifted).length,
        0,
      );
    }, [fleetSnapshot]);

    // `FleetTopology` holds this in a ref, so an inline callback is safe —
    // but memoising keeps the prop identity stable anyway.
    const handleSnapshot = useCallback((snapshot: FleetTopologySnapshot) => {
      setFleetSnapshot(snapshot);
    }, []);

    if (loading && !stats) {
      return (
        <div className={`space-y-6 ${className}`}>
          <Card variant="elevated" padding="lg">
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
              {[...Array(4)].map((_, i) => (
                <div key={i} className="animate-pulse space-y-2">
                  <div className="h-3 bg-theme-surface rounded w-1/2" />
                  <div className="h-7 bg-theme-surface rounded w-2/3" />
                </div>
              ))}
            </div>
          </Card>
          <Card variant="elevated" padding="lg">
            <div className="animate-pulse h-64 bg-theme-surface rounded" />
          </Card>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
            {[...Array(4)].map((_, i) => (
              <Card key={i} variant="elevated" padding="lg">
                <div className="animate-pulse space-y-3">
                  <div className="h-3 bg-theme-surface rounded w-1/2" />
                  <div className="h-7 bg-theme-surface rounded w-3/4" />
                </div>
              </Card>
            ))}
          </div>
        </div>
      );
    }

    if (error) {
      return (
        <div className={`${className}`}>
          <Card variant="outlined" padding="lg">
            <div className="text-center py-8">
              <XCircle className="w-12 h-12 text-theme-error-fg mx-auto mb-4" />
              <h3 className="text-lg font-semibold text-theme-primary mb-2">Failed to Load System Data</h3>
              <p className="text-theme-secondary mb-4">{error}</p>
              <Button onClick={loadData} variant="primary">
                <RefreshCw className="w-4 h-4 mr-2" />
                Retry
              </Button>
            </div>
          </Card>
        </div>
      );
    }

    if (!stats) return null;

    const instancesRunning = stats.instances.running;
    const instancesTotal = stats.instances.total;
    const poolPercent =
      poolReadiness && poolReadiness.target > 0
        ? Math.round((poolReadiness.ready / poolReadiness.target) * 100)
        : null;

    return (
      <div className={`space-y-6 ${className}`}>
        {/* ── Status strip: running / drifted / exposed / warm ────────── */}
        <Card variant="elevated" padding="md">
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-2">
            <Signal
              label="Instances"
              value={instancesRunning}
              unit={`/ ${instancesTotal.toLocaleString()}`}
              sub={
                instancesTotal === 0
                  ? 'No instances provisioned'
                  : `${instancesTotal - instancesRunning} not running · ${stats.nodes.total} nodes`
              }
              icon={<Server className="w-5 h-5" />}
              tone={
                instancesTotal === 0
                  ? 'neutral'
                  : instancesRunning === instancesTotal
                    ? 'success'
                    : 'warning'
              }
              onClick={() => navigate(ROUTES.nodes)}
            />
            <Signal
              label="Boot image drift"
              value={driftedInstances}
              sub={
                driftedInstances === null
                  ? 'Waiting on the fleet graph'
                  : driftedInstances === 0
                    ? 'Every graphed instance on its published image'
                    : 'Instances behind their published image'
              }
              icon={<GitCompareArrows className="w-5 h-5" />}
              tone={driftedInstances ? 'warning' : driftedInstances === null ? 'neutral' : 'success'}
              onClick={() => navigate(ROUTES.fleet)}
            />
            <Signal
              label="Open CVE exposures"
              value={openCves}
              sub={
                openCves === null
                  ? 'Unavailable — needs system.cve.read'
                  : openCves === 0
                    ? 'No open exposures'
                    : 'Triage runs on the CVE Responder'
              }
              icon={<ShieldAlert className="w-5 h-5" />}
              tone={openCves ? 'error' : openCves === null ? 'neutral' : 'success'}
              onClick={() => navigate(ROUTES.cve)}
            />
            <Signal
              label="Pool readiness"
              value={poolReadiness ? poolReadiness.ready : null}
              unit={poolReadiness ? `/ ${poolReadiness.target.toLocaleString()}` : undefined}
              sub={
                poolReadiness === null
                  ? 'Unavailable — pools could not be read'
                  : poolReadiness.pools === 0
                    ? 'No active pools'
                    : `${poolReadiness.pools} active pool${poolReadiness.pools === 1 ? '' : 's'}${
                        poolPercent === null ? '' : ` · ${poolPercent}% warm`
                      }`
              }
              icon={<Droplet className="w-5 h-5" />}
              tone={
                poolReadiness === null || poolReadiness.pools === 0
                  ? 'neutral'
                  : poolPercent !== null && poolPercent >= 100
                    ? 'success'
                    : 'warning'
              }
              onClick={() => navigate(ROUTES.instancePools)}
            />
          </div>
        </Card>

        {/* ── Fleet topology: the centrepiece ─────────────────────────── */}
        <Card variant="elevated" padding="lg">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h3 className="text-lg font-semibold text-theme-primary">Fleet</h3>
              <p className="text-sm text-theme-secondary">
                Providers and platforms → nodes → instances → SDWAN networks. Live off the fleet channel.
              </p>
            </div>
            <Button variant="outline" size="sm" onClick={() => navigate(ROUTES.topology)}>
              Full view <ArrowRight className="w-4 h-4 ml-1" />
            </Button>
          </div>
          <FleetTopology refreshKey={refreshKey} height={520} onSnapshot={handleSnapshot} />
        </Card>

        {/* ── Inventory tiles ─────────────────────────────────────────── */}
        <div>
          <h3 className="text-lg font-semibold text-theme-primary mb-4">Inventory</h3>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
            <StatTile
              label="Nodes"
              value={stats.nodes.total}
              sub={`${stats.nodes.enabled} enabled · ${stats.nodes.disabled} disabled`}
              icon={<Server className="w-5 h-5 text-theme-secondary" />}
              onClick={() => navigate(ROUTES.nodes)}
            >
              <MeterBar
                value={stats.nodes.enabled}
                max={stats.nodes.total}
                tone="success"
                ariaLabel="Enabled nodes as a share of all nodes"
              />
            </StatTile>
            <StatTile
              label="Modules"
              value={stats.modules.total}
              sub={`${stats.modules.by_variety.config} config · ${stats.modules.by_variety.instance} instance · ${stats.modules.by_variety.subscription} subscription`}
              icon={<Package className="w-5 h-5 text-theme-secondary" />}
              onClick={() => navigate(ROUTES.modules)}
            >
              <MeterBar
                value={stats.modules.enabled}
                max={stats.modules.total}
                tone="primary"
                ariaLabel="Enabled modules as a share of all modules"
              />
            </StatTile>
            <StatTile
              label="Templates"
              value={stats.templates.total}
              sub={`${stats.templates.public} public · ${stats.templates.private} private`}
              icon={<FileText className="w-5 h-5 text-theme-secondary" />}
              onClick={() => navigate(ROUTES.templates)}
            />
            <StatTile
              label="Providers"
              value={stats.providers.total}
              sub={
                stats.providers.types.length > 0
                  ? `${stats.regions.total} regions · ${stats.providers.types.join(', ')}`
                  : `${stats.providers.enabled} enabled · ${stats.regions.total} regions`
              }
              icon={<Globe className="w-5 h-5 text-theme-secondary" />}
              onClick={() => navigate(ROUTES.providers)}
            />
            <StatTile
              label="Platforms"
              value={stats.platforms.total}
              sub={`${stats.platforms.enabled} enabled`}
              icon={<Layers className="w-5 h-5 text-theme-secondary" />}
              onClick={() => navigate(ROUTES.platforms)}
            />
            <StatTile
              label="Puppet modules"
              value={stats.puppet.modules}
              sub={`${stats.puppet.resources} resources · ${stats.puppet.assignments} assignments`}
              icon={<Boxes className="w-5 h-5 text-theme-secondary" />}
              onClick={() => navigate(ROUTES.puppetModules)}
            />
            <StatTile
              label="Operations"
              value={stats.operations.total}
              sub={`${stats.operations.pending} pending · ${stats.operations.running} running · ${stats.operations.failed} failed`}
              icon={<Activity className="w-5 h-5 text-theme-secondary" />}
              onClick={() => navigate(ROUTES.tasks)}
            >
              <MeterBar
                value={stats.operations.completed}
                max={stats.operations.total}
                tone={stats.operations.failed > 0 ? 'warning' : 'success'}
                ariaLabel="Completed operations as a share of all operations"
              />
            </StatTile>
            <StatTile
              label="Volumes"
              value={stats.volumes.total}
              sub={`${stats.volumes.total_size_gb.toLocaleString()} GB provisioned`}
              icon={<Gauge className="w-5 h-5 text-theme-secondary" />}
              onClick={() => navigate(ROUTES.volumes)}
            />
          </div>
        </div>

        {/* ── SDWAN — hidden when the operator lacks SDWAN read (the
             overview aggregator soft-fetches those lanes to zero, and the
             `sdwan` block stays optional, so the section vanishes cleanly
             rather than rendering an empty row). ───────────────────────── */}
        {stats.sdwan && (
          stats.sdwan.networks > 0 ||
          stats.sdwan.host_bridges > 0 ||
          stats.sdwan.ovn_deployments > 0 ||
          stats.sdwan.ipfix_collectors > 0
        ) && (
          <div>
            <div className="flex items-center justify-between mb-4">
              <h3 className="text-lg font-semibold text-theme-primary">SDWAN</h3>
              <Button variant="outline" size="sm" onClick={() => navigate(ROUTES.sdwan)}>
                Open SDWAN <ArrowRight className="w-4 h-4 ml-1" />
              </Button>
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
              <StatTile
                label="SDWAN networks"
                value={stats.sdwan.networks}
                sub="IPv6 overlay networks"
                icon={<NetworkIcon className="w-5 h-5 text-theme-secondary" />}
                onClick={() => navigate(ROUTES.sdwanNetworks)}
              />
              <StatTile
                label="Host bridges"
                value={stats.sdwan.host_bridges}
                sub={`${stats.sdwan.bridges_by_kind.linux} Linux · ${stats.sdwan.bridges_by_kind.ovs} OVS`}
                icon={<Layers className="w-5 h-5 text-theme-secondary" />}
                onClick={() => navigate(ROUTES.sdwanHostBridges)}
              />
              <StatTile
                label="OVN deployments"
                value={stats.sdwan.ovn_deployments}
                sub={
                  stats.sdwan.ovn_deployments === 0
                    ? 'Heavyweight profile only'
                    : `${stats.sdwan.ovn_active} active`
                }
                icon={<ShieldIcon className="w-5 h-5 text-theme-secondary" />}
                onClick={() => navigate(ROUTES.sdwanOvn)}
              />
              <StatTile
                label="IPFIX collectors"
                value={stats.sdwan.ipfix_collectors}
                sub={
                  stats.sdwan.ipfix_collectors === 0
                    ? 'Flow telemetry export'
                    : `${stats.sdwan.ipfix_active} active`
                }
                icon={<Gauge className="w-5 h-5 text-theme-secondary" />}
                onClick={() => navigate(ROUTES.sdwanIpfix)}
              />
            </div>
          </div>
        )}

        {/* ── Quick actions + recent activity ─────────────────────────── */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <Card variant="elevated" padding="lg">
            <h3 className="text-lg font-semibold text-theme-primary mb-4">Quick Actions</h3>
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
              {[
                { label: 'Nodes', icon: <Server className="w-5 h-5" />, to: ROUTES.nodes },
                { label: 'Catalog', icon: <Boxes className="w-5 h-5" />, to: ROUTES.modules },
                { label: 'Templates', icon: <FileText className="w-5 h-5" />, to: ROUTES.templates },
                { label: 'Operations', icon: <Activity className="w-5 h-5" />, to: ROUTES.tasks },
                { label: 'Fleet signals', icon: <Gauge className="w-5 h-5" />, to: ROUTES.fleet },
                { label: 'Topology', icon: <NetworkIcon className="w-5 h-5" />, to: ROUTES.topology },
              ].map((action) => (
                <Button
                  key={action.label}
                  variant="outline"
                  className="flex flex-col items-center justify-center p-3 h-auto gap-1"
                  onClick={() => navigate(action.to)}
                >
                  {action.icon}
                  <span className="text-xs font-medium">{action.label}</span>
                </Button>
              ))}
            </div>
          </Card>

          <Card variant="elevated" padding="lg">
            <div className="flex items-center justify-between mb-4">
              <h3 className="text-lg font-semibold text-theme-primary">Recent Activity</h3>
              <Button variant="outline" size="sm" onClick={() => navigate(ROUTES.tasks)}>
                View All <ArrowRight className="w-4 h-4 ml-1" />
              </Button>
            </div>
            {recentActivity.length === 0 ? (
              <div className="text-center py-8">
                <Activity className="w-10 h-10 text-theme-tertiary mx-auto mb-3" />
                <p className="text-theme-secondary">No recent activity</p>
              </div>
            ) : (
              <ul className="space-y-2">
                {recentActivity.map((activity) => (
                  <li key={activity.id}>
                    <button
                      type="button"
                      onClick={() => navigate(ROUTES.tasks)}
                      className="flex items-center gap-3 w-full text-left p-2 rounded-lg hover:bg-theme-surface-hover transition-colors"
                    >
                      <span className="shrink-0">{activityIcon(activity.status || '')}</span>
                      <span className="flex-1 min-w-0">
                        <span className="block font-medium text-theme-primary truncate">
                          {activity.action}
                        </span>
                        <span className="block text-xs text-theme-tertiary truncate">
                          {new Date(activity.timestamp).toLocaleString()}
                          {activity.initiated_by && ` · ${activity.initiated_by}`}
                        </span>
                      </span>
                      {activity.status && (
                        <span
                          className={`shrink-0 text-xs font-medium px-2 py-1 rounded-full ${activityStatusClasses(activity.status)}`}
                        >
                          {activity.status}
                        </span>
                      )}
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>
      </div>
    );
  }
);

SystemOverview.displayName = 'SystemOverview';
