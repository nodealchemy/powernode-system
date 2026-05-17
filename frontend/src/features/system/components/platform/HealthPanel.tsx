import React, { useCallback, useEffect, useState } from 'react';
import {
  Activity,
  Server,
  Cpu,
  Database,
  HardDrive,
  ShieldCheck,
  Network,
  Globe2,
  AlertTriangle,
  CheckCircle2,
  AlertCircle,
  XCircle,
  HelpCircle,
  RefreshCw,
  Clock,
} from 'lucide-react';
import { platformHealthApi } from '../../services/api/platformHealthApi';
import type {
  PlatformHealth,
  SubsystemStatus,
} from '../../types/platform-health.types';

/**
 * Read-only health snapshot panel for the
 * /app/system/compute/platform/health route. Aggregates per-subsystem
 * status into cards with key metrics. Auto-refreshes every 30s.
 *
 * Plan reference: Decentralized Federation §I + P7.2.
 */
export const HealthPanel: React.FC = () => {
  const [health, setHealth] = useState<PlatformHealth | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchHealth = useCallback(async () => {
    setError(null);
    try {
      const data = await platformHealthApi.show();
      setHealth(data);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load health');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void fetchHealth();
    const interval = setInterval(() => void fetchHealth(), 30_000);
    return () => clearInterval(interval);
  }, [fetchHealth]);

  if (loading && !health) {
    return (
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
        {[ 0, 1, 2, 3, 4, 5, 6 ].map((i) => (
          <div key={i} className="bg-theme-surface border border-theme rounded p-4 animate-pulse">
            <div className="h-4 bg-theme-background-secondary rounded w-1/2 mb-3"></div>
            <div className="h-6 bg-theme-background-secondary rounded w-1/3 mb-2"></div>
            <div className="h-3 bg-theme-background-secondary rounded w-2/3"></div>
          </div>
        ))}
      </div>
    );
  }

  if (error && !health) {
    return (
      <div className="p-3 bg-theme-danger text-theme-danger text-sm rounded inline-flex items-center gap-2">
        <AlertTriangle className="w-4 h-4" />
        {error}
      </div>
    );
  }

  if (!health) return null;

  return (
    <div>
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2 text-sm text-theme-secondary">
          <Activity className="w-4 h-4" />
          <span>Generated {new Date(health.generated_at).toLocaleTimeString()}</span>
          <span className="text-theme-tertiary">· refreshes every 30s</span>
        </div>
        <button
          type="button"
          onClick={() => void fetchHealth()}
          disabled={loading}
          className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
          title="Refresh"
        >
          <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
        </button>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
        <Card
          icon={<Cpu className="w-4 h-4" />}
          label="Rails API"
          status={health.rails.status}
          primary={health.rails.uptime_human ?? '—'}
          detail={
            <div className="space-y-0.5">
              <div>uptime · <span className="font-mono">{health.rails.uptime_human ?? '—'}</span></div>
              <div>env · <span className="font-mono">{health.rails.rails_env ?? '—'}</span></div>
              <div>ruby · <span className="font-mono">{health.rails.ruby_version ?? '—'}</span></div>
              <div>db · {health.rails.db_connected ? 'connected' : 'disconnected'}</div>
              {health.rails.error && <div className="text-theme-danger">{health.rails.error}</div>}
            </div>
          }
        />

        <Card
          icon={<Server className="w-4 h-4" />}
          label="Worker Pool"
          status={health.worker.status}
          primary={`${health.worker.stats.processes ?? '—'} live`}
          detail={
            <div className="space-y-0.5">
              <div>processed · <span className="font-mono">{health.worker.stats.processed?.toLocaleString() ?? '—'}</span></div>
              <div>failed · <span className="font-mono">{health.worker.stats.failed?.toLocaleString() ?? '—'}</span></div>
              <div>enqueued · <span className="font-mono">{health.worker.stats.enqueued ?? '—'}</span></div>
              <div>retry · <span className="font-mono">{health.worker.stats.retry_size ?? '—'}</span></div>
              {health.worker.last_seen_at && (
                <div className="flex items-center gap-1">
                  <Clock className="w-3 h-3" />
                  {new Date(health.worker.last_seen_at).toLocaleString()}
                </div>
              )}
              {health.worker.error && <div className="text-theme-danger">{health.worker.error}</div>}
            </div>
          }
        />

        <Card
          icon={<HardDrive className="w-4 h-4" />}
          label="Redis"
          status={health.redis.status}
          primary={health.redis.status}
          detail={
            <div className="space-y-0.5">
              <div>store · <span className="font-mono text-xs">{health.redis.cache_store ?? '—'}</span></div>
              {health.redis.probe_at && (
                <div className="flex items-center gap-1">
                  <Clock className="w-3 h-3" />
                  probed {new Date(health.redis.probe_at).toLocaleTimeString()}
                </div>
              )}
              {health.redis.error && <div className="text-theme-danger">{health.redis.error}</div>}
            </div>
          }
        />

        <Card
          icon={<Database className="w-4 h-4" />}
          label="Postgres"
          status={health.postgres.status}
          primary={health.postgres.size_human ?? '—'}
          detail={
            <div className="space-y-0.5">
              <div>database · <span className="font-mono text-xs">{health.postgres.database ?? '—'}</span></div>
              <div>active conns · <span className="font-mono">{health.postgres.active_connections ?? '—'}</span></div>
              {health.postgres.error && <div className="text-theme-danger">{health.postgres.error}</div>}
            </div>
          }
        />

        <Card
          icon={<ShieldCheck className="w-4 h-4" />}
          label="ACME / Traefik"
          status={health.acme.status}
          primary={`${health.acme.count ?? 0} cert${health.acme.count === 1 ? '' : 's'}`}
          detail={
            <div className="space-y-0.5">
              {health.acme.by_status && Object.entries(health.acme.by_status).map(([k, v]) => (
                <div key={k}>{k} · <span className="font-mono">{v}</span></div>
              ))}
              {(health.acme.expiring_within_30d ?? 0) > 0 && (
                <div className="text-theme-warning">
                  {health.acme.expiring_within_30d} expiring &lt;30d
                </div>
              )}
              {(health.acme.expiring_within_7d ?? 0) > 0 && (
                <div className="text-theme-danger">
                  {health.acme.expiring_within_7d} expiring &lt;7d
                </div>
              )}
              {health.acme.nearest_expiry_at && (
                <div className="flex items-center gap-1">
                  <Clock className="w-3 h-3" />
                  next {new Date(health.acme.nearest_expiry_at).toLocaleDateString()}
                </div>
              )}
              {health.acme.error && <div className="text-theme-danger">{health.acme.error}</div>}
            </div>
          }
        />

        <Card
          icon={<Network className="w-4 h-4" />}
          label="SDWAN"
          status={health.sdwan.status}
          primary={`${health.sdwan.networks_count ?? 0} networks`}
          detail={
            <div className="space-y-0.5">
              <div>VIPs · <span className="font-mono">{health.sdwan.virtual_ips?.count ?? 0}</span> ({health.sdwan.virtual_ips?.assigned ?? 0} assigned)</div>
              <div>BGP · <span className="font-mono">{health.sdwan.bgp?.established ?? 0}/{health.sdwan.bgp?.total ?? 0} established</span></div>
              {health.sdwan.error && <div className="text-theme-danger">{health.sdwan.error}</div>}
            </div>
          }
        />

        <Card
          icon={<Globe2 className="w-4 h-4" />}
          label="Federation"
          status={health.federation.status}
          primary={`${health.federation.total ?? 0} peer${health.federation.total === 1 ? '' : 's'}`}
          detail={
            <div className="space-y-0.5">
              <div>active · <span className="font-mono">{health.federation.active ?? 0}</span></div>
              <div>degraded · <span className="font-mono">{health.federation.degraded ?? 0}</span></div>
              <div>suspended · <span className="font-mono">{health.federation.suspended ?? 0}</span></div>
              {(health.federation.heartbeat_stale ?? 0) > 0 && (
                <div className="text-theme-warning">
                  {health.federation.heartbeat_stale} stale heartbeat
                </div>
              )}
              {health.federation.last_handshake_at && (
                <div className="flex items-center gap-1">
                  <Clock className="w-3 h-3" />
                  last {new Date(health.federation.last_handshake_at).toLocaleString()}
                </div>
              )}
              {health.federation.error && <div className="text-theme-danger">{health.federation.error}</div>}
            </div>
          }
        />
      </div>
    </div>
  );
};

interface CardProps {
  icon: React.ReactNode;
  label: string;
  status: SubsystemStatus;
  primary: string;
  detail: React.ReactNode;
}

const Card: React.FC<CardProps> = ({ icon, label, status, primary, detail }) => (
  <div className="bg-theme-surface border border-theme rounded p-4">
    <div className="flex items-center justify-between gap-2 mb-2">
      <div className="flex items-center gap-2 text-xs text-theme-secondary">
        {icon}
        <span className="uppercase tracking-wide">{label}</span>
      </div>
      <StatusPill status={status} />
    </div>
    <div className="text-2xl font-semibold text-theme-primary mb-2">{primary}</div>
    <div className="text-xs text-theme-secondary">{detail}</div>
  </div>
);

const StatusPill: React.FC<{ status: SubsystemStatus }> = ({ status }) => {
  const config: Record<SubsystemStatus, { icon: React.ReactNode; cls: string; label: string }> = {
    ok: {
      icon: <CheckCircle2 className="w-3 h-3" />,
      cls: 'bg-theme-success text-theme-success',
      label: 'ok',
    },
    degraded: {
      icon: <AlertCircle className="w-3 h-3" />,
      cls: 'bg-theme-warning text-theme-warning',
      label: 'degraded',
    },
    down: {
      icon: <XCircle className="w-3 h-3" />,
      cls: 'bg-theme-danger text-theme-danger',
      label: 'down',
    },
    unknown: {
      icon: <HelpCircle className="w-3 h-3" />,
      cls: 'bg-theme-background-tertiary text-theme-secondary',
      label: 'unknown',
    },
  };
  const c = config[status];
  return (
    <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium ${c.cls}`}>
      {c.icon}
      {c.label}
    </span>
  );
};
