import React, { useState } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';
import type { SdwanIssueUserDeviceResponse } from '../../types/sdwan.types';

interface UserDeviceIssueModalProps {
  isOpen: boolean;
  networkId: string;
  grantId: string;
  onClose: () => void;
  onIssued: (result: SdwanIssueUserDeviceResponse) => void;
}

/**
 * UserDeviceIssueModal — collects a label, calls the server to generate
 * the keypair, then hands the result (which includes the bootstrap URL)
 * to the parent's onIssued so it can show the BootstrapUrlModal.
 */
export const UserDeviceIssueModal: React.FC<UserDeviceIssueModalProps> = ({
  isOpen, networkId, grantId, onClose, onIssued,
}) => {
  const { addNotification } = useNotifications();
  const [label, setLabel] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const handleClose = () => { if (!submitting) { setLabel(''); onClose(); } };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!label.trim()) return;
    setSubmitting(true);
    try {
      const result = await sdwanApi.issueUserDevice(networkId, grantId, { label: label.trim() });
      addNotification({ type: 'success', message: `Device "${label}" issued` });
      onIssued(result);
      setLabel('');
      onClose();
    } catch (err) {
      addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Issue failed' });
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Issue VPN device">
      <form onSubmit={handleSubmit} className="space-y-3">
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Device label</label>
          <input
            type="text" value={label} onChange={(e) => setLabel(e.target.value)}
            placeholder="e.g. macbook, phone, work-laptop"
            autoFocus disabled={submitting}
            className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
          />
          <p className="text-xs text-theme-secondary mt-1">
            The keypair is generated server-side; the private key is stored in Vault. You'll get a
            single-use URL on the next screen — copy and send it to the user immediately.
          </p>
        </div>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={handleClose} disabled={submitting}>Cancel</Button>
          <Button variant="primary" type="submit" disabled={submitting || !label.trim()}>
            {submitting ? 'Generating keypair…' : 'Issue'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
