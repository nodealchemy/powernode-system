import React, { useEffect, useState } from 'react';
import {
  Network,
  Server,
  Globe2,
  Move,
  ShieldCheck,
  AlertTriangle,
} from 'lucide-react';
import { platformApi } from '../../services/api/platformApi';
import type { PlatformOverview } from '../../types/platform.types';

/**
 * At-a-glance status cards at the top of the Platform dashboard.
 * Shows counts + key signals for Peers / Children / Services /
 * Migrations / Certificates. Re-fetches on the configurable
 * refresh interval.
 *
 * Plan reference: Decentralized Federation §I + P7.
 */
export const PlatformOverviewCards: React.FC = () => {
  const [overview, setOverview] = useState<PlatformOverview | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const fetch = async () => {
      try {
        const data = await platformApi.overview();
        if (!cancelled) {
          setOverview(data);
          setError(null);
        }
      } catch (err: unknown) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'Failed to load overview');
        }
      }
    };
    void fetch();
    const interval = setInterval(fetch, 30_000); // refresh every 30s
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, []);

  if (error) {
    return (
      <div className="p-3 bg-theme-danger text-theme-danger text-sm rounded inline-flex items-center gap-2">
        <AlertTriangle className="w-4 h-4" />
        Overview failed to load: {error}
      </div>
    );
  }

  if (!overview) {
    return (
      <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-4">
        {[ 0, 1, 2, 3, 4 ].map((i) => (
          <div key={i} className="bg-theme-surface border border-theme rounded p-3 animate-pulse">
            <div className="h-3 bg-theme-background-secondary rounded w-2/3 mb-2"></div>
            <div className="h-6 bg-theme-background-secondary rounded w-1/3"></div>
          </div>
        ))}
      </div>
    );
  }

  return (
    <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-4">
      <Card
        icon={<Network className="w-4 h-4 text-theme-info" />}
        label="Peers"
        primary={overview.peers.count}
        detail={statusDetail(overview.peers.by_status, [ 'active', 'enrolled', 'degraded' ])}
      />
      <Card
        icon={<Server className="w-4 h-4 text-theme-info" />}
        label="Children"
        primary={overview.children.count}
        detail={statusDetail(overview.children.by_status, [ 'active', 'enrolled', 'proposed' ])}
      />
      <Card
        icon={<Globe2 className="w-4 h-4 text-theme-info" />}
        label="Services"
        primary={`${overview.services.offerings} / ${overview.services.subscriptions}`}
        detail="offerings / subscriptions"
      />
      <Card
        icon={<Move className="w-4 h-4 text-theme-info" />}
        label="Migrations"
        primary={overview.migrations.count}
        detail={statusDetail(overview.migrations.by_status, [ 'pending', 'applying', 'applied' ])}
      />
      <Card
        icon={<ShieldCheck className="w-4 h-4 text-theme-info" />}
        label="Certificates"
        primary={overview.certificates.count}
        detail={
          overview.certificates.near_expiry > 0
            ? `${overview.certificates.near_expiry} expiring soon`
            : statusDetail(overview.certificates.by_status, [ 'valid', 'failed' ])
        }
        warn={overview.certificates.near_expiry > 0}
      />
    </div>
  );
};

interface CardProps {
  icon: React.ReactNode;
  label: string;
  primary: string | number;
  detail: string;
  warn?: boolean;
}

const Card: React.FC<CardProps> = ({ icon, label, primary, detail, warn }) => (
  <div className="bg-theme-surface border border-theme rounded p-3">
    <div className="flex items-center gap-2 text-xs text-theme-secondary mb-1">
      {icon}
      <span>{label}</span>
    </div>
    <div className="text-2xl font-semibold text-theme-primary">{primary}</div>
    <div className={`text-xs mt-1 ${warn ? 'text-theme-warning' : 'text-theme-tertiary'}`}>
      {detail}
    </div>
  </div>
);

function statusDetail(
  by_status: Record<string, number> | undefined,
  order: string[],
): string {
  if (!by_status) return '—';
  const parts: string[] = [];
  for (const key of order) {
    if (by_status[key]) parts.push(`${by_status[key]} ${key}`);
  }
  for (const [ key, n ] of Object.entries(by_status)) {
    if (!order.includes(key) && n > 0) parts.push(`${n} ${key}`);
  }
  return parts.length > 0 ? parts.join(' · ') : 'none';
}
