import React, { useState } from 'react';
import {
  Network,
  AlertTriangle,
  X,
  Plus,
  Trash2,
  RefreshCw,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
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

/**
 * Operator-side panel: list this platform's symmetric and child-side
 * federation peers (children-side peers live in the Children tab).
 *
 * Plan reference: Decentralized Federation §I + P7.1.
 */
export const PeersPanel: React.FC = () => {
  const { addNotification } = useNotifications();
  const [statusFilter, setStatusFilter] = useState<PeerStatus | null>(null);
  const { peers, loading, error, setError, refetch } = usePlatformPeers(
    statusFilter ? { status: statusFilter } : undefined,
  );
  const [inviteOpen, setInviteOpen] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [revokingId, setRevokingId] = useState<string | null>(null);

  const handleRevoke = async (peer: PlatformPeerSummary) => {
    const reason = window.prompt(
      `Revoke federation peer "${peer.remote_instance_url}"?\n\n` +
        'This is terminal: subsequent federation_api calls from the peer fail. ' +
        'Optional reason:',
      '',
    );
    if (reason === null) return;
    setRevokingId(peer.id);
    try {
      await platformPeersApi.revoke(peer.id, reason || undefined);
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
  };

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
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
          <Button variant="primary" onClick={() => setInviteOpen(true)}>
            <Plus className="w-4 h-4" />
            Invite Peer
          </Button>
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
          No federation peers yet. Click "Invite Peer" to propose one.
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
            <PeerRow
              key={peer.id}
              peer={peer}
              onSelect={() => setSelectedId(peer.id)}
              onRevoke={() => handleRevoke(peer)}
              isRevoking={revokingId === peer.id}
            />
          ))}
        </PeerTable>
      )}

      <InvitePeerModal
        isOpen={inviteOpen}
        onClose={() => setInviteOpen(false)}
        onInvited={() => void refetch()}
      />

      <PeerDetailDrawer
        peerId={selectedId}
        onClose={() => setSelectedId(null)}
      />
    </div>
  );
};

interface PeerRowProps {
  peer: PlatformPeerSummary;
  onSelect: () => void;
  onRevoke: () => void;
  isRevoking: boolean;
}

const PeerRow: React.FC<PeerRowProps> = ({ peer, onSelect, onRevoke, isRevoking }) => {
  const isTerminal = peer.status === 'revoked';

  return (
    <tr
      className="border-t border-theme cursor-pointer hover:bg-theme-surface-hover transition-colors"
      onClick={onSelect}
    >
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
      <td className="px-4 py-3 text-right" onClick={(e) => e.stopPropagation()}>
        {!isTerminal && (
          <button
            type="button"
            onClick={onRevoke}
            disabled={isRevoking}
            title="Revoke peer"
            className="px-2 py-1 rounded text-xs text-theme-danger-fg hover:bg-theme-surface-hover disabled:opacity-40 inline-flex items-center gap-1 transition-colors"
          >
            <Trash2 className="w-3 h-3" />
            {isRevoking ? 'Revoking…' : 'Revoke'}
          </button>
        )}
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
