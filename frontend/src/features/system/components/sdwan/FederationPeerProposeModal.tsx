import React, { useState } from 'react';
import { Users } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';
import { isPendingApproval } from '../../services/api/helpers';
import { pendingApprovalNotice } from '../../utils/pendingApproval';

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
      const result = await sdwanApi.proposeFederationPeer({
        remote_instance_url: remoteInstanceUrl.trim(),
        remote_instance_id: remoteInstanceId.trim() || undefined,
        remote_account_id: remoteAccountId.trim() || undefined,
        remote_prefix_advertisement: remotePrefix.trim() || undefined,
      });
      if (isPendingApproval(result)) {
        addNotification(pendingApprovalNotice(`proposing federation peer ${remoteInstanceUrl.trim()}`, result));
        reset();
        onClose();
        return;
      }
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
    <Modal isOpen={isOpen} onClose={() => !submitting && (reset(), onClose())} title="Propose federation peer" icon={<Users className="w-6 h-6" />}>
      <form onSubmit={handleSubmit} className="space-y-3">
        <div className="p-3 bg-theme-info-bg border border-theme-info-border rounded text-xs text-theme-info-fg">
          v1 stores the proposal as data only — cross-CA verification, prefix routing, and
          tunnel establishment arrive in a future federation slice. The governance scanner
          will flag prefix overlaps with this install's address space.
        </div>
        <div>
          {/* `required` marks the label; `nativeRequired` sets the attribute a
              spec in this file asserts. FormField splits the two. */}
          <FormField
            label="Remote instance URL"
            id="fp-remote-instance-url"
            type="url"
            required
            nativeRequired
            value={remoteInstanceUrl}
            onChange={setRemoteInstanceUrl}
            placeholder="https://other.powernode.example.org"
            className="font-mono text-sm"
            disabled={submitting}
          />
        </div>
        <div>
          <FormField
            label="Remote instance ID (UUID, optional)"
            id="fp-remote-instance-id"
            value={remoteInstanceId}
            onChange={setRemoteInstanceId}
            placeholder="019d…"
            className="font-mono text-sm"
            disabled={submitting}
          />
        </div>
        <div>
          <FormField
            label="Remote account ID (UUID, optional)"
            id="fp-remote-account-id"
            value={remoteAccountId}
            onChange={setRemoteAccountId}
            className="font-mono text-sm"
            disabled={submitting}
          />
        </div>
        <div>
          <FormField
            label="Remote prefix advertisement (optional)"
            id="fp-remote-prefix"
            value={remotePrefix}
            onChange={setRemotePrefix}
            placeholder="fdab:cdef:1234::/48"
            className="font-mono text-sm"
            disabled={submitting}
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
