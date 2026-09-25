import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Network,
  Plus,
  Trash2,
  RefreshCw,
  ShieldCheck,
  Eye,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useArmedConfirm } from '@/shared/hooks/useArmedConfirm';
import { platformPeersApi } from '../../services/api/platformPeersApi';
import { usePlatformPeers } from '../../hooks/usePlatformPeers';
import { PeerTable, PeerUrlCell, PeerStatusCell, PeerHeartbeatCell } from './PeerTable';
import type {
  PlatformPeerSummary,
  PeerStatus,
  SpawnMode,
  SpawnRole,
} from '../../types/peer.types';
import { InvitePeerModal } from './InvitePeerModal';
import { PeerDetailDrawer } from './PeerDetailDrawer';
import { GrantsManagementModal } from './GrantsManagementModal';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';

/**
 * PeerControlPanel — the single canonical peer-management surface (fc-35),
 * on ServiceDeliveryPage's Peers tab. Composes the existing InvitePeerModal
 * (propose/accept), GrantsManagementModal (grant lifecycle), and
 * PeerDetailDrawer. Each mutating action is gated on the SAME permission its
 * backend endpoint checks (review fix, fc-35): Invite on
 * `system.peers.invite` (Api::V1::System::Platform::PeersController#create),
 * Revoke and Grants on `system.peers.manage`
 * (…PeersController#revoke, …PeerGrantsController#create) — computed here via
 * usePermissions(), not passed down from a caller's own, differently-scoped
 * permission (ServiceDeliveryPage's prior `canManage` prop mapped to
 * `system.sdwan.federation.manage`, a federation-governance permission the
 * peer endpoints never check). REVOKE here is an arm-and-confirm action
 * (useArmedConfirm) instead of a `window.prompt`. Revoke is terminal, so a
 * two-stage in-place confirm matches the destructive-action convention
 * (feedback_destructive_confirm) without a blocking modal. The optional
 * revoke reason is taken from an inline field that appears only while the
 * row's revoke button is armed.
 *
 * fc-35: PeersPanel (formerly PlatformInfraTab's Peers sub-tab, ComputePage)
 * was deleted as a duplicate surface (05498995). It carried real capability
 * this panel did not yet have — Role / Mode / Endpoints columns and a status
 * filter bar (C13 diff-then-decide, component-status-plane campaign, had
 * deliberately kept both for exactly that divergence) — so per the
 * consolidation rule (feedback_ux_simplicity_discoverable_nav_first: the
 * canonical surface absorbs the capabilities of the surface it replaces),
 * that capability was ported here rather than left flagged. The filter is
 * local component state, not a URL param — neither this panel nor
 * ServiceDeliveryPage reads search params elsewhere. See PeerTable.tsx's
 * header comment for the shared-cell factoring (URL/status/heartbeat
 * rendering) that PeersPanel and this panel both used.
 *
 * Plan reference: Phase 3 (Federation & Multi-Site) — Control.
 */

interface PeerControlPanelProps {
  /** Bumped by the parent to force a manual refetch. */
  refreshKey?: number;
}

export const PeerControlPanel: React.FC<PeerControlPanelProps> = ({ refreshKey }) => {
  const { addNotification } = useNotifications();
  const { hasPermission } = usePermissions();
  const canInvite = hasPermission('system.peers.invite');
  const canManage = hasPermission('system.peers.manage');
  const [statusFilter, setStatusFilter] = useState<PeerStatus | null>(null);
  const { peers, loading, error, setError, refetch } = usePlatformPeers(
    statusFilter ? { status: statusFilter } : undefined,
  );
  const [inviteOpen, setInviteOpen] = useState(false);
  const [detailId, setDetailId] = useState<string | null>(null);
  const [grantsPeer, setGrantsPeer] = useState<PlatformPeerSummary | null>(null);
  const [revokingId, setRevokingId] = useState<string | null>(null);

  // Force a refetch only when the parent actually BUMPS refreshKey — not on
  // every render where `refetch`'s identity changes (e.g. a status-filter
  // click, which already triggers its own fetch via usePlatformPeers' own
  // mount/filter-change effect). Depending on `refetch` here duplicated that
  // fetch on mount and on every filter change (review fix, fc-35).
  const lastRefreshKey = useRef(refreshKey);
  useEffect(() => {
    if (refreshKey === lastRefreshKey.current) return;
    lastRefreshKey.current = refreshKey;
    void refetch();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- refetch is read from the closure, not tracked: this effect must fire on refreshKey changes ONLY (see comment above), not on refetch identity changes.
  }, [refreshKey]);

  const handleRevoke = useCallback(
    async (peer: PlatformPeerSummary, reason: string) => {
      setRevokingId(peer.id);
      try {
        await platformPeersApi.revoke(peer.id, reason.trim() || undefined);
        addNotification({ type: 'success', message: `Peer '${peer.remote_instance_url}' revoked.` });
        await refetch();
      } catch (err: unknown) {
        addNotification({
          type: 'error',
          message: err instanceof Error ? err.message : 'Failed to revoke peer',
        });
      } finally {
        setRevokingId(null);
      }
    },
    [addNotification, refetch],
  );

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden" data-testid="peer-control-panel">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Network className="w-5 h-5 text-theme-info-fg" />
          <h2 className="font-semibold text-theme-primary">Peers</h2>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${peers.length} ${peers.length === 1 ? 'peer' : 'peers'}`}
          </span>
        </div>
        <div className="flex items-center gap-2">
          <StatusFilterBar value={statusFilter} onChange={setStatusFilter} />
          <button
            type="button"
            onClick={() => void refetch()}
            disabled={loading}
            title="Refresh"
            className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
          </button>
          {canInvite && (
            <Button variant="primary" onClick={() => setInviteOpen(true)}>
              <Plus className="w-4 h-4" />
              Invite Peer
            </Button>
          )}
        </div>
      </header>

      {error && (
        <div className="px-4 pt-4">
          <ErrorAlert message={error} onClose={() => setError(null)} />
        </div>
      )}

      {!loading && peers.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm">
          No federation peers yet. {canInvite ? 'Click "Invite Peer" to propose one.' : ''}
        </div>
      )}

      {peers.length > 0 && (
        <PeerTable
          columns={[
            { label: 'Remote URL' },
            { label: 'Role' },
            { label: 'Mode' },
            { label: 'Status' },
            { label: 'Endpoints' },
            { label: 'Last Heartbeat' },
            { label: 'Actions', align: 'right' },
          ]}
        >
          {peers.map((peer) => (
            <ControlRow
              key={peer.id}
              peer={peer}
              canManage={canManage}
              isRevoking={revokingId === peer.id}
              onView={() => setDetailId(peer.id)}
              onGrants={() => setGrantsPeer(peer)}
              onRevoke={(reason) => void handleRevoke(peer, reason)}
            />
          ))}
        </PeerTable>
      )}

      <InvitePeerModal
        isOpen={inviteOpen}
        onClose={() => setInviteOpen(false)}
        onInvited={() => void refetch()}
      />

      <PeerDetailDrawer peerId={detailId} onClose={() => setDetailId(null)} />

      <GrantsManagementModal
        isOpen={grantsPeer !== null}
        peerId={grantsPeer?.id ?? null}
        peerLabel={grantsPeer?.remote_instance_url ?? ''}
        onClose={() => setGrantsPeer(null)}
        onChanged={() => void refetch()}
      />
    </div>
  );
};

interface ControlRowProps {
  peer: PlatformPeerSummary;
  canManage: boolean;
  isRevoking: boolean;
  onView: () => void;
  onGrants: () => void;
  onRevoke: (reason: string) => void;
}

const ControlRow: React.FC<ControlRowProps> = ({
  peer,
  canManage,
  isRevoking,
  onView,
  onGrants,
  onRevoke,
}) => {
  const [reason, setReason] = useState('');
  const isTerminal = peer.status === 'revoked';

  const { armed, trigger, reset } = useArmedConfirm(() => onRevoke(reason), {
    onTimeout: () => setReason(''),
  });

  return (
    <tr className="border-t border-theme hover:bg-theme-surface-hover transition-colors" data-testid={`control-row-${peer.id}`}>
      <PeerUrlCell peer={peer} />
      <td className="px-4 py-3 text-theme-secondary text-xs">
        {peer.spawn_role ? <RoleBadge role={peer.spawn_role} /> : <span className="text-theme-tertiary">—</span>}
      </td>
      <td className="px-4 py-3 text-theme-secondary text-xs">
        {peer.spawn_mode ? <ModeBadge mode={peer.spawn_mode} /> : <span className="text-theme-tertiary">—</span>}
      </td>
      <PeerStatusCell peer={peer} />
      <td className="px-4 py-3 text-xs text-theme-secondary">
        {peer.endpoints_count}
      </td>
      <PeerHeartbeatCell peer={peer} />
      <td className="px-4 py-3">
        <div className="flex items-center justify-end gap-2">
          <button
            type="button"
            onClick={onView}
            title="View detail"
            className="px-2 py-1 rounded text-xs text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover inline-flex items-center gap-1 transition-colors"
          >
            <Eye className="w-3 h-3" />
            Detail
          </button>
          {canManage && (
            <button
              type="button"
              onClick={onGrants}
              title="Manage grants"
              className="px-2 py-1 rounded text-xs text-theme-info-fg hover:bg-theme-surface-hover inline-flex items-center gap-1 transition-colors"
            >
              <ShieldCheck className="w-3 h-3" />
              Grants
            </button>
          )}
          {canManage && !isTerminal && (
            <div className="inline-flex items-center gap-1">
              {armed && (
                <input
                  type="text"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="reason (optional)"
                  disabled={isRevoking}
                  className="w-36 px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary text-xs disabled:opacity-50"
                  autoFocus
                />
              )}
              <button
                type="button"
                onClick={trigger}
                onBlur={armed ? undefined : reset}
                disabled={isRevoking}
                title={armed ? 'Click again to confirm revoke' : 'Revoke peer'}
                className={`px-2 py-1 rounded text-xs inline-flex items-center gap-1 transition-colors disabled:opacity-40 ${
                  armed
                    ? 'bg-theme-danger-solid text-white font-medium'
                    : 'text-theme-danger-fg hover:bg-theme-surface-hover'
                }`}
                data-testid={`revoke-${peer.id}`}
              >
                <Trash2 className="w-3 h-3" />
                {isRevoking ? 'Revoking…' : armed ? 'Confirm revoke' : 'Revoke'}
              </button>
            </div>
          )}
        </div>
      </td>
    </tr>
  );
};

const ROLE_LABELS: Record<SpawnRole, string> = {
  parent: 'parent',
  child: 'child',
  symmetric: 'symmetric',
};

const RoleBadge: React.FC<{ role: SpawnRole }> = ({ role }) => (
  <span className="px-1.5 py-0.5 bg-theme-background-secondary rounded text-xs font-mono">
    {ROLE_LABELS[role]}
  </span>
);

const MODE_LABELS: Record<SpawnMode, string> = {
  managed_child: 'managed',
  autonomous_peer: 'autonomous',
  cluster_member: 'cluster',
  out_of_band: 'out-of-band',
};

const ModeBadge: React.FC<{ mode: SpawnMode }> = ({ mode }) => (
  <span className="px-1.5 py-0.5 bg-theme-background-secondary rounded text-xs font-mono">
    {MODE_LABELS[mode]}
  </span>
);

const STATUS_FILTERS: Array<{ value: PeerStatus | null; label: string }> = [
  { value: null, label: 'All' },
  { value: 'proposed', label: 'Proposed' },
  { value: 'accepted', label: 'Accepted' },
  { value: 'enrolled', label: 'Enrolled' },
  { value: 'active', label: 'Active' },
  { value: 'degraded', label: 'Degraded' },
  { value: 'suspended', label: 'Suspended' },
  { value: 'revoked', label: 'Revoked' },
];

const StatusFilterBar: React.FC<{
  value: PeerStatus | null;
  onChange: (v: PeerStatus | null) => void;
}> = ({ value, onChange }) => (
  <div className="inline-flex items-center gap-1 text-xs">
    {STATUS_FILTERS.map((f) => (
      <button
        type="button"
        key={f.label}
        onClick={() => onChange(f.value)}
        className={`px-2 py-1 rounded transition-colors ${
          value === f.value
            ? 'bg-theme-info-solid text-white'
            : 'text-theme-secondary hover:bg-theme-surface-hover'
        }`}
      >
        {f.label}
      </button>
    ))}
  </div>
);

export default PeerControlPanel;
