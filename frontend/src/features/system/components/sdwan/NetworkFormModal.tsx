import React, { useEffect, useState } from 'react';
import { Network, Pencil } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';
import { isPendingApproval } from '../../services/api/helpers';
import { pendingApprovalNotice } from '../../utils/pendingApproval';
import type { SdwanNetwork } from '../../types/sdwan.types';

interface NetworkFormModalProps {
  isOpen: boolean;
  /** The network to edit, or null to create a new one. */
  network: SdwanNetwork | null;
  onClose: () => void;
  onSaved: () => void;
}

/**
 * NetworkFormModal — create and edit an SDWAN network from one component, the
 * shape every other area of the app uses (networks/NetworkFormModal,
 * providers/ProviderFormModal, scripts/ScriptFormModal …). It replaces the
 * NetworkCreateModal/NetworkEditModal pair, whose bodies had drifted: the same
 * firewall option read "Allow all by default" on one and "Accept all" on the
 * other. The edit wording is the one kept.
 *
 * The /64 CIDR auto-allocates server-side via Sdwan::PrefixAllocator and is
 * immutable afterwards (the FirewallCompiler interface name and every peer's
 * /128 derive from it), so it is neither asked for nor editable.
 *
 * Status is an edit-only field: a network that does not exist yet has no status
 * to move.
 */
export const NetworkFormModal: React.FC<NetworkFormModalProps> = ({
  isOpen,
  network,
  onClose,
  onSaved,
}) => {
  const { addNotification } = useNotifications();
  const isEditMode = !!network;

  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [status, setStatus] = useState<string>('registered');
  const [defaultPolicy, setDefaultPolicy] = useState<'accept' | 'drop'>('accept');
  const [submitting, setSubmitting] = useState(false);

  const reset = () => {
    setName('');
    setDescription('');
    setStatus('registered');
    setDefaultPolicy('accept');
    setSubmitting(false);
  };

  useEffect(() => {
    if (!network) return;
    setName(network.name);
    setDescription(network.description ?? '');
    setStatus(network.status);
    setDefaultPolicy(
      (network.settings?.firewall_default_policy as 'accept' | 'drop') ?? 'accept'
    );
  }, [network]);

  const handleClose = () => {
    if (submitting) return;
    // Only the create form owns its fields; an edit form is re-seeded from the
    // network prop, so clearing here would blank the inputs mid-close.
    if (!isEditMode) reset();
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
      if (network) {
        const settings = { ...(network.settings ?? {}), firewall_default_policy: defaultPolicy };
        const result = await sdwanApi.updateNetwork(network.id, {
          name: name.trim(),
          description: description.trim() || undefined,
          status,
          settings,
        });
        if (isPendingApproval(result)) {
          addNotification(pendingApprovalNotice(`updating network "${name}"`, result));
          onClose();
          return;
        }
        addNotification({ type: 'success', message: `Network "${name}" updated` });
        onSaved();
        onClose();
        return;
      }

      const result = await sdwanApi.createNetwork({
        name: name.trim(),
        description: description.trim() || undefined,
        settings: defaultPolicy === 'drop' ? { firewall_default_policy: 'drop' } : undefined,
      });
      if (isPendingApproval(result)) {
        addNotification(pendingApprovalNotice(`creating network "${name}"`, result));
        reset();
        onClose();
        return;
      }
      addNotification({ type: 'success', message: `Network "${name}" created` });
      onSaved();
      reset();
      onClose();
    } catch (err) {
      const fallback = isEditMode ? 'Update failed' : 'Failed to create network';
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : fallback,
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={handleClose}
      title={network ? `Edit ${network.name}` : 'Create SDWAN network'}
      icon={network ? <Pencil className="w-6 h-6" /> : <Network className="w-6 h-6" />}
    >
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
          <label className="block text-sm font-medium text-theme-primary mb-1">
            {isEditMode ? 'Description' : 'Description (optional)'}
          </label>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
            rows={2}
            placeholder="What is this network for?"
            disabled={submitting}
          />
        </div>

        {isEditMode && (
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Status</label>
            <select
              value={status}
              onChange={(e) => setStatus(e.target.value)}
              className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
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
        )}

        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">
            Default firewall policy
          </label>
          <div className="flex gap-3">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="sdwan-network-firewall-policy"
                value="accept"
                checked={defaultPolicy === 'accept'}
                onChange={() => setDefaultPolicy('accept')}
                disabled={submitting}
              />
              <span className="text-sm text-theme-primary">Accept all</span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="sdwan-network-firewall-policy"
                value="drop"
                checked={defaultPolicy === 'drop'}
                onChange={() => setDefaultPolicy('drop')}
                disabled={submitting}
              />
              <span className="text-sm text-theme-primary">Drop all (allowlist)</span>
            </label>
          </div>
          {!isEditMode && (
            <p className="text-xs text-theme-secondary mt-1">
              The /64 CIDR is auto-allocated. Add firewall rules from the network detail page.
            </p>
          )}
        </div>

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={handleClose} disabled={submitting}>
            Cancel
          </Button>
          <Button variant="primary" type="submit" disabled={submitting || !name.trim()}>
            {submitting
              ? (isEditMode ? 'Saving…' : 'Creating…')
              : (isEditMode ? 'Save changes' : 'Create')}
          </Button>
        </div>
      </form>
    </Modal>
  );
};

export default NetworkFormModal;
