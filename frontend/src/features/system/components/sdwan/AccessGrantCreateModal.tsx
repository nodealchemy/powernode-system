import React, { useState } from 'react';
import { ShieldCheck } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';
import { isPendingApproval } from '../../services/api/helpers';
import { pendingApprovalNotice } from '../../utils/pendingApproval';

interface AccessGrantCreateModalProps {
  isOpen: boolean;
  networkId: string;
  onClose: () => void;
  onCreated: () => void;
}

/**
 * AccessGrantCreateModal — grants a user permission to attach VPN
 * clients to this network. Slice 4.5 ships with a UUID input rather
 * than a user picker; a real picker requires a usersApi which lives
 * outside the System extension and would couple the slice.
 */
export const AccessGrantCreateModal: React.FC<AccessGrantCreateModalProps> = ({
  isOpen, networkId, onClose, onCreated,
}) => {
  const { addNotification } = useNotifications();
  const [userId, setUserId] = useState('');
  const [tagsInput, setTagsInput] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const reset = () => { setUserId(''); setTagsInput(''); setSubmitting(false); };
  const handleClose = () => { if (!submitting) { reset(); onClose(); } };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!userId.trim()) {
      addNotification({ type: 'error', message: 'User ID is required' });
      return;
    }
    setSubmitting(true);
    try {
      const tags = tagsInput.split(',').map((t) => t.trim()).filter(Boolean);
      const result = await sdwanApi.createAccessGrant(networkId, { user_id: userId.trim(), tags });
      if (isPendingApproval(result)) {
        addNotification(pendingApprovalNotice('creating the access grant', result));
        reset();
        onClose();
        return;
      }
      addNotification({ type: 'success', message: 'Access grant created' });
      onCreated();
      reset();
      onClose();
    } catch (err) {
      addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Failed' });
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={handleClose} icon={<ShieldCheck className="w-6 h-6" />} title="Grant network access to user">
      <form onSubmit={handleSubmit} className="space-y-3">
        <div>
          <FormField
            label="User ID (UUID)"
            value={userId}
            onChange={setUserId}
            placeholder="019d…"
            className="font-mono text-sm"
            autoFocus
            disabled={submitting}
            helpText="Find user IDs in the Users panel or via the platform Users API."
          />
        </div>
        <div>
          <FormField
            label="Tags (comma-separated, optional)"
            value={tagsInput}
            onChange={setTagsInput}
            placeholder="vpn-pilot, contractor"
            disabled={submitting}
          />
        </div>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={handleClose} disabled={submitting}>Cancel</Button>
          <Button variant="primary" type="submit" disabled={submitting || !userId.trim()}>
            {submitting ? 'Granting…' : 'Grant access'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
