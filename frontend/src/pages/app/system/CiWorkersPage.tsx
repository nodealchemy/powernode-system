import React, { useCallback, useEffect, useState } from 'react';
import { Bot, Plus, RotateCw, Trash2, Copy, Check } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { ciWorkersApi } from '@system/features/system/services/api/ciWorkersApi';
import type {
  SystemCiWorker,
  SystemCiWorkerCreatedResponse,
} from '@system/features/system/types/system.types';

/**
 * Operator-facing CRUD for per-account CI workers (Worker rows holding
 * the ci_worker role — narrowly scoped to `system.platforms.publish_disk_image`).
 *
 * Token plaintext is shown EXACTLY ONCE on create + rotate. The
 * "save before close" modal forces explicit acknowledgement.
 *
 * Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 4).
 */
const CiWorkersPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();

  const canCreate = hasPermission('system.ci_workers.create');
  const canDelete = hasPermission('system.ci_workers.delete');
  const canRotate = hasPermission('system.ci_workers.rotate_token');

  const [workers, setWorkers] = useState<SystemCiWorker[]>([]);
  const [loading, setLoading] = useState(true);
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [createdToken, setCreatedToken] = useState<SystemCiWorkerCreatedResponse | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setWorkers(await ciWorkersApi.list());
    } catch {
      addNotification({ type: 'error', message: 'Failed to load CI workers' });
    } finally {
      setLoading(false);
    }
  }, [addNotification]);

  useEffect(() => { void refresh(); }, [refresh]);

  const handleRevoke = useCallback(async (worker: SystemCiWorker) => {
    if (!window.confirm(`Revoke CI worker "${worker.name}"? CI runs using this token will start failing immediately.`)) return;
    try {
      await ciWorkersApi.destroy(worker.id);
      addNotification({ type: 'success', message: `CI worker "${worker.name}" revoked` });
      void refresh();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Revoke failed' });
    }
  }, [addNotification, refresh]);

  const handleRotate = useCallback(async (worker: SystemCiWorker) => {
    if (!window.confirm(`Rotate token for "${worker.name}"? Old token is revoked immediately — update CI before the next run.`)) return;
    try {
      const result = await ciWorkersApi.rotateToken(worker.id);
      setCreatedToken(result);
      void refresh();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Rotation failed' });
    }
  }, [addNotification, refresh]);

  return (
    <PageContainer
      title="CI workers"
      actions={canCreate ? [
        {
          label: 'New CI worker',
          icon: Plus,
          variant: 'primary',
          onClick: () => setShowCreateModal(true),
        },
      ] : []}
    >
      <div className="p-4 space-y-4">
        <p className="text-sm text-theme-secondary">
          Per-pipeline CI worker tokens. Holds only{' '}
          <code className="text-xs">system.platforms.publish_disk_image</code>{' '}
          permission — a leaked token can register disk images but cannot read
          other resources or escalate. Token plaintext is shown exactly once at
          create + rotate.
        </p>

        <section className="bg-theme-surface rounded-lg border border-theme-border">
          <header className="px-4 py-3 border-b border-theme-border flex items-center gap-2">
            <Bot size={16} className="text-theme-accent" />
            <h2 className="font-medium text-theme-primary">Active CI workers</h2>
            {workers.length > 0 && (
              <Badge variant="info" size="xs">{workers.length}</Badge>
            )}
          </header>
          <div className="p-2">
            {loading ? (
              <p className="text-sm text-theme-tertiary p-3">Loading…</p>
            ) : workers.length === 0 ? (
              <p className="text-sm text-theme-secondary p-3">
                No CI workers yet. Click "New CI worker" to provision a token for your CI pipeline.
              </p>
            ) : (
              <ul className="divide-y divide-theme-border">
                {workers.map((w) => (
                  <li key={w.id} className="px-3 py-2.5">
                    <div className="flex items-center justify-between gap-3">
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2 text-sm">
                          <span className="font-medium text-theme-primary">{w.name}</span>
                          <Badge variant={w.status === 'active' ? 'success' : 'secondary'} size="xs">
                            {w.status}
                          </Badge>
                        </div>
                        <div className="mt-1 text-xs text-theme-tertiary">
                          {w.last_seen_at ? <>Last seen {new Date(w.last_seen_at).toLocaleString()}</> : 'Never seen'}
                        </div>
                      </div>
                      <div className="flex items-center gap-1">
                        {canRotate && (
                          <Button size="sm" variant="outline" onClick={() => handleRotate(w)} title="Rotate token">
                            <RotateCw size={14} />
                          </Button>
                        )}
                        {canDelete && (
                          <Button size="sm" variant="ghost" onClick={() => handleRevoke(w)} title="Revoke worker">
                            <Trash2 size={14} className="text-theme-error" />
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
      </div>

      {showCreateModal && (
        <CreateCiWorkerModal
          onClose={() => setShowCreateModal(false)}
          onCreated={(result) => {
            setShowCreateModal(false);
            setCreatedToken(result);
            void refresh();
          }}
        />
      )}

      {createdToken && (
        <TokenShownOnceModal
          name={createdToken.ci_worker.name}
          plaintext={createdToken.token_plaintext}
          note={createdToken.note}
          onClose={() => setCreatedToken(null)}
        />
      )}
    </PageContainer>
  );
};

const CreateCiWorkerModal: React.FC<{
  onClose: () => void;
  onCreated: (result: SystemCiWorkerCreatedResponse) => void;
}> = ({ onClose, onCreated }) => {
  const [name, setName] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const { addNotification } = useNotifications();

  const handleSubmit = async () => {
    if (!name.trim()) return;
    setSubmitting(true);
    try {
      const result = await ciWorkersApi.create(name.trim());
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
        <h3 className="text-lg font-semibold mb-3 text-theme-primary">New CI worker</h3>
        <label className="block text-sm text-theme-secondary mb-1" htmlFor="ci-worker-name-input">Name</label>
        <input
          id="ci-worker-name-input"
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="release-pipeline-runner"
          className="w-full px-3 py-2 rounded-lg border border-theme-border bg-theme-background text-theme-primary mb-4"
        />
        <p className="text-xs text-theme-tertiary mb-4">
          Pick a name that identifies the CI pipeline (e.g. "main-ci-runner",
          "release-pipeline-runner"). Stored as POWERNODE_CI_WORKER_TOKEN in your CI secrets.
        </p>
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button variant="primary" onClick={handleSubmit} disabled={!name.trim() || submitting}>
            {submitting ? 'Creating…' : 'Create CI worker'}
          </Button>
        </div>
      </div>
    </div>
  );
};

const TokenShownOnceModal: React.FC<{
  name: string;
  plaintext: string;
  note: string;
  onClose: () => void;
}> = ({ name, plaintext, note, onClose }) => {
  const [acknowledged, setAcknowledged] = useState(false);
  const [copied, setCopied] = useState(false);

  const copy = () => {
    navigator.clipboard.writeText(plaintext);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4">
      <div className="bg-theme-surface rounded-lg shadow-xl w-full max-w-2xl p-6">
        <h3 className="text-lg font-semibold mb-2 text-theme-primary">CI worker: {name}</h3>
        <p className="text-sm text-theme-warning mb-4 font-medium">
          ⚠️ This token is shown ONCE. It cannot be recovered. Save it now.
        </p>

        <label className="block text-sm text-theme-secondary mb-1">Token</label>
        <div className="flex items-center gap-2 mb-4">
          <code className="flex-1 px-3 py-2 rounded border border-theme-border bg-theme-background text-theme-primary font-mono text-sm break-all">
            {plaintext}
          </code>
          <Button size="sm" variant="outline" onClick={copy}>
            {copied ? <Check size={14} /> : <Copy size={14} />}
          </Button>
        </div>

        <p className="text-xs text-theme-tertiary mb-4">{note}</p>

        <label className="flex items-center gap-2 cursor-pointer mb-4">
          <input
            type="checkbox"
            checked={acknowledged}
            onChange={(e) => setAcknowledged(e.target.checked)}
            className="w-4 h-4 rounded border-theme bg-theme-background"
          />
          <span className="text-sm text-theme-primary">I have saved the token in my CI's secret manager</span>
        </label>

        <div className="flex justify-end">
          <Button variant="primary" onClick={onClose} disabled={!acknowledged}>
            Done
          </Button>
        </div>
      </div>
    </div>
  );
};

export default CiWorkersPage;
