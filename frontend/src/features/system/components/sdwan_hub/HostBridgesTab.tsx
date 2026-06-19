import React, { useEffect, useState, useCallback } from 'react';
import { Network as NetworkIcon, Trash2, ChevronDown, ChevronRight } from 'lucide-react';
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
    return <div className="p-4 bg-theme-danger-bg text-theme-danger-fg rounded">{error}</div>;
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
            <th className="w-8 p-3"></th>
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
              expanded={expandedIds.has(b.id)}
              onToggleExpanded={toggleExpanded}
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
  expanded: boolean;
  onToggleExpanded: (id: string) => void;
  onDelete: (bridge: SdwanHostBridge) => void;
}

// The host is a cross-reference to a node_instance. The shared EntityLink
// `node_instance` type requires a composite "nodeId:instanceId" id, but the
// host-bridge payload only carries the bare instance id (the parent node id is
// not serialized — see serialize_bridge in host_bridges_controller.rb). Per the
// linking rules we never invent the missing segment, so the host stays plain
// text until the parent node id is available — mirroring VolumeList's guarded
// renderAttachedInstance. When the API adds node_id, wrap this in
// <EntityLink type="node_instance" id={`${nodeId}:${instanceId}`} .../>.
const renderHost = (b: SdwanHostBridge): React.ReactNode => {
  const label = b.node_instance_name ?? b.node_instance_id;
  return <span className="text-theme-primary">{label}</span>;
};

const BridgeRow: React.FC<BridgeRowProps> = ({ bridge: b, canManage, expanded, onToggleExpanded, onDelete }) => {
  // Per-row armed-confirm state so each row's delete button arms
  // independently; one row's armed state never bleeds into another.
  const { armed, trigger } = useArmedConfirm(() => onDelete(b));

  // Richer own-detail (timestamps) lives on the detail endpoint; lazy-fetch it
  // the first time the row expands so the list view stays a single round trip.
  const [detail, setDetail] = useState<SdwanHostBridge | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    if (expanded && !detail && !detailError) {
      sdwanApi
        .getHostBridge(b.id)
        .then((full) => { if (!cancelled) setDetail(full); })
        .catch((err) => {
          if (!cancelled) setDetailError(err instanceof Error ? err.message : 'Failed to load detail');
        });
    }
    return () => { cancelled = true; };
  }, [expanded, detail, detailError, b.id]);

  const d = detail ?? b;

  return (
    <React.Fragment>
      <tr className="border-b border-theme">
        <td className="p-3 align-middle">
          <button
            type="button"
            onClick={() => onToggleExpanded(b.id)}
            className="p-1 text-theme-secondary hover:text-theme-primary"
            title={expanded ? 'Collapse details' : 'Expand details'}
            data-testid={`expand-host-bridge-${b.id}`}
          >
            {expanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
          </button>
        </td>
        <td className="p-3">{renderHost(b)}</td>
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
                  ? 'bg-theme-danger-bg text-theme-danger-fg px-2'
                  : 'text-theme-danger-fg hover:bg-theme-danger-bg')
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
      {expanded && (
        <tr className="bg-theme-background border-b border-theme">
          <td></td>
          <td colSpan={7} className="p-3">
            <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
              <DetailItem label="Host">{renderHost(d)}</DetailItem>
              <DetailItem label="Network Profile">{d.network_profile ?? '—'}</DetailItem>
              <DetailItem label="Bridge Name" mono>{d.bridge_name}</DetailItem>
              <DetailItem label="Kind">{d.kind}</DetailItem>
              <DetailItem label="State">{d.state}</DetailItem>
              <DetailItem label="Short ID">{d.short_id}</DetailItem>
              <DetailItem label="Bridge ID" mono>{d.id}</DetailItem>
              <DetailItem label="Applied">{formatTs(d.applied_at)}</DetailItem>
              <DetailItem label="Draining">{formatTs(d.draining_at)}</DetailItem>
              <DetailItem label="Removed">{formatTs(d.removed_at)}</DetailItem>
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

function kindBadgeClass(kind: 'linux' | 'ovs'): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  return kind === 'ovs'
    ? `${base} bg-theme-info-bg text-theme-info-fg`
    : `${base} bg-theme-background-secondary text-theme-secondary`;
}

function stateBadgeClass(state: SdwanHostBridgeState): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  switch (state) {
    case 'active':
      return `${base} bg-theme-success-bg text-theme-success-fg`;
    case 'pending':
      return `${base} bg-theme-info-bg text-theme-info-fg`;
    case 'draining':
      return `${base} bg-theme-warning-bg text-theme-warning-fg`;
    case 'removed':
      return `${base} bg-theme-background-secondary text-theme-secondary`;
    default:
      return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}
