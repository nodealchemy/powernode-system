import React, { useEffect, useState, useCallback } from 'react';
import { Activity, CheckCircle, Trash2, Pause, Play } from 'lucide-react';
import { useArmedConfirm } from '@/shared/hooks/useArmedConfirm';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type {
  SdwanIpfixCollector,
  SdwanIpfixState,
} from '@system/features/system/types/sdwan.types';

// Phase O6 — read view of registered IPFIX collectors plus inline
// manage actions (state toggle + delete). Creation still happens via
// the SDWAN IPFIX Collector Compose skill / system_sdwan_create_ipfix_collector
// MCP action.
//
// "Compiler picks" badge: the topology compiler selects the account's
// oldest active collector when stamping the ipfix payload onto OVS
// bridges, so even with multiple collector rows only one wires up.
// Disabling the winning collector lets a sibling take over.
export const IpfixCollectorsTab: React.FC = () => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canManage = hasPermission('sdwan.ipfix.manage');

  const [collectors, setCollectors] = useState<SdwanIpfixCollector[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const result = await sdwanApi.getIpfixCollectors();
      setCollectors(result);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load IPFIX collectors');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  const handleToggleState = useCallback(async (c: SdwanIpfixCollector) => {
    const next = c.state === 'active' ? 'disabled' : 'active';
    try {
      await sdwanApi.setIpfixCollectorState(c.id, next);
      addNotification({
        type: 'success',
        message: `Collector ${c.name} ${next === 'active' ? 'enabled' : 'disabled'}`,
      });
      setRefreshKey((k) => k + 1);
    } catch (err) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to update collector state',
      });
    }
  }, [addNotification]);

  const handleDelete = useCallback(async (c: SdwanIpfixCollector) => {
    try {
      await sdwanApi.deleteIpfixCollector(c.id);
      addNotification({ type: 'success', message: `Collector ${c.name} deleted` });
      setRefreshKey((k) => k + 1);
    } catch (err) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to delete collector',
      });
    }
  }, [addNotification]);

  if (loading) {
    return <div className="p-8 text-center text-theme-secondary">Loading IPFIX collectors…</div>;
  }
  if (error) {
    return <div className="p-4 bg-theme-danger text-theme-danger rounded">{error}</div>;
  }
  if (collectors.length === 0) {
    return (
      <div className="p-12 text-center">
        <Activity className="mx-auto mb-4 text-theme-secondary" size={48} />
        <h3 className="text-lg font-medium text-theme-primary mb-2">No IPFIX collectors yet</h3>
        <p className="text-theme-secondary">
          IPFIX is heavyweight-profile only — lightweight (Linux-bridge) hosts ignore the
          payload. Register a collector via the SDWAN IPFIX Collector Compose skill or
          the <code className="text-xs">system_sdwan_create_ipfix_collector</code> MCP action.
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
            <th className="text-left p-3">Target</th>
            <th className="text-left p-3">Sampling</th>
            <th className="text-left p-3">State</th>
            <th className="text-left p-3">Compiler picks</th>
            <th className="text-right p-3">Actions</th>
          </tr>
        </thead>
        <tbody>
          {collectors.map((c) => (
            <CollectorRow
              key={c.id}
              collector={c}
              canManage={canManage}
              onToggleState={handleToggleState}
              onDelete={handleDelete}
            />
          ))}
        </tbody>
      </table>
    </div>
  );
};

interface CollectorRowProps {
  collector: SdwanIpfixCollector;
  canManage: boolean;
  onToggleState: (c: SdwanIpfixCollector) => void;
  onDelete: (c: SdwanIpfixCollector) => void;
}

const CollectorRow: React.FC<CollectorRowProps> = ({ collector: c, canManage, onToggleState, onDelete }) => {
  // State toggle is reversible — no arm-and-confirm needed.
  // Delete is destructive — arm-and-confirm gates it.
  const { armed, trigger: triggerDelete } = useArmedConfirm(() => onDelete(c));
  const isActive = c.state === 'active';

  return (
    <tr className="border-b border-theme">
      <td className="p-3">
        <div className="flex items-center gap-2">
          <Activity size={14} className="text-theme-info" />
          <span className="font-medium text-theme-primary">{c.name}</span>
        </div>
      </td>
      <td className="p-3 font-mono text-xs text-theme-secondary">{c.target_endpoint}</td>
      <td className="p-3 text-theme-secondary text-sm">1 in {c.sampling_rate}</td>
      <td className="p-3">
        <span className={stateBadgeClass(c.state)}>{c.state}</span>
      </td>
      <td className="p-3">
        {c.is_winning_collector ? (
          <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-theme-success text-theme-success">
            <CheckCircle size={12} /> Winning
          </span>
        ) : (
          <span className="text-xs text-theme-secondary">—</span>
        )}
      </td>
      <td className="p-3 text-right">
        {canManage && (
          <div className="flex items-center justify-end gap-2">
            <button
              type="button"
              onClick={() => onToggleState(c)}
              className="p-1 rounded text-theme-secondary hover:bg-theme-surface-hover"
              aria-label={isActive ? `Disable ${c.name}` : `Enable ${c.name}`}
              title={isActive ? 'Disable collector' : 'Enable collector'}
              data-testid={`toggle-ipfix-${c.id}`}
            >
              {isActive ? <Pause size={16} /> : <Play size={16} />}
            </button>
            <button
              type="button"
              onClick={triggerDelete}
              className={
                'p-1 rounded text-xs ' +
                (armed
                  ? 'bg-theme-danger text-theme-danger px-2'
                  : 'text-theme-danger hover:bg-theme-danger')
              }
              aria-label={`Delete collector ${c.name}`}
              title={armed ? 'Click to confirm' : 'Delete collector'}
              data-testid={`delete-ipfix-${c.id}`}
            >
              {armed ? 'Confirm?' : <Trash2 size={16} />}
            </button>
          </div>
        )}
      </td>
    </tr>
  );
};

function stateBadgeClass(state: SdwanIpfixState): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  return state === 'active'
    ? `${base} bg-theme-success text-theme-success`
    : `${base} bg-theme-background-secondary text-theme-secondary`;
}
