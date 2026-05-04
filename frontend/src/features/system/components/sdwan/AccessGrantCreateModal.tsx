import React, { useState } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';

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
      await sdwanApi.createAccessGrant(networkId, { user_id: userId.trim(), tags });
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
    <Modal isOpen={isOpen} onClose={handleClose} title="Grant network access to user">
      <form onSubmit={handleSubmit} className="space-y-3">
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">User ID (UUID)</label>
          <input
            type="text" value={userId} onChange={(e) => setUserId(e.target.value)}
            placeholder="019d…" autoFocus disabled={submitting}
            className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary font-mono text-sm"
          />
          <p className="text-xs text-theme-secondary mt-1">
            Find user IDs in the Users panel or via the platform Users API.
          </p>
        </div>
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Tags (comma-separated, optional)</label>
          <input
            type="text" value={tagsInput} onChange={(e) => setTagsInput(e.target.value)}
            placeholder="vpn-pilot, contractor" disabled={submitting}
            className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
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
