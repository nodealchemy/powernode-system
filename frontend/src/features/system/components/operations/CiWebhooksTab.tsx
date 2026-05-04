import React, { useCallback, useEffect, useState } from 'react';
import { Webhook, RotateCw, Trash2, Copy, Check } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { diskImageWebhooksApi } from '@system/features/system/services/api/diskImageWebhooksApi';
import type {
  SystemDiskImageWebhook,
  SystemDiskImageWebhookCreatedResponse,
} from '@system/features/system/types/system.types';

interface CiWebhooksTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const CiWebhooksTab: React.FC<CiWebhooksTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canDelete = hasPermission('system.disk_image_webhooks.delete');
  const canRotate = hasPermission('system.disk_image_webhooks.rotate_secret');

  const [webhooks, setWebhooks] = useState<SystemDiskImageWebhook[]>([]);
  const [loading, setLoading] = useState(true);
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [createdSecret, setCreatedSecret] = useState<SystemDiskImageWebhookCreatedResponse | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const result = await diskImageWebhooksApi.list();
      setWebhooks(result);
    } catch {
      addNotification({ type: 'error', message: 'Failed to load disk-image webhooks' });
    } finally {
      setLoading(false);
    }
  }, [addNotification]);

  useEffect(() => { void refresh(); }, [refresh]);

  useEffect(() => {
    onActionsReady?.({ openCreate: () => setShowCreateModal(true) });
    return () => onActionsReady?.(null);
  }, [onActionsReady]);

  const handleRevoke = useCallback(async (webhook: SystemDiskImageWebhook) => {
    if (!window.confirm(`Revoke webhook "${webhook.label}"? CI runs using this secret will start failing immediately.`)) return;
    try {
      await diskImageWebhooksApi.destroy(webhook.id);
      addNotification({ type: 'success', message: `Webhook "${webhook.label}" revoked` });
      void refresh();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Revoke failed' });
    }
  }, [addNotification, refresh]);

  const handleRotate = useCallback(async (webhook: SystemDiskImageWebhook) => {
    if (!window.confirm(`Rotate secret for "${webhook.label}"? Old secret is revoked immediately — update CI before the next webhook fires.`)) return;
    try {
      const result = await diskImageWebhooksApi.rotateSecret(webhook.id);
      setCreatedSecret(result);
      void refresh();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Rotation failed' });
    }
  }, [addNotification, refresh]);

  return (
    <div className="space-y-4">
      <p className="text-sm text-theme-secondary">
        Per-pipeline HMAC secrets that authorize CI runners to register disk-image builds.
        One per CI repo / pipeline. Plaintext secret is shown exactly once at create + rotate.
      </p>

      <section className="bg-theme-surface rounded-lg border border-theme">
        <header className="px-4 py-3 border-b border-theme flex items-center gap-2">
          <Webhook size={16} className="text-theme-info" />
          <h2 className="font-medium text-theme-primary">Active webhooks</h2>
          {webhooks.length > 0 && (
            <Badge variant="info" size="xs">{webhooks.length}</Badge>
          )}
        </header>
        <div className="p-2">
          {loading ? (
            <p className="text-sm text-theme-tertiary p-3">Loading…</p>
          ) : webhooks.length === 0 ? (
            <p className="text-sm text-theme-secondary p-3">
              No webhooks yet. Click "New webhook" to provision one for your CI pipeline.
            </p>
          ) : (
            <ul className="divide-y divide-theme">
              {webhooks.map((w) => (
                <li key={w.id} className="px-3 py-2.5">
                  <div className="flex items-center justify-between gap-3">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 text-sm">
                        <span className="font-medium text-theme-primary">{w.label}</span>
                        <Badge variant={w.status === 'active' ? 'success' : 'secondary'} size="xs">
                          {w.status}
                        </Badge>
                        <code className="text-xs text-theme-tertiary font-mono">
                          secret: {w.secret_preview}…
                        </code>
                      </div>
                      <div className="mt-1 text-xs text-theme-tertiary">
                        Received {w.received_count} times
                        {w.last_received_at && (
                          <> · last {new Date(w.last_received_at).toLocaleString()}</>
                        )}
                      </div>
                    </div>
                    <div className="flex items-center gap-1">
                      {canRotate && (
                        <Button size="sm" variant="outline" onClick={() => handleRotate(w)} title="Rotate secret">
                          <RotateCw size={14} />
                        </Button>
                      )}
                      {canDelete && (
                        <Button size="sm" variant="ghost" onClick={() => handleRevoke(w)} title="Revoke webhook">
                          <Trash2 size={14} className="text-theme-danger" />
                        </Button>
                      )}
                    </div>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>

      {showCreateModal && (
        <CreateWebhookModal
          onClose={() => setShowCreateModal(false)}
          onCreated={(result) => {
            setShowCreateModal(false);
            setCreatedSecret(result);
            void refresh();
          }}
        />
      )}

      {createdSecret && (
        <SecretShownOnceModal
          title={createdSecret.disk_image_webhook.label ? `Webhook: ${createdSecret.disk_image_webhook.label}` : 'New webhook'}
          plaintext={createdSecret.secret_plaintext}
          secondLine={`Webhook URL: ${createdSecret.webhook_url}`}
          note={createdSecret.note}
          onClose={() => setCreatedSecret(null)}
        />
      )}
    </div>
  );
};

const CreateWebhookModal: React.FC<{
  onClose: () => void;
  onCreated: (result: SystemDiskImageWebhookCreatedResponse) => void;
}> = ({ onClose, onCreated }) => {
  const [label, setLabel] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const { addNotification } = useNotifications();

  const handleSubmit = async () => {
    if (!label.trim()) return;
    setSubmitting(true);
    try {
      const result = await diskImageWebhooksApi.create(label.trim());
      onCreated(result);
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Create failed' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-black/50 flex items-center justify-center p-4">
      <div className="bg-theme-surface rounded-lg shadow-xl w-full max-w-md p-6">
        <h3 className="text-lg font-semibold mb-3 text-theme-primary">New disk-image webhook</h3>
        <label className="block text-sm text-theme-secondary mb-1" htmlFor="webhook-label-input">Label</label>
        <input
          id="webhook-label-input"
          type="text"
          value={label}
          onChange={(e) => setLabel(e.target.value)}
          placeholder="main-ci"
          className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary mb-4"
        />
        <p className="text-xs text-theme-tertiary mb-4">
          Pick a name that identifies this CI pipeline (e.g. "main-ci", "release-pipeline").
          Must be unique within your account.
        </p>
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button variant="primary" onClick={handleSubmit} disabled={!label.trim() || submitting}>
            {submitting ? 'Creating…' : 'Create webhook'}
          </Button>
        </div>
      </div>
    </div>
  );
};

const SecretShownOnceModal: React.FC<{
  title: string;
  plaintext: string;
  secondLine?: string;
  note: string;
  onClose: () => void;
}> = ({ title, plaintext, secondLine, note, onClose }) => {
  const [acknowledged, setAcknowledged] = useState(false);
  const [copiedSecret, setCopiedSecret] = useState(false);
  const [copiedSecond, setCopiedSecond] = useState(false);

  const copy = (text: string, setter: (v: boolean) => void) => {
    navigator.clipboard.writeText(text);
    setter(true);
    setTimeout(() => setter(false), 2000);
  };

  return (
    <div className="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4">
      <div className="bg-theme-surface rounded-lg shadow-xl w-full max-w-2xl p-6">
        <h3 className="text-lg font-semibold mb-2 text-theme-primary">{title}</h3>
        <p className="text-sm text-theme-warning mb-4 font-medium">
          ⚠️ This secret is shown ONCE. It cannot be recovered. Save it now.
        </p>

        <label className="block text-sm text-theme-secondary mb-1">Secret</label>
        <div className="flex items-center gap-2 mb-4">
          <code className="flex-1 px-3 py-2 rounded border border-theme bg-theme-surface text-theme-primary font-mono text-sm break-all">
            {plaintext}
          </code>
          <Button size="sm" variant="outline" onClick={() => copy(plaintext, setCopiedSecret)}>
            {copiedSecret ? <Check size={14} /> : <Copy size={14} />}
          </Button>
        </div>

        {secondLine && (
          <>
            <label className="block text-sm text-theme-secondary mb-1">Webhook URL</label>
            <div className="flex items-center gap-2 mb-4">
              <code className="flex-1 px-3 py-2 rounded border border-theme bg-theme-surface text-theme-primary font-mono text-xs break-all">
                {secondLine.replace(/^Webhook URL: /, '')}
              </code>
              <Button size="sm" variant="outline" onClick={() => copy(secondLine.replace(/^Webhook URL: /, ''), setCopiedSecond)}>
                {copiedSecond ? <Check size={14} /> : <Copy size={14} />}
              </Button>
            </div>
          </>
        )}

        <p className="text-xs text-theme-tertiary mb-4">{note}</p>

        <label className="flex items-center gap-2 cursor-pointer mb-4">
          <input
            type="checkbox"
            checked={acknowledged}
            onChange={(e) => setAcknowledged(e.target.checked)}
            className="w-4 h-4 rounded border-theme bg-theme-surface"
          />
          <span className="text-sm text-theme-primary">I have saved the secret in my CI's secret manager</span>
        </label>

        <div className="flex justify-end">
          <Button variant="primary" onClick={onClose} disabled={!acknowledged}>Done</Button>
        </div>
      </div>
    </div>
  );
};
