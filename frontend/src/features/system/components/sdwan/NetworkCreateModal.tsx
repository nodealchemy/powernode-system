import React, { useState } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';

interface NetworkCreateModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCreated: () => void;
}

/**
 * NetworkCreateModal — the simplest path to a working SDWAN network.
 * The /64 CIDR auto-allocates server-side via Sdwan::PrefixAllocator;
 * operators don't pick addresses. The default firewall policy can be
 * flipped at create time, since changing it later requires updating
 * existing peers' agent configs (which happens on the next heartbeat).
 */
export const NetworkCreateModal: React.FC<NetworkCreateModalProps> = ({ isOpen, onClose, onCreated }) => {
  const { addNotification } = useNotifications();
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [defaultPolicy, setDefaultPolicy] = useState<'accept' | 'drop'>('accept');
  const [submitting, setSubmitting] = useState(false);

  const reset = () => {
    setName('');
    setDescription('');
    setDefaultPolicy('accept');
    setSubmitting(false);
  };

  const handleClose = () => {
    if (submitting) return;
    reset();
    onClose();
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (submitting) return;
    if (!name.trim()) {
      addNotification({ type: 'error', message: 'Name is required' });
      return;
    }
    setSubmitting(true);
    try {
      await sdwanApi.createNetwork({
        name: name.trim(),
        description: description.trim() || undefined,
        settings: defaultPolicy === 'drop' ? { firewall_default_policy: 'drop' } : undefined,
      });
      addNotification({ type: 'success', message: `Network "${name}" created` });
      onCreated();
      reset();
      onClose();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to create network';
      addNotification({ type: 'error', message: msg });
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Create SDWAN network">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Name</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
            placeholder="e.g. edge-overlay"
            autoFocus
            disabled={submitting}
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Description (optional)</label>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
            rows={2}
            placeholder="What is this network for?"
            disabled={submitting}
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Default firewall policy</label>
          <div className="flex gap-3">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="firewall-policy"
                value="accept"
                checked={defaultPolicy === 'accept'}
                onChange={() => setDefaultPolicy('accept')}
                disabled={submitting}
              />
              <span className="text-sm text-theme-primary">Allow all by default</span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="firewall-policy"
                value="drop"
                checked={defaultPolicy === 'drop'}
                onChange={() => setDefaultPolicy('drop')}
                disabled={submitting}
              />
              <span className="text-sm text-theme-primary">Drop all by default (allowlist)</span>
            </label>
          </div>
          <p className="text-xs text-theme-secondary mt-1">
            The /64 CIDR is auto-allocated. Add firewall rules from the network detail page.
          </p>
        </div>

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={handleClose} disabled={submitting}>
            Cancel
          </Button>
          <Button variant="primary" type="submit" disabled={submitting || !name.trim()}>
            {submitting ? 'Creating…' : 'Create'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
