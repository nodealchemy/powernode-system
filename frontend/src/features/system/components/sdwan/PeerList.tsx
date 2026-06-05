import React, { useEffect, useState, useCallback } from 'react';
import { Globe, Server, Trash2, Pencil, ChevronRight, ChevronDown } from 'lucide-react';
import { sdwanApi } from '../../services/api/sdwanApi';
import type { SdwanPeer } from '../../types/sdwan.types';

interface PeerListProps {
  networkId: string;
  onDetach?: (peer: SdwanPeer) => void;
  onEdit?: (peer: SdwanPeer) => void;
  refreshKey?: number;
}

export const PeerList: React.FC<PeerListProps> = ({ networkId, onDetach, onEdit, refreshKey }) => {
  const [peers, setPeers] = useState<SdwanPeer[]>([]);
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
      const result = await sdwanApi.getPeers(networkId);
      setPeers(result.peers);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load peers');
    } finally {
      setLoading(false);
    }
  }, [networkId]);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  if (loading) return <div className="p-4 text-theme-secondary">Loading peers…</div>;
  if (error) return <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>;

  if (peers.length === 0) {
    return (
      <div className="p-8 text-center text-theme-secondary text-sm">
        No peers attached yet. Use the Attach Peer button to add a node instance.
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full">
        <thead className="bg-theme-background-secondary text-theme-secondary text-sm">
          <tr>
            <th className="w-8 p-3"></th>
            <th className="text-left p-3">Role</th>
            <th className="text-left p-3">Address</th>
            <th className="text-left p-3">Endpoint</th>
            <th className="text-left p-3">Status</th>
            <th className="text-left p-3">Last handshake</th>
            <th className="text-right p-3">Actions</th>
          </tr>
        </thead>
        <tbody>
          {peers.map((p) => {
            const expanded = expandedIds.has(p.id);
            return (
            <React.Fragment key={p.id}>
            <tr className="border-b border-theme">
              <td className="p-3 align-middle">
                <button
                  type="button"
                  onClick={() => toggleExpanded(p.id)}
                  className="p-1 text-theme-secondary hover:text-theme-primary"
                  title={expanded ? 'Collapse details' : 'Expand details'}
                  aria-label={expanded ? `Collapse peer ${p.assigned_address}` : `Expand peer ${p.assigned_address}`}
                >
                  {expanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
                </button>
              </td>
              <td className="p-3">
                <div className="flex items-center gap-2">
                  {p.publicly_reachable ? (
                    <>
                      <Globe size={16} className="text-theme-info" />
                      <span className="text-sm text-theme-primary">Hub</span>
                    </>
                  ) : (
                    <>
                      <Server size={16} className="text-theme-secondary" />
                      <span className="text-sm text-theme-secondary">Spoke</span>
                    </>
                  )}
                </div>
              </td>
              <td className="p-3 font-mono text-xs text-theme-primary">{p.assigned_address}</td>
              <td className="p-3 font-mono text-xs text-theme-secondary">
                {p.endpoint || (p.publicly_reachable ? '—' : 'outbound only')}
              </td>
              <td className="p-3">
                <span className={peerStatusClass(p.status)}>{p.status}</span>
              </td>
              <td className="p-3 text-xs text-theme-secondary">
                {p.last_handshake_at ? new Date(p.last_handshake_at).toLocaleString() : 'never'}
              </td>
              <td className="p-3 text-right">
                {onEdit && (
                  <button
                    type="button"
                    onClick={() => onEdit(p)}
                    className="text-theme-secondary hover:bg-theme-surface-hover p-1 rounded mr-1"
                    aria-label={`Edit peer ${p.assigned_address}`}
                  >
                    <Pencil size={16} />
                  </button>
                )}
                {onDetach && (
                  <button
                    type="button"
                    onClick={() => onDetach(p)}
                    className="text-theme-danger hover:bg-theme-danger p-1 rounded"
                    aria-label={`Detach peer ${p.assigned_address}`}
                  >
                    <Trash2 size={16} />
                  </button>
                )}
              </td>
            </tr>
            {expanded && (
              <tr className="bg-theme-background border-b border-theme">
                <td></td>
                <td colSpan={6} className="p-3">
                  <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Role</label>
                      <p className="text-theme-primary">{p.publicly_reachable ? 'Hub (publicly reachable)' : 'Spoke (outbound only)'}</p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Overlay Address</label>
                      <p className="text-theme-primary font-mono text-xs">{p.assigned_address}</p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Status</label>
                      <p className="text-theme-primary">{p.status}</p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last Handshake</label>
                      <p className="text-theme-primary text-xs">{p.last_handshake_at ? new Date(p.last_handshake_at).toLocaleString() : 'never'}</p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Listen Port</label>
                      <p className="text-theme-primary font-mono text-xs">{p.listen_port}</p>
                    </div>
                    {p.effective_endpoint && (
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Effective Endpoint</label>
                        <p className="text-theme-primary font-mono text-xs break-all">
                          {p.effective_endpoint}
                          {p.effective_endpoint_family ? ` (${p.effective_endpoint_family})` : ''}
                        </p>
                      </div>
                    )}
                    {p.fallback_endpoint && (
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Fallback Endpoint</label>
                        <p className="text-theme-primary font-mono text-xs break-all">{p.fallback_endpoint}</p>
                      </div>
                    )}
                    {(p.endpoint_host_v6 || p.endpoint_host_v4) && (
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Endpoint Hosts</label>
                        <p className="text-theme-primary font-mono text-xs break-all">
                          {p.endpoint_host_v6 ? `v6 ${p.endpoint_host_v6}` : ''}
                          {p.endpoint_host_v6 && p.endpoint_host_v4 ? ' · ' : ''}
                          {p.endpoint_host_v4 ? `v4 ${p.endpoint_host_v4}` : ''}
                          {p.endpoint_port ? `:${p.endpoint_port}` : ''}
                        </p>
                      </div>
                    )}
                    {p.public_key && (
                      <div className="col-span-2 md:col-span-3">
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Public Key</label>
                        <p className="text-theme-primary font-mono text-xs break-all">{p.public_key}</p>
                      </div>
                    )}
                    <div className="col-span-2 md:col-span-3">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">LAN Subnets</label>
                      <p className="text-theme-primary font-mono text-xs break-all">
                        {p.lan_subnets && p.lan_subnets.length > 0 ? p.lan_subnets.join(', ') : 'none advertised'}
                      </p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">BGP Route Reflector Client</label>
                      <p className="text-theme-primary">{p.bgp_route_reflector_client ? 'Yes' : 'No'}</p>
                    </div>
                    {p.bgp_router_id_override && (
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">BGP Router ID Override</label>
                        <p className="text-theme-primary font-mono text-xs">{p.bgp_router_id_override}</p>
                      </div>
                    )}
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Advertised Prefixes</label>
                      <p className="text-theme-primary">{p.advertised_prefix_count ?? 0}</p>
                    </div>
                    <div className="col-span-2 md:col-span-3">
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Node Instance ID</label>
                      <p className="text-theme-primary font-mono text-xs break-all" title={p.node_instance_id}>{p.node_instance_id}</p>
                    </div>
                    {p.capabilities && Object.keys(p.capabilities).length > 0 && (
                      <div className="col-span-2 md:col-span-3">
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Capabilities</label>
                        <pre className="text-theme-primary font-mono text-xs whitespace-pre-wrap break-all bg-theme-background-secondary rounded p-2">{JSON.stringify(p.capabilities, null, 2)}</pre>
                      </div>
                    )}
                    {p.created_at && (
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Attached</label>
                        <p className="text-theme-primary text-xs">{new Date(p.created_at).toLocaleString()}</p>
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
    </div>
  );
};

function peerStatusClass(status: string): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  switch (status) {
    case 'active': return `${base} bg-theme-success text-theme-success`;
    case 'degraded': return `${base} bg-theme-warning text-theme-warning`;
    case 'pending': return `${base} bg-theme-info text-theme-info`;
    case 'disconnected': return `${base} bg-theme-danger text-theme-danger`;
    default: return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}
