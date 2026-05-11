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

  // Numbers + short labels stay big (text-2xl). Long string values like
  // `peer_overlay_ipv6_hash` shrink to text-base so the whole token fits
  // on one line at the lg:grid-cols-4 width — wrapping looks worse than
  // smaller text per operator feedback. Anything still too long for the
  // smaller size truncates with an ellipsis + tooltip.
  const valueStr = String(value);
  const isLongString = typeof value === 'string' && valueStr.length > 10;
  const valueSizeClass = isLongString ? 'text-base' : 'text-2xl';

  return (
    <div className="flex items-start gap-3 p-4 bg-theme-surface rounded border border-theme overflow-hidden">
      <div className="text-theme-secondary mt-0.5 shrink-0">{icon}</div>
      {/* min-w-0 releases the default content-sized min-width so the flex
          column can shrink to its parent's actual width instead of pushing
          past the tile edge. */}
      <div className="flex-1 min-w-0">
        <div className="text-xs text-theme-secondary uppercase tracking-wide truncate" title={label}>
          {label}
        </div>
        <div
          className={`${valueSizeClass} font-semibold mt-1 truncate ${toneClass}`}
          title={valueStr}
        >
          {value}
        </div>
        {hint && (
          <div className="text-xs text-theme-secondary mt-0.5 truncate" title={hint}>
            {hint}
          </div>
        )}
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
