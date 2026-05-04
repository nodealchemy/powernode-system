import React, { useEffect, useState, useCallback } from 'react';
import { Network as NetworkIcon, Trash2 } from 'lucide-react';
import { sdwanApi } from '../../services/api/sdwanApi';
import type { SdwanNetwork } from '../../types/sdwan.types';

interface NetworkListProps {
  onView: (network: SdwanNetwork) => void;
  onDelete?: (network: SdwanNetwork) => void;
  refreshKey?: number;
}

/**
 * NetworkList — operator-facing list of SDWAN networks.
 *
 * Slice 3 ships a flat-list rendering instead of useInfiniteResourceList
 * because the typical account has fewer than 50 networks; pagination/scroll
 * is overkill at this scale and obscures the at-a-glance fleet view.
 * Slice 5 adds infinite scroll if/when networks grow into the hundreds.
 */
export const NetworkList: React.FC<NetworkListProps> = ({ onView, onDelete, refreshKey }) => {
  const [networks, setNetworks] = useState<SdwanNetwork[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const result = await sdwanApi.getNetworks();
      setNetworks(result.networks);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load networks');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  if (loading) {
    return <div className="p-8 text-center text-theme-secondary">Loading networks…</div>;
  }
  if (error) {
    return <div className="p-4 bg-theme-danger text-theme-danger rounded">{error}</div>;
  }
  if (networks.length === 0) {
    return (
      <div className="p-12 text-center">
        <NetworkIcon className="mx-auto mb-4 text-theme-secondary" size={48} />
        <h3 className="text-lg font-medium text-theme-primary mb-2">No SDWAN networks yet</h3>
        <p className="text-theme-secondary">
          Create your first overlay network to start connecting node instances.
        </p>
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full">
        <thead className="bg-theme-background-secondary text-theme-secondary text-sm">
          <tr>
            <th className="text-left p-3">Name</th>
            <th className="text-left p-3">Status</th>
            <th className="text-left p-3">CIDR</th>
            <th className="text-left p-3">Peers</th>
            <th className="text-left p-3">Hub / Spoke</th>
            <th className="text-right p-3">Actions</th>
          </tr>
        </thead>
        <tbody>
          {networks.map((n) => (
            <tr
              key={n.id}
              className="border-b border-theme-border hover:bg-theme-hover cursor-pointer"
              onClick={() => onView(n)}
            >
              <td className="p-3">
                <div className="flex items-center gap-2">
                  <NetworkIcon size={16} className="text-theme-accent" />
                  <span className="font-medium text-theme-primary">{n.name}</span>
                </div>
                <div className="text-xs text-theme-secondary">{n.slug}</div>
              </td>
              <td className="p-3">
                <span className={statusBadgeClass(n.status)}>{n.status}</span>
              </td>
              <td className="p-3 font-mono text-xs text-theme-secondary">{n.cidr_64}</td>
              <td className="p-3 text-theme-primary">{n.peer_count}</td>
              <td className="p-3 text-theme-secondary text-sm">
                {(n.hub_count ?? 0)} hub{(n.hub_count ?? 0) === 1 ? '' : 's'} ·{' '}
                {(n.spoke_count ?? 0)} spoke{(n.spoke_count ?? 0) === 1 ? '' : 's'}
              </td>
              <td className="p-3 text-right">
                {onDelete && (
                  <button
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      onDelete(n);
                    }}
                    className="text-theme-danger hover:bg-theme-danger p-1 rounded"
                    aria-label={`Delete ${n.name}`}
                    data-testid={`delete-network-${n.id}`}
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

function statusBadgeClass(status: string): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  switch (status) {
    case 'active':
      return `${base} bg-theme-success text-theme-success`;
    case 'registered':
      return `${base} bg-theme-info text-theme-info`;
    case 'suspended':
      return `${base} bg-theme-warning text-theme-warning`;
    case 'archived':
      return `${base} bg-theme-background-secondary text-theme-secondary`;
    default:
      return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}
