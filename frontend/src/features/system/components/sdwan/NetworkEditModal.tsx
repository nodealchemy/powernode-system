import React, { useEffect, useState } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';
import type { SdwanNetwork } from '../../types/sdwan.types';

interface NetworkEditModalProps {
  isOpen: boolean;
  network: SdwanNetwork | null;
  onClose: () => void;
  onSaved: () => void;
}

/**
 * NetworkEditModal — operator-side update for a network's name,
 * description, status, and default firewall policy. The /64 CIDR is
 * immutable post-creation (FirewallCompiler interface name + every peer's
 * /128 derivation depend on it), so it's not editable here.
 */
export const NetworkEditModal: React.FC<NetworkEditModalProps> = ({ isOpen, network, onClose, onSaved }) => {
  const { addNotification } = useNotifications();
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [status, setStatus] = useState<string>('registered');
  const [defaultPolicy, setDefaultPolicy] = useState<'accept' | 'drop'>('accept');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!network) return;
    setName(network.name);
    setDescription(network.description ?? '');
    setStatus(network.status);
    setDefaultPolicy(
      (network.settings?.firewall_default_policy as 'accept' | 'drop') ?? 'accept'
    );
  }, [network]);

  if (!network) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (submitting) return;
    setSubmitting(true);
    try {
      const settings = { ...(network.settings ?? {}), firewall_default_policy: defaultPolicy };
      await sdwanApi.updateNetwork(network.id, {
        name: name.trim(),
        description: description.trim() || undefined,
        status,
        settings,
      });
      addNotification({ type: 'success', message: `Network "${name}" updated` });
      onSaved();
      onClose();
    } catch (err) {
      addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Update failed' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={() => !submitting && onClose()} title={`Edit ${network.name}`}>
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Name</label>
          <input
            type="text" value={name} onChange={(e) => setName(e.target.value)}
            className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
            disabled={submitting}
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Description</label>
          <textarea
            value={description} onChange={(e) => setDescription(e.target.value)}
            className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
            rows={2} disabled={submitting}
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Status</label>
          <select
            value={status} onChange={(e) => setStatus(e.target.value)}
            className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
            disabled={submitting}
          >
            <option value="registered">registered</option>
            <option value="active">active</option>
            <option value="suspended">suspended</option>
            <option value="archived">archived</option>
          </select>
          <p className="text-xs text-theme-secondary mt-1">
            Suspended networks compile a default-deny ruleset; archived stops compilation entirely.
          </p>
        </div>
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Default firewall policy</label>
          <div className="flex gap-3">
            <label className="flex items-center gap-2 cursor-pointer">
              <input type="radio" name="edit-fw-policy" value="accept"
                     checked={defaultPolicy === 'accept'} onChange={() => setDefaultPolicy('accept')}
                     disabled={submitting} />
              <span className="text-sm text-theme-primary">Accept all</span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input type="radio" name="edit-fw-policy" value="drop"
                     checked={defaultPolicy === 'drop'} onChange={() => setDefaultPolicy('drop')}
                     disabled={submitting} />
              <span className="text-sm text-theme-primary">Drop all (allowlist)</span>
            </label>
          </div>
        </div>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={onClose} disabled={submitting}>Cancel</Button>
          <Button variant="primary" type="submit" disabled={submitting || !name.trim()}>
            {submitting ? 'Saving…' : 'Save changes'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
