import React, { useEffect, useState, useCallback } from 'react';
import { Activity, RefreshCw } from 'lucide-react';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanBgpSession } from '../../../types/sdwan.types';

interface BgpSessionsTableProps {
  networkId?: string;
  refreshKey?: number;
}

const stateColor = (state: string) => {
  switch (state) {
    case 'established':
      return 'text-theme-success';
    case 'opensent':
    case 'openconfirm':
    case 'connect':
    case 'active':
      return 'text-theme-warning';
    case 'idle':
      return 'text-theme-secondary';
    default:
      return 'text-theme-secondary';
  }
};

const formatUptime = (seconds: number): string => {
  if (seconds <= 0) return '—';
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
};

export const BgpSessionsTable: React.FC<BgpSessionsTableProps> = ({ networkId, refreshKey }) => {
  const [sessions, setSessions] = useState<SdwanBgpSession[]>([]);
  const [stateFilter, setStateFilter] = useState<string>('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const result = await sdwanApi.getBgpSessions({
        network_id: networkId,
        state: stateFilter || undefined,
      });
      setSessions(result.sessions);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load BGP sessions');
    } finally {
      setLoading(false);
    }
  }, [networkId, stateFilter]);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-3">
        <select
          value={stateFilter}
          onChange={(e) => setStateFilter(e.target.value)}
          className="px-2 py-1.5 rounded bg-theme-surface border border-theme text-sm text-theme-primary"
        >
          <option value="">All states</option>
          <option value="established">Established</option>
          <option value="active">Active</option>
          <option value="connect">Connect</option>
          <option value="opensent">OpenSent</option>
          <option value="openconfirm">OpenConfirm</option>
          <option value="idle">Idle</option>
        </select>
        <button
          type="button"
          onClick={() => load()}
          className="px-2 py-1.5 rounded bg-theme-surface border border-theme text-sm hover:bg-theme-background-secondary"
          title="Refresh"
        >
          <RefreshCw size={14} />
        </button>
        <div className="text-xs text-theme-secondary ml-auto">
          {sessions.length} session{sessions.length === 1 ? '' : 's'}
        </div>
      </div>

      {loading ? (
        <div className="p-4 text-theme-secondary text-sm">Loading sessions…</div>
      ) : error ? (
        <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>
      ) : sessions.length === 0 ? (
        <div className="p-8 text-center text-theme-secondary text-sm">
          <Activity size={32} className="mx-auto mb-2 opacity-50" />
          No BGP sessions reported yet.
          <div className="mt-1 text-xs">
            Sessions appear here once an agent on an iBGP-enabled peer reports its observed FRR state via heartbeat.
          </div>
        </div>
      ) : (
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-theme-secondary border-b border-theme">
              <th className="px-3 py-2">Local peer</th>
              <th className="px-3 py-2">Neighbor</th>
              <th className="px-3 py-2">State</th>
              <th className="px-3 py-2">Uptime</th>
              <th className="px-3 py-2">Rx prefixes</th>
              <th className="px-3 py-2">Tx prefixes</th>
              <th className="px-3 py-2">Last observed</th>
            </tr>
          </thead>
          <tbody>
            {sessions.map((s) => (
              <tr key={s.id} className="border-b border-theme hover:bg-theme-background-secondary/30">
                <td className="px-3 py-2 font-mono text-xs">{s.peer_id.slice(0, 8)}</td>
                <td className="px-3 py-2 font-mono text-xs">{s.neighbor_address}</td>
                <td className="px-3 py-2">
                  <span className={`text-xs font-medium ${stateColor(s.state)}`}>{s.state}</span>
                </td>
                <td className="px-3 py-2 text-xs">{formatUptime(s.uptime_seconds)}</td>
                <td className="px-3 py-2 text-xs">{s.prefixes_received}</td>
                <td className="px-3 py-2 text-xs">{s.prefixes_sent}</td>
                <td className="px-3 py-2 text-xs text-theme-secondary">
                  {s.last_observed_at ? new Date(s.last_observed_at).toLocaleString() : '—'}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
};
