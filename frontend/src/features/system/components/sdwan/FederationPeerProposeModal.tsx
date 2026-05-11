import React, { useState } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';

interface FederationPeerProposeModalProps {
  isOpen: boolean;
  onClose: () => void;
  onProposed: () => void;
}

/**
 * FederationPeerProposeModal — creates a `proposed`-status federation
 * peer. v1 only stores the operator's attestation (URL, prefix); future
 * federation slices will activate cross-CA verification.
 */
export const FederationPeerProposeModal: React.FC<FederationPeerProposeModalProps> = ({
  isOpen, onClose, onProposed,
}) => {
  const { addNotification } = useNotifications();
  const [remoteInstanceUrl, setRemoteInstanceUrl] = useState('');
  const [remoteInstanceId, setRemoteInstanceId] = useState('');
  const [remoteAccountId, setRemoteAccountId] = useState('');
  const [remotePrefix, setRemotePrefix] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const reset = () => {
    setRemoteInstanceUrl(''); setRemoteInstanceId(''); setRemoteAccountId('');
    setRemotePrefix(''); setSubmitting(false);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!remoteInstanceUrl.trim()) {
      addNotification({ type: 'error', message: 'Remote instance URL is required' });
      return;
    }
    setSubmitting(true);
    try {
      await sdwanApi.proposeFederationPeer({
        remote_instance_url: remoteInstanceUrl.trim(),
        remote_instance_id: remoteInstanceId.trim() || undefined,
        remote_account_id: remoteAccountId.trim() || undefined,
        remote_prefix_advertisement: remotePrefix.trim() || undefined,
      });
      addNotification({ type: 'success', message: 'Federation peer proposed' });
      onProposed();
      reset();
      onClose();
    } catch (err) {
      addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Failed' });
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={() => !submitting && (reset(), onClose())} title="Propose federation peer">
      <form onSubmit={handleSubmit} className="space-y-3">
        <div className="p-3 bg-theme-info border border-theme-info rounded text-xs text-theme-info">
          v1 stores the proposal as data only — cross-CA verification, prefix routing, and
          tunnel establishment arrive in a future federation slice. The governance scanner
          will flag prefix overlaps with this install's address space.
        </div>
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Remote instance URL *</label>
          <input
            type="url" value={remoteInstanceUrl} onChange={(e) => setRemoteInstanceUrl(e.target.value)}
            placeholder="https://other.powernode.example.org" required
            disabled={submitting}
            className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary font-mono text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Remote instance ID (UUID, optional)</label>
          <input
            type="text" value={remoteInstanceId} onChange={(e) => setRemoteInstanceId(e.target.value)}
            placeholder="019d…" disabled={submitting}
            className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary font-mono text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Remote account ID (UUID, optional)</label>
          <input
            type="text" value={remoteAccountId} onChange={(e) => setRemoteAccountId(e.target.value)}
            disabled={submitting}
            className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary font-mono text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Remote prefix advertisement (optional)</label>
          <input
            type="text" value={remotePrefix} onChange={(e) => setRemotePrefix(e.target.value)}
            placeholder="fdab:cdef:1234::/48" disabled={submitting}
            className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary font-mono text-sm"
          />
          <p className="text-xs text-theme-secondary mt-1">/48, /56, or /64 ULA prefix the remote claims to own.</p>
        </div>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={() => { reset(); onClose(); }} disabled={submitting}>Cancel</Button>
          <Button variant="primary" type="submit" disabled={submitting || !remoteInstanceUrl.trim()}>
            {submitting ? 'Proposing…' : 'Propose'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
