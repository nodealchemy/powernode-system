import React, { useEffect, useState, useCallback } from 'react';
import { Network as NetworkIcon, Trash2 } from 'lucide-react';
import { useArmedConfirm } from '@/shared/hooks/useArmedConfirm';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type {
  SdwanHostBridge,
  SdwanHostBridgeState,
} from '@system/features/system/types/sdwan.types';

// Phase O6 — read-only operator view of allocated SDWAN host bridges
// (now with inline manage actions). Allocation happens through the
// agent reconcile loop / AI compose skill / MCP action; the inline
// delete button uses arm-and-confirm and force-removes the bridge
// (short_id returns to the pool immediately).
//
// Bridges are grouped visually by host — the controller sorts by
// (node_instance_id, short_id) so consecutive rows share a host.
export const HostBridgesTab: React.FC = () => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canManage = hasPermission('sdwan.host_bridges.manage');

  const [bridges, setBridges] = useState<SdwanHostBridge[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const result = await sdwanApi.getHostBridges();
      setBridges(result);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load host bridges');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  const handleDelete = useCallback(async (bridge: SdwanHostBridge) => {
    try {
      await sdwanApi.deleteHostBridge(bridge.id);
      addNotification({ type: 'success', message: `Bridge ${bridge.bridge_name} removed` });
      setRefreshKey((k) => k + 1);
    } catch (err) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to remove bridge',
      });
    }
  }, [addNotification]);

  if (loading) {
    return <div className="p-8 text-center text-theme-secondary">Loading host bridges…</div>;
  }
  if (error) {
    return <div className="p-4 bg-theme-danger text-theme-danger rounded">{error}</div>;
  }
  if (bridges.length === 0) {
    return (
      <div className="p-12 text-center">
        <NetworkIcon className="mx-auto mb-4 text-theme-secondary" size={48} />
        <h3 className="text-lg font-medium text-theme-primary mb-2">No host bridges yet</h3>
        <p className="text-theme-secondary">
          Bridges are allocated by the on-node agent (during reconcile) or by the SDWAN
          Host Bridge Compose skill. Lightweight-profile hosts get a Linux bridge;
          heavyweight-profile hosts get OVS.
        </p>
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full">
        <thead className="bg-theme-background-secondary text-theme-secondary text-sm">
          <tr>
            <th className="text-left p-3">Host</th>
            <th className="text-left p-3">Profile</th>
            <th className="text-left p-3">Bridge</th>
            <th className="text-left p-3">Kind</th>
            <th className="text-left p-3">State</th>
            <th className="text-left p-3">Short ID</th>
            <th className="text-right p-3">Actions</th>
          </tr>
        </thead>
        <tbody>
          {bridges.map((b) => (
            <BridgeRow
              key={b.id}
              bridge={b}
              canManage={canManage}
              onDelete={handleDelete}
            />
          ))}
        </tbody>
      </table>
    </div>
  );
};

interface BridgeRowProps {
  bridge: SdwanHostBridge;
  canManage: boolean;
  onDelete: (bridge: SdwanHostBridge) => void;
}

const BridgeRow: React.FC<BridgeRowProps> = ({ bridge: b, canManage, onDelete }) => {
  // Per-row armed-confirm state so each row's delete button arms
  // independently; one row's armed state never bleeds into another.
  const { armed, trigger } = useArmedConfirm(() => onDelete(b));

  return (
    <tr className="border-b border-theme-border">
      <td className="p-3 text-theme-primary">{b.node_instance_name ?? b.node_instance_id}</td>
      <td className="p-3 text-theme-secondary text-sm">{b.network_profile ?? '—'}</td>
      <td className="p-3 font-mono text-xs text-theme-secondary">{b.bridge_name}</td>
      <td className="p-3">
        <span className={kindBadgeClass(b.kind)}>{b.kind}</span>
      </td>
      <td className="p-3">
        <span className={stateBadgeClass(b.state)}>{b.state}</span>
      </td>
      <td className="p-3 text-theme-secondary text-sm">{b.short_id}</td>
      <td className="p-3 text-right">
        {canManage && b.state !== 'removed' && (
          <button
            type="button"
            onClick={trigger}
            className={
              'p-1 rounded text-xs ' +
              (armed
                ? 'bg-theme-danger text-theme-danger px-2'
                : 'text-theme-danger hover:bg-theme-danger')
            }
            aria-label={`Remove bridge ${b.bridge_name}`}
            title={armed ? 'Click to confirm' : 'Remove bridge'}
            data-testid={`delete-host-bridge-${b.id}`}
          >
            {armed ? 'Confirm?' : <Trash2 size={16} />}
          </button>
        )}
      </td>
    </tr>
  );
};

function kindBadgeClass(kind: 'linux' | 'ovs'): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  return kind === 'ovs'
    ? `${base} bg-theme-info text-theme-info`
    : `${base} bg-theme-background-secondary text-theme-secondary`;
}

function stateBadgeClass(state: SdwanHostBridgeState): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  switch (state) {
    case 'active':
      return `${base} bg-theme-success text-theme-success`;
    case 'pending':
      return `${base} bg-theme-info text-theme-info`;
    case 'draining':
      return `${base} bg-theme-warning text-theme-warning`;
    case 'removed':
      return `${base} bg-theme-background-secondary text-theme-secondary`;
    default:
      return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}
