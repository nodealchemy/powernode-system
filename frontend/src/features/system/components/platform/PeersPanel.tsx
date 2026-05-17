import React, { useCallback, useEffect, useState } from 'react';
import {
  Network,
  AlertTriangle,
  X,
  Plus,
  Clock,
  Trash2,
  RefreshCw,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { platformPeersApi } from '../../services/api/platformPeersApi';
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
  const [peers, setPeers] = useState<PlatformPeerSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<PeerStatus | null>(null);
  const [inviteOpen, setInviteOpen] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [revokingId, setRevokingId] = useState<string | null>(null);

  const fetchPeers = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await platformPeersApi.listPeers(
        statusFilter ? { status: statusFilter } : undefined,
      );
      setPeers(result.peers);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load peers');
    } finally {
      setLoading(false);
    }
  }, [statusFilter]);

  useEffect(() => {
    void fetchPeers();
  }, [fetchPeers]);

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
      await fetchPeers();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to revoke peer');
    } finally {
      setRevokingId(null);
    }
  };

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Network className="w-5 h-5 text-theme-info" />
          <h2 className="font-semibold text-theme-primary">Peers</h2>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${peers.length} ${peers.length === 1 ? 'peer' : 'peers'}`}
          </span>
        </div>
        <div className="flex items-center gap-2">
          <StatusFilterBar value={statusFilter} onChange={setStatusFilter} />
          <button
            type="button"
            onClick={() => void fetchPeers()}
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
        <div className="p-3 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm">
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
        <table className="w-full text-sm">
          <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
            <tr>
              <th className="text-left px-4 py-2 font-medium">Remote URL</th>
              <th className="text-left px-4 py-2 font-medium">Role</th>
              <th className="text-left px-4 py-2 font-medium">Mode</th>
              <th className="text-left px-4 py-2 font-medium">Status</th>
              <th className="text-left px-4 py-2 font-medium">Endpoints</th>
              <th className="text-left px-4 py-2 font-medium">Last Heartbeat</th>
              <th className="text-right px-4 py-2 font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {peers.map((peer) => (
              <PeerRow
                key={peer.id}
                peer={peer}
                onSelect={() => setSelectedId(peer.id)}
                onRevoke={() => handleRevoke(peer)}
                isRevoking={revokingId === peer.id}
              />
            ))}
          </tbody>
        </table>
      )}

      <InvitePeerModal
        isOpen={inviteOpen}
        onClose={() => setInviteOpen(false)}
        onInvited={() => void fetchPeers()}
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
      <td className="px-4 py-3 text-theme-primary font-mono text-xs">{peer.remote_instance_url}</td>
      <td className="px-4 py-3 text-theme-secondary text-xs">
        {peer.spawn_role ? <RoleBadge role={peer.spawn_role} /> : <span className="text-theme-tertiary">—</span>}
      </td>
      <td className="px-4 py-3 text-theme-secondary text-xs">
        {peer.spawn_mode ? <ModeBadge mode={peer.spawn_mode} /> : <span className="text-theme-tertiary">—</span>}
      </td>
      <td className="px-4 py-3">
        <StatusPill status={peer.status} />
      </td>
      <td className="px-4 py-3 text-xs text-theme-secondary">
        {peer.endpoints_count}
      </td>
      <td className="px-4 py-3 text-xs text-theme-secondary">
        {peer.last_heartbeat_at ? (
          <span className="inline-flex items-center gap-1">
            <Clock className="w-3 h-3" />
            {new Date(peer.last_heartbeat_at).toLocaleString()}
          </span>
        ) : (
          <span className="text-theme-tertiary">never</span>
        )}
      </td>
      <td className="px-4 py-3 text-right" onClick={(e) => e.stopPropagation()}>
        {!isTerminal && (
          <button
            type="button"
            onClick={onRevoke}
            disabled={isRevoking}
            title="Revoke peer"
            className="px-2 py-1 rounded text-xs text-theme-danger hover:bg-theme-surface-hover disabled:opacity-40 inline-flex items-center gap-1 transition-colors"
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

const StatusPill: React.FC<{ status: PeerStatus }> = ({ status }) => {
  const styleByStatus: Record<PeerStatus, string> = {
    proposed: 'bg-theme-background-tertiary text-theme-secondary',
    accepted: 'bg-theme-info text-theme-info',
    enrolled: 'bg-theme-info text-theme-info',
    active: 'bg-theme-success text-theme-success',
    degraded: 'bg-theme-warning text-theme-warning',
    suspended: 'bg-theme-warning text-theme-warning',
    revoked: 'bg-theme-danger text-theme-danger',
  };
  return (
    <span className={`inline-block px-2 py-0.5 rounded text-xs font-medium ${styleByStatus[status]}`}>
      {status}
    </span>
  );
};
