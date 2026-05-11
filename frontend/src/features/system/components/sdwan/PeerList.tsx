import React, { useEffect, useState, useCallback } from 'react';
import { Globe, Server, Trash2, Pencil } from 'lucide-react';
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
            <th className="text-left p-3">Role</th>
            <th className="text-left p-3">Address</th>
            <th className="text-left p-3">Endpoint</th>
            <th className="text-left p-3">Status</th>
            <th className="text-left p-3">Last handshake</th>
            <th className="text-right p-3">Actions</th>
          </tr>
        </thead>
        <tbody>
          {peers.map((p) => (
            <tr key={p.id} className="border-b border-theme">
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
          ))}
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
