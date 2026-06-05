import React, { useEffect, useState, useCallback } from 'react';
import { Globe, Pencil, Trash2, GitBranch, ChevronRight, ChevronDown } from 'lucide-react';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanVirtualIp, SdwanPeer } from '../../../types/sdwan.types';

interface VirtualIpListProps {
  networkId: string;
  refreshKey?: number;
  onEdit?: (vip: SdwanVirtualIp) => void;
  onFailover?: (vip: SdwanVirtualIp) => void;
  onDelete?: (vip: SdwanVirtualIp) => void;
}

const stateColor = (state: string) => {
  switch (state) {
    case 'active':
      return 'text-theme-success';
    case 'pending':
      return 'text-theme-warning';
    case 'failing_over':
      return 'text-theme-warning';
    case 'unassigned':
      return 'text-theme-secondary';
    case 'error':
      return 'text-theme-danger';
    default:
      return 'text-theme-secondary';
  }
};

export const VirtualIpList: React.FC<VirtualIpListProps> = ({
  networkId,
  refreshKey,
  onEdit,
  onFailover,
  onDelete,
}) => {
  const [vips, setVips] = useState<SdwanVirtualIp[]>([]);
  const [peers, setPeers] = useState<Record<string, SdwanPeer>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());

  const toggleExpanded = useCallback((id: string) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
  }, []);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const [vipResult, peerResult] = await Promise.all([
        sdwanApi.listVirtualIps(networkId),
        sdwanApi.getPeers(networkId),
      ]);
      setVips(vipResult.virtual_ips);
      const map: Record<string, SdwanPeer> = {};
      peerResult.peers.forEach((p) => {
        map[p.id] = p;
      });
      setPeers(map);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load virtual IPs');
    } finally {
      setLoading(false);
    }
  }, [networkId]);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  const peerLabel = (peerId: string | null | undefined): string => {
    if (!peerId) return '—';
    const p = peers[peerId];
    if (!p) return peerId.slice(0, 8);
    return p.node_instance_id?.slice(0, 8) ?? peerId.slice(0, 8);
  };

  if (loading) return <div className="p-4 text-theme-secondary">Loading virtual IPs…</div>;
  if (error) return <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>;

  if (vips.length === 0) {
    return (
      <div className="p-8 text-center text-theme-secondary text-sm">
        <Globe size={32} className="mx-auto mb-2 opacity-50" />
        No virtual IPs in this network.
        <div className="mt-2 text-xs">
          Create a VIP to expose a stable address that follows a holder peer (or floats across multiple holders in anycast mode).
        </div>
      </div>
    );
  }

  return (
    <table className="w-full text-sm">
      <thead>
        <tr className="text-left text-theme-secondary border-b border-theme">
          <th className="w-8 px-3 py-2"></th>
          <th className="px-3 py-2">Name</th>
          <th className="px-3 py-2">CIDR</th>
          <th className="px-3 py-2">Mode</th>
          <th className="px-3 py-2">State</th>
          <th className="px-3 py-2">Holder</th>
          <th className="px-3 py-2">Failover</th>
          <th className="px-3 py-2 text-right">Actions</th>
        </tr>
      </thead>
      <tbody>
        {vips.map((v) => {
          const expanded = expandedIds.has(v.id);
          return (
          <React.Fragment key={v.id}>
          <tr className="border-b border-theme hover:bg-theme-background-secondary/30">
            <td className="px-3 py-2 align-middle">
              <button
                type="button"
                onClick={() => toggleExpanded(v.id)}
                className="p-1 text-theme-secondary hover:text-theme-primary"
                title={expanded ? 'Collapse details' : 'Expand details'}
                aria-label={expanded ? `Collapse VIP ${v.name}` : `Expand VIP ${v.name}`}
              >
                {expanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
              </button>
            </td>
            <td className="px-3 py-2 font-medium text-theme-primary">{v.name}</td>
            <td className="px-3 py-2 font-mono text-xs text-theme-secondary">{v.cidr}</td>
            <td className="px-3 py-2">
              {v.anycast ? (
                <span className="inline-flex items-center gap-1 text-xs">
                  <GitBranch size={12} />
                  Anycast ({v.holder_peer_ids.length})
                </span>
              ) : (
                <span className="text-xs text-theme-secondary">Active/passive</span>
              )}
            </td>
            <td className="px-3 py-2">
              <span className={`text-xs font-medium ${stateColor(v.state)}`}>{v.state}</span>
            </td>
            <td className="px-3 py-2 text-xs">
              {v.anycast
                ? v.holder_peer_ids.map(peerLabel).join(', ')
                : peerLabel(v.primary_holder_peer_id)}
            </td>
            <td className="px-3 py-2 text-xs text-theme-secondary">
              {v.failover_holder_peer_ids.length > 0
                ? `${v.failover_holder_peer_ids.length} candidate${v.failover_holder_peer_ids.length === 1 ? '' : 's'}`
                : '—'}
            </td>
            <td className="px-3 py-2">
              <div className="flex justify-end gap-1">
                {onFailover && !v.anycast && v.failover_holder_peer_ids.length > 0 && (
                  <button
                    type="button"
                    onClick={() => onFailover(v)}
                    className="p-1 hover:bg-theme-background-secondary rounded text-theme-warning"
                    title="Trigger failover"
                  >
                    <GitBranch size={14} />
                  </button>
                )}
                {onEdit && (
                  <button
                    type="button"
                    onClick={() => onEdit(v)}
                    className="p-1 hover:bg-theme-background-secondary rounded text-theme-secondary"
                    title="Edit"
                  >
                    <Pencil size={14} />
                  </button>
                )}
                {onDelete && (
                  <button
                    type="button"
                    onClick={() => onDelete(v)}
                    className="p-1 hover:bg-theme-background-secondary rounded text-theme-danger"
                    title="Delete"
                  >
                    <Trash2 size={14} />
                  </button>
                )}
              </div>
            </td>
          </tr>
          {expanded && (
            <tr className="bg-theme-background border-b border-theme">
              <td></td>
              <td colSpan={7} className="px-3 py-3">
                <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Mode</label>
                    <p className="text-theme-primary">{v.anycast ? `Anycast (${v.holder_peer_ids.length} active holders)` : 'Active/passive'}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">State</label>
                    <p className={`font-medium ${stateColor(v.state)}`}>{v.state}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">CIDR</label>
                    <p className="text-theme-primary font-mono text-xs">{v.cidr}</p>
                  </div>
                  {v.description && (
                    <div className="col-span-2 md:col-span-3">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
                      <p className="text-theme-primary">{v.description}</p>
                    </div>
                  )}
                  {!v.anycast && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Primary Holder</label>
                      <p className="text-theme-primary text-xs font-mono">{peerDetail(v.primary_holder_peer_id)}</p>
                      {v.primary_holder_address && (
                        <p className="text-theme-secondary text-xs font-mono mt-0.5">{v.primary_holder_address}</p>
                      )}
                    </div>
                  )}
                  {v.anycast && (
                    <div className="col-span-2 md:col-span-3">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Active Holders</label>
                      <p className="text-theme-primary text-xs font-mono break-all">
                        {v.holder_peer_ids.length > 0 ? v.holder_peer_ids.map(peerDetail).join(', ') : 'none'}
                      </p>
                    </div>
                  )}
                  <div className="col-span-2 md:col-span-3">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Failover Candidates</label>
                    <p className="text-theme-primary text-xs font-mono break-all">
                      {v.failover_holder_peer_ids.length > 0 ? v.failover_holder_peer_ids.map(peerDetail).join(', ') : 'none'}
                    </p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Advertised MED</label>
                    <p className="text-theme-primary">{v.advertised_med}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Advertised Local Pref</label>
                    <p className="text-theme-primary">{v.advertised_local_pref}</p>
                  </div>
                  {v.tags.length > 0 && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Tags</label>
                      <p className="text-theme-primary text-xs">{v.tags.join(', ')}</p>
                    </div>
                  )}
                  {v.created_at && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                      <p className="text-theme-primary text-xs">{new Date(v.created_at).toLocaleString()}</p>
                    </div>
                  )}
                  {v.assignments && v.assignments.length > 0 && (
                    <div className="col-span-2 md:col-span-3">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Recent Assignments</label>
                      <ul className="text-theme-primary text-xs space-y-1">
                        {v.assignments.slice(0, 5).map((a) => (
                          <li key={a.id} className="font-mono break-all">
                            {peerDetail(a.peer_id)} · {a.reason} · assumed {new Date(a.assumed_at).toLocaleString()}
                            {a.released_at ? ` · released ${new Date(a.released_at).toLocaleString()}` : a.active ? ' · active' : ''}
                          </li>
                        ))}
                      </ul>
                    </div>
                  )}
                </div>
              </td>
            </tr>
          )}
          </React.Fragment>
          );
        })}
      </tbody>
    </table>
  );

  function peerDetail(peerId: string | null | undefined): string {
    if (!peerId) return '—';
    const p = peers[peerId];
    if (!p) return peerId;
    return `${peerId} (${p.assigned_address}${p.publicly_reachable ? ', hub' : ''})`;
  }
};
