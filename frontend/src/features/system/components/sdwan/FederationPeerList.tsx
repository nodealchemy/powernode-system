import React, { useEffect, useState, useCallback } from 'react';
import { Globe2, Trash2, Ban } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Modal } from '@/shared/components/ui/Modal';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { sdwanApi } from '../../services/api/sdwanApi';
import type {
  SdwanFederationPeer,
  SdwanFederationStatus,
} from '../../types/sdwan.types';

interface FederationPeerListProps {
  refreshKey?: number;
}

export const FederationPeerList: React.FC<FederationPeerListProps> = ({ refreshKey }) => {
  const { addNotification } = useNotifications();
  const { hasPermission } = usePermissions();
  const canManage = hasPermission('sdwan.federation.manage');

  const [peers, setPeers] = useState<SdwanFederationPeer[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [revokeConfirm, setRevokeConfirm] = useState<SdwanFederationPeer | null>(null);
  const [deleteConfirm, setDeleteConfirm] = useState<SdwanFederationPeer | null>(null);

  const [localKey, setLocalKey] = useState(0);
  const triggerLocal = useCallback(() => setLocalKey((k) => k + 1), []);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const { peers: list } = await sdwanApi.getFederationPeers();
      setPeers(list);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load federation peers');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load, refreshKey, localKey]);

  if (loading) return <div className="p-4 text-theme-secondary">Loading federation peers…</div>;
  if (error) return <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>;

  if (peers.length === 0) {
    return (
      <div className="p-12 text-center">
        <Globe2 className="mx-auto mb-4 text-theme-secondary" size={48} />
        <h3 className="text-lg font-medium text-theme-primary mb-1">No federation peers</h3>
        <p className="text-sm text-theme-secondary">
          Propose a federation peer to register a cross-Powernode-instance overlay intent.
        </p>
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full">
        <thead className="bg-theme-background-secondary text-theme-secondary text-sm">
          <tr>
            <th className="text-left p-3">Remote instance</th>
            <th className="text-left p-3">Prefix</th>
            <th className="text-left p-3">Status</th>
            <th className="text-left p-3">Signed / expires</th>
            <th className="text-right p-3">Actions</th>
          </tr>
        </thead>
        <tbody>
          {peers.map((p) => (
            <tr key={p.id} className="border-b border-theme">
              <td className="p-3">
                <div className="font-mono text-xs text-theme-primary">{p.remote_instance_url}</div>
                {p.remote_instance_id && (
                  <div className="text-xs text-theme-secondary font-mono">
                    id: {p.remote_instance_id.slice(0, 8)}…
                  </div>
                )}
              </td>
              <td className="p-3 font-mono text-xs text-theme-secondary">
                {p.remote_prefix_advertisement ?? '—'}
              </td>
              <td className="p-3">
                <span className={statusClass(p.status)}>{p.status}</span>
              </td>
              <td className="p-3 text-xs text-theme-secondary">
                <div>signed: {p.signed_at ? new Date(p.signed_at).toLocaleDateString() : '—'}</div>
                <div>expires: {p.expires_at ? new Date(p.expires_at).toLocaleDateString() : '—'}</div>
              </td>
              <td className="p-3 text-right">
                {canManage && p.status !== 'revoked' && (
                  <button type="button" onClick={() => setRevokeConfirm(p)}
                          className="text-theme-warning hover:bg-theme-warning p-1 rounded mr-1"
                          aria-label={`Revoke peer ${p.remote_instance_url}`}>
                    <Ban size={16} />
                  </button>
                )}
                {canManage && (
                  <button type="button" onClick={() => setDeleteConfirm(p)}
                          className="text-theme-danger hover:bg-theme-danger p-1 rounded"
                          aria-label={`Delete peer ${p.remote_instance_url}`}>
                    <Trash2 size={16} />
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <Modal isOpen={revokeConfirm !== null} onClose={() => setRevokeConfirm(null)} title="Revoke federation peer">
        {revokeConfirm && (
          <div className="space-y-3">
            <p className="text-theme-primary">
              Revoke federation peer <strong className="font-mono text-sm">{revokeConfirm.remote_instance_url}</strong>?
            </p>
            <p className="text-sm text-theme-secondary">
              The row stays for audit but transitions to <code>revoked</code> (terminal in v1).
              Re-proposing the same remote instance creates a fresh row.
            </p>
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setRevokeConfirm(null)}>Cancel</Button>
              <Button variant="danger" onClick={async () => {
                try {
                  await sdwanApi.revokeFederationPeer(revokeConfirm.id);
                  addNotification({ type: 'success', message: 'Peer revoked' });
                  setRevokeConfirm(null);
                  triggerLocal();
                } catch (err) {
                  addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Failed' });
                }
              }}>Revoke</Button>
            </div>
          </div>
        )}
      </Modal>

      <Modal isOpen={deleteConfirm !== null} onClose={() => setDeleteConfirm(null)} title="Delete federation peer">
        {deleteConfirm && (
          <div className="space-y-3">
            <p className="text-theme-primary">
              Permanently delete <strong className="font-mono text-sm">{deleteConfirm.remote_instance_url}</strong>?
            </p>
            <p className="text-sm text-theme-secondary">
              Hard-deletes the row + its Vault trust JWT. Use Revoke instead to keep audit history.
            </p>
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setDeleteConfirm(null)}>Cancel</Button>
              <Button variant="danger" onClick={async () => {
                try {
                  await sdwanApi.deleteFederationPeer(deleteConfirm.id);
                  addNotification({ type: 'success', message: 'Peer deleted' });
                  setDeleteConfirm(null);
                  triggerLocal();
                } catch (err) {
                  addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Failed' });
                }
              }}>Delete</Button>
            </div>
          </div>
        )}
      </Modal>
    </div>
  );
};

function statusClass(s: SdwanFederationStatus): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  switch (s) {
    case 'proposed':  return `${base} bg-theme-info text-theme-info`;
    case 'accepted':  return `${base} bg-theme-success text-theme-success`;
    case 'active':    return `${base} bg-theme-success text-theme-success`;
    case 'suspended': return `${base} bg-theme-warning text-theme-warning`;
    case 'revoked':   return `${base} bg-theme-danger text-theme-danger`;
    default:          return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}
