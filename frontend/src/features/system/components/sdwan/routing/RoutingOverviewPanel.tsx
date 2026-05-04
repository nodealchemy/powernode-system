import React from 'react';
import { Globe2, Network, Activity, GitBranch } from 'lucide-react';
import type { SdwanRoutingOverview } from '../../../types/sdwan.types';

interface RoutingOverviewPanelProps {
  data: SdwanRoutingOverview;
}

const StatTile: React.FC<{
  icon: React.ReactNode;
  label: string;
  value: number | string;
  hint?: string;
  tone?: 'default' | 'success' | 'warning';
}> = ({ icon, label, value, hint, tone = 'default' }) => {
  const toneClass =
    tone === 'success'
      ? 'text-theme-success'
      : tone === 'warning'
      ? 'text-theme-warning'
      : 'text-theme-primary';
  return (
    <div className="flex items-start gap-3 p-4 bg-theme-surface rounded border border-theme">
      <div className="text-theme-secondary mt-0.5">{icon}</div>
      <div className="flex-1">
        <div className="text-xs text-theme-secondary uppercase tracking-wide">{label}</div>
        <div className={`text-2xl font-semibold mt-1 ${toneClass}`}>{value}</div>
        {hint && <div className="text-xs text-theme-secondary mt-0.5">{hint}</div>}
      </div>
    </div>
  );
};

export const RoutingOverviewPanel: React.FC<RoutingOverviewPanelProps> = ({ data }) => {
  const { summary, account_bgp } = data;
  const sessionRatio =
    summary.total_sessions > 0
      ? Math.round((summary.established_sessions / summary.total_sessions) * 100)
      : 0;

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3">
      <StatTile
        icon={<Network size={20} />}
        label="iBGP networks"
        value={summary.ibgp_networks}
        hint={`${summary.static_networks} static · ${summary.total_networks} total`}
      />
      <StatTile
        icon={<Activity size={20} />}
        label="BGP sessions"
        value={summary.total_sessions}
        hint={
          summary.total_sessions > 0
            ? `${summary.established_sessions} established (${sessionRatio}%)`
            : 'No agents reporting yet'
        }
        tone={
          summary.total_sessions > 0 && summary.established_sessions === summary.total_sessions
            ? 'success'
            : summary.total_sessions > 0 && sessionRatio < 80
            ? 'warning'
            : 'default'
        }
      />
      <StatTile
        icon={<GitBranch size={20} />}
        label="AS number"
        value={account_bgp?.as_number?.toString() ?? '—'}
        hint={
          account_bgp
            ? `RFC 6996 4-byte private`
            : 'Allocate to enable iBGP'
        }
      />
      <StatTile
        icon={<Globe2 size={20} />}
        label="Router-ID strategy"
        value={account_bgp?.router_id_strategy ?? '—'}
        hint="Derived from each peer's overlay /128"
      />
    </div>
  );
};
