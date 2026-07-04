import React, { useCallback, useEffect, useState } from 'react';
import {
  Network,
  AlertTriangle,
  X,
  Plus,
  Trash2,
  RefreshCw,
  ShieldCheck,
  Eye,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useArmedConfirm } from '@/shared/hooks/useArmedConfirm';
import { platformPeersApi } from '../../services/api/platformPeersApi';
import { usePlatformPeers } from '../../hooks/usePlatformPeers';
import { PeerTable, PeerUrlCell, PeerStatusCell, PeerHeartbeatCell } from './PeerTable';
import type { PlatformPeerSummary } from '../../types/peer.types';
import { InvitePeerModal } from './InvitePeerModal';
import { PeerDetailDrawer } from './PeerDetailDrawer';
import { GrantsManagementModal } from './GrantsManagementModal';

/**
 * PeerControlPanel — the mutate-side peer surface for the Federation Hub's
 * Control tab. Composes the existing InvitePeerModal (propose/accept),
 * GrantsManagementModal (grant lifecycle), and PeerDetailDrawer.
 *
 * Differs from the legacy PeersPanel in exactly one way the Phase 3 contract
 * calls for: REVOKE is an arm-and-confirm action (useArmedConfirm) instead of
 * a `window.prompt`. Revoke is terminal, so a two-stage in-place confirm
 * matches the destructive-action convention (feedback_destructive_confirm)
 * without a blocking modal. The optional revoke reason is taken from an inline
 * field that appears only while the row's revoke button is armed.
 *
 * Plan reference: Phase 3 (Federation & Multi-Site) — Control.
 */

interface PeerControlPanelProps {
  /** Bumped by the parent to force a manual refetch. */
  refreshKey?: number;
  /** Whether the operator can mutate peers (propose / revoke / grant). */
  canManage: boolean;
}

export const PeerControlPanel: React.FC<PeerControlPanelProps> = ({ refreshKey, canManage }) => {
  const { addNotification } = useNotifications();
  const { peers, loading, error, setError, refetch } = usePlatformPeers();
  const [inviteOpen, setInviteOpen] = useState(false);
  const [detailId, setDetailId] = useState<string | null>(null);
  const [grantsPeer, setGrantsPeer] = useState<PlatformPeerSummary | null>(null);
  const [revokingId, setRevokingId] = useState<string | null>(null);

  // Force a refetch when the parent bumps refreshKey.
  useEffect(() => {
    void refetch();
  }, [refetch, refreshKey]);

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
          <button
            type="button"
            onClick={() => void refetch()}
            disabled={loading}
            title="Refresh"
            className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
          </button>
          {canManage && (
            <Button variant="primary" onClick={() => setInviteOpen(true)}>
              <Plus className="w-4 h-4" />
              Invite Peer
            </Button>
          )}
        </div>
      </header>

      {error && (
        <div className="p-3 bg-theme-danger-bg text-theme-danger-fg flex items-center gap-2 text-sm">
          <AlertTriangle className="w-4 h-4 flex-shrink-0" />
          <span className="flex-1">{error}</span>
          <button type="button" onClick={() => setError(null)} className="p-1">
            <X className="w-3 h-3" />
          </button>
        </div>
      )}

      {!loading && peers.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm">
          No federation peers yet. {canManage ? 'Click "Invite Peer" to propose one.' : ''}
        </div>
      )}

      {peers.length > 0 && (
        <PeerTable
          columns={[
            { label: 'Remote URL' },
            { label: 'Status' },
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
      <PeerStatusCell peer={peer} />
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

export default PeerControlPanel;
