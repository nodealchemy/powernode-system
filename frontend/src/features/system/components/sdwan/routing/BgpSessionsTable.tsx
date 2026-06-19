import React, { useEffect, useState, useCallback } from 'react';
import { Activity, RefreshCw, ChevronRight, ChevronDown } from 'lucide-react';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanBgpSession } from '../../../types/sdwan.types';

interface BgpSessionsTableProps {
  networkId?: string;
  refreshKey?: number;
}

const stateColor = (state: string) => {
  switch (state) {
    case 'established':
      return 'text-theme-success-fg';
    case 'opensent':
    case 'openconfirm':
    case 'connect':
    case 'active':
      return 'text-theme-warning-fg';
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

  // Expansion state — Set<id> so multiple session rows can stay open at once.
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  const toggleExpanded = useCallback((id: string) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  }, []);

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
        <div className="p-3 bg-theme-danger-bg text-theme-danger-fg rounded text-sm">{error}</div>
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
              <th className="w-8 px-2 py-2"></th>
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
            {sessions.map((s) => {
              const expanded = expandedIds.has(s.id);
              return (
                <React.Fragment key={s.id}>
                  <tr className="border-b border-theme hover:bg-theme-background-secondary/30">
                    <td className="px-2 py-2 align-top">
                      <button
                        type="button"
                        onClick={() => toggleExpanded(s.id)}
                        className="p-1 text-theme-secondary hover:text-theme-primary"
                        title={expanded ? 'Collapse details' : 'Expand details'}
                      >
                        {expanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                      </button>
                    </td>
                    {/* peer_id / neighbor_peer_id reference SDWAN peers; that
                        type is not registered, so they render as plain text. */}
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
                  {expanded && (
                    <tr className="bg-theme-background border-b border-theme">
                      <td></td>
                      <td colSpan={7} className="px-3 py-3">
                        <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Local peer</label>
                            <p className="text-theme-primary font-mono text-xs break-all" title={s.peer_id}>{s.peer_id}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Neighbor address</label>
                            <p className="text-theme-primary font-mono text-xs break-all">{s.neighbor_address}</p>
                          </div>
                          {s.neighbor_peer_id && (
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Neighbor peer</label>
                              <p className="text-theme-primary font-mono text-xs break-all" title={s.neighbor_peer_id}>{s.neighbor_peer_id}</p>
                            </div>
                          )}
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">State</label>
                            <p className={`font-medium ${stateColor(s.state)}`}>{s.state}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Uptime</label>
                            <p className="text-theme-primary">{formatUptime(s.uptime_seconds)} ({s.uptime_seconds}s)</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Prefixes Rx / Tx</label>
                            <p className="text-theme-primary">{s.prefixes_received} received · {s.prefixes_sent} sent</p>
                          </div>
                          {s.last_state_change_at && (
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last state change</label>
                              <p className="text-theme-primary text-xs">{new Date(s.last_state_change_at).toLocaleString()}</p>
                            </div>
                          )}
                          {s.last_observed_at && (
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last observed</label>
                              <p className="text-theme-primary text-xs">{new Date(s.last_observed_at).toLocaleString()}</p>
                            </div>
                          )}
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Session ID</label>
                            <p className="text-theme-primary font-mono text-xs break-all" title={s.id}>{s.id}</p>
                          </div>
                        </div>

                        {s.last_error && (
                          <div className="mt-3">
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last error</label>
                            <pre className="font-mono text-xs bg-theme-surface border border-theme rounded px-2 py-1 whitespace-pre-wrap text-theme-danger-fg">{s.last_error}</pre>
                          </div>
                        )}

                        <div className="mt-3 text-xs text-theme-secondary">
                          The full compiled FRR config (frr.conf) for a peer is available via the MCP tool{' '}
                          <code className="font-mono">system_sdwan_get_bgp_config_for_peer</code>; per-neighbor learned
                          routes appear inline under each peer in the topology view.
                        </div>
                      </td>
                    </tr>
                  )}
                </React.Fragment>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
};
