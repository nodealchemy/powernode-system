import React, { useEffect, useState, useCallback } from 'react';
import { Activity, CheckCircle, Trash2, Pause, Play, ChevronDown, ChevronRight } from 'lucide-react';
import { useArmedConfirm } from '@/shared/hooks/useArmedConfirm';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import { isPendingApproval } from '@system/features/system/services/api/helpers';
import { pendingApprovalNotice } from '@system/features/system/utils/pendingApproval';
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
  const canManage = hasPermission('system.sdwan.ipfix.manage');

  const [collectors, setCollectors] = useState<SdwanIpfixCollector[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  // Click-to-expand state — Set<id> so multiple rows can be open at once.
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
      const result = await sdwanApi.setIpfixCollectorState(c.id, next);
      if (isPendingApproval(result)) {
        addNotification(pendingApprovalNotice(`${next === 'active' ? 'enabling' : 'disabling'} collector ${c.name}`, result));
        return;
      }
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
      const result = await sdwanApi.deleteIpfixCollector(c.id);
      if (isPendingApproval(result)) {
        addNotification(pendingApprovalNotice(`deleting collector ${c.name}`, result));
        return;
      }
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
    return <div className="p-4 bg-theme-danger-bg text-theme-danger-fg rounded">{error}</div>;
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
            <th className="w-8 p-3"></th>
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
              expanded={expandedIds.has(c.id)}
              onToggleExpanded={toggleExpanded}
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
  expanded: boolean;
  onToggleExpanded: (id: string) => void;
  onToggleState: (c: SdwanIpfixCollector) => void;
  onDelete: (c: SdwanIpfixCollector) => void;
}

const CollectorRow: React.FC<CollectorRowProps> = ({ collector: c, canManage, expanded, onToggleExpanded, onToggleState, onDelete }) => {
  // State toggle is reversible — no arm-and-confirm needed.
  // Delete is destructive — arm-and-confirm gates it.
  const { armed, trigger: triggerDelete } = useArmedConfirm(() => onDelete(c));
  const isActive = c.state === 'active';

  // Richer own-detail (timestamps) lives on the detail endpoint; lazy-fetch it
  // the first time the row expands so the list view stays a single round trip.
  const [detail, setDetail] = useState<SdwanIpfixCollector | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    if (expanded && !detail && !detailError) {
      sdwanApi
        .getIpfixCollector(c.id)
        .then((full) => { if (!cancelled) setDetail(full); })
        .catch((err) => {
          if (!cancelled) setDetailError(err instanceof Error ? err.message : 'Failed to load detail');
        });
    }
    return () => { cancelled = true; };
  }, [expanded, detail, detailError, c.id]);

  const d = detail ?? c;

  return (
    <React.Fragment>
      <tr className="border-b border-theme">
        <td className="p-3 align-middle">
          <button
            type="button"
            onClick={() => onToggleExpanded(c.id)}
            className="p-1 text-theme-secondary hover:text-theme-primary"
            title={expanded ? 'Collapse details' : 'Expand details'}
            data-testid={`expand-ipfix-${c.id}`}
          >
            {expanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
          </button>
        </td>
        <td className="p-3">
          <div className="flex items-center gap-2">
            <Activity size={14} className="text-theme-info-fg" />
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
            <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-theme-success-bg text-theme-success-fg">
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
                    ? 'bg-theme-danger-bg text-theme-danger-fg px-2'
                    : 'text-theme-danger-fg hover:bg-theme-danger-bg')
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
      {expanded && (
        <tr className="bg-theme-background border-b border-theme">
          <td></td>
          <td colSpan={6} className="p-3">
            <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
              <DetailItem label="Name">{d.name}</DetailItem>
              <DetailItem label="Host" mono>{d.host}</DetailItem>
              <DetailItem label="Port" mono>{d.port}</DetailItem>
              <DetailItem label="Target Endpoint" mono>{d.target_endpoint}</DetailItem>
              <DetailItem label="Sampling Rate">1 in {d.sampling_rate}</DetailItem>
              <DetailItem label="State">{d.state}</DetailItem>
              <DetailItem label="Compiler Picks">{d.is_winning_collector ? 'Winning' : 'No'}</DetailItem>
              <DetailItem label="Collector ID" mono>{d.id}</DetailItem>
              <DetailItem label="Created">{formatTs(d.created_at)}</DetailItem>
              <DetailItem label="Updated">{formatTs(d.updated_at)}</DetailItem>
              {detailError && (
                <div className="col-span-full text-xs text-theme-danger-fg">
                  Detail unavailable: {detailError}
                </div>
              )}
            </div>
          </td>
        </tr>
      )}
    </React.Fragment>
  );
};

interface DetailItemProps {
  label: string;
  mono?: boolean;
  children: React.ReactNode;
}

const DetailItem: React.FC<DetailItemProps> = ({ label, mono, children }) => (
  <div>
    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">{label}</label>
    <div className={'text-theme-primary ' + (mono ? 'font-mono text-xs break-all' : '')}>{children}</div>
  </div>
);

function formatTs(ts?: string | null): string {
  return ts ? new Date(ts).toLocaleString() : '—';
}

function stateBadgeClass(state: SdwanIpfixState): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  return state === 'active'
    ? `${base} bg-theme-success-bg text-theme-success-fg`
    : `${base} bg-theme-background-secondary text-theme-secondary`;
}
