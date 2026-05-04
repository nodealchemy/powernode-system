import React, { useEffect, useState, useCallback } from 'react';
import { ArrowRightLeft, Pencil, Trash2, Power, PowerOff } from 'lucide-react';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanPortMapping, SdwanPeer } from '../../../types/sdwan.types';

interface PortMappingListProps {
  networkId: string;
  refreshKey?: number;
  onEdit?: (mapping: SdwanPortMapping) => void;
  onDelete?: (mapping: SdwanPortMapping) => void;
  onToggle?: (mapping: SdwanPortMapping) => void;
}

export const PortMappingList: React.FC<PortMappingListProps> = ({
  networkId,
  refreshKey,
  onEdit,
  onDelete,
  onToggle,
}) => {
  const [mappings, setMappings] = useState<SdwanPortMapping[]>([]);
  const [peerById, setPeerById] = useState<Record<string, SdwanPeer>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const [mResult, pResult] = await Promise.all([
        sdwanApi.listPortMappings(networkId),
        sdwanApi.getPeers(networkId),
      ]);
      setMappings(mResult.port_mappings);
      const map: Record<string, SdwanPeer> = {};
      pResult.peers.forEach((p) => {
        map[p.id] = p;
      });
      setPeerById(map);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load port mappings');
    } finally {
      setLoading(false);
    }
  }, [networkId]);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  const peerLabel = (peerId: string | null | undefined): string => {
    if (!peerId) return '—';
    const p = peerById[peerId];
    if (!p) return peerId.slice(0, 8);
    return `${peerId.slice(0, 8)}${p.publicly_reachable ? ' (hub)' : ''}`;
  };

  if (loading) return <div className="p-4 text-theme-secondary">Loading port mappings…</div>;
  if (error) return <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>;

  if (mappings.length === 0) {
    return (
      <div className="p-8 text-center text-theme-secondary text-sm">
        <ArrowRightLeft size={32} className="mx-auto mb-2 opacity-50" />
        No port mappings in this network.
        <div className="mt-2 text-xs">
          Port mappings publish overlay services to v4-only clients via DNAT on a hub peer's underlay socket.
          Inbound packets to <code className="font-mono">hub:port</code> get redirected to a target peer's overlay address.
        </div>
      </div>
    );
  }

  return (
    <table className="w-full text-sm">
      <thead>
        <tr className="text-left text-theme-secondary border-b border-theme">
          <th className="px-3 py-2">Name</th>
          <th className="px-3 py-2">Hub</th>
          <th className="px-3 py-2">Listen</th>
          <th className="px-3 py-2">Target</th>
          <th className="px-3 py-2">Target Port</th>
          <th className="px-3 py-2">Enabled</th>
          <th className="px-3 py-2 text-right">Actions</th>
        </tr>
      </thead>
      <tbody>
        {mappings.map((m) => (
          <tr key={m.id} className="border-b border-theme hover:bg-theme-background-secondary/30">
            <td className="px-3 py-2">
              <div className="font-medium text-theme-primary">{m.name}</div>
              {m.description && <div className="text-xs text-theme-secondary">{m.description}</div>}
            </td>
            <td className="px-3 py-2 font-mono text-xs">{peerLabel(m.hub_peer_id)}</td>
            <td className="px-3 py-2 font-mono text-xs">
              <span className={m.protocol === 'tcp' ? 'text-theme-info' : 'text-theme-success'}>
                {m.protocol}
              </span>
              <span className="text-theme-secondary mx-1">/</span>
              {m.listen_port}
            </td>
            <td className="px-3 py-2 text-xs">
              {m.target_virtual_ip_id ? (
                <span>
                  <span className="text-theme-warning">VIP</span>{' '}
                  <span className="font-mono">{m.target_virtual_ip_id.slice(0, 8)}</span>
                </span>
              ) : (
                <span className="font-mono">{peerLabel(m.target_peer_id)}</span>
              )}
              {m.resolved_target_address && (
                <div className="font-mono text-xs text-theme-secondary mt-0.5">
                  → {m.resolved_target_address}
                </div>
              )}
            </td>
            <td className="px-3 py-2 font-mono text-xs">{m.effective_target_port}</td>
            <td className="px-3 py-2">
              {m.enabled ? (
                <Power size={14} className="text-theme-success" />
              ) : (
                <PowerOff size={14} className="text-theme-secondary" />
              )}
            </td>
            <td className="px-3 py-2">
              <div className="flex justify-end gap-1">
                {onToggle && (
                  <button
                    type="button"
                    onClick={() => onToggle(m)}
                    className="p-1 hover:bg-theme-background-secondary rounded text-theme-secondary"
                    title={m.enabled ? 'Disable' : 'Enable'}
                  >
                    {m.enabled ? <PowerOff size={14} /> : <Power size={14} />}
                  </button>
                )}
                {onEdit && (
                  <button
                    type="button"
                    onClick={() => onEdit(m)}
                    className="p-1 hover:bg-theme-background-secondary rounded text-theme-secondary"
                    title="Edit"
                  >
                    <Pencil size={14} />
                  </button>
                )}
                {onDelete && (
                  <button
                    type="button"
                    onClick={() => onDelete(m)}
                    className="p-1 hover:bg-theme-background-secondary rounded text-theme-danger"
                    title="Delete"
                  >
                    <Trash2 size={14} />
                  </button>
                )}
              </div>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
};
