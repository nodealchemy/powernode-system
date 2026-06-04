import React, { useCallback, useEffect, useState } from 'react';
import { GitBranch, RefreshCw, Trash2 } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { gitopsApi } from '@system/features/system/services/api/gitopsApi';
import type { SystemGitopsRepository } from '@system/features/system/types/system.types';

interface GitopsTabProps {
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

function statusVariant(status: string): 'success' | 'danger' | 'warning' | 'secondary' {
  switch (status) {
    case 'success':
      return 'success';
    case 'failed':
      return 'danger';
    case 'partial':
      return 'warning';
    default:
      return 'secondary';
  }
}

export const GitopsTab: React.FC<GitopsTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canWrite = hasPermission('system.gitops.write');
  const canSync = hasPermission('system.gitops.sync');

  const [repositories, setRepositories] = useState<SystemGitopsRepository[]>([]);
  const [loading, setLoading] = useState(true);
  const [syncingId, setSyncingId] = useState<string | null>(null);
  const [showCreateModal, setShowCreateModal] = useState(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const result = await gitopsApi.list();
      setRepositories(result.gitops_repositories);
    } catch {
      addNotification({ type: 'error', message: 'Failed to load GitOps repositories' });
    } finally {
      setLoading(false);
    }
  }, [addNotification]);

  useEffect(() => { void refresh(); }, [refresh]);

  useEffect(() => {
    onActionsReady?.({ openCreate: () => setShowCreateModal(true) });
    return () => onActionsReady?.(null);
  }, [onActionsReady]);

  const handleSyncNow = useCallback(async (repo: SystemGitopsRepository) => {
    setSyncingId(repo.id);
    try {
      const result = await gitopsApi.syncNow(repo.id);
      addNotification({
        type: result.ok ? 'success' : 'warning',
        message: result.ok
          ? `Reconciled "${repo.name}" — ${result.diff_count} diff(s), ${result.proposal_ids.length} proposal(s)`
          : `Reconcile of "${repo.name}" completed with errors`,
      });
      void refresh();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Sync failed' });
    } finally {
      setSyncingId(null);
    }
  }, [addNotification, refresh]);

  const handleDelete = useCallback(async (repo: SystemGitopsRepository) => {
    if (!window.confirm(`Delete GitOps repository "${repo.name}"? Reconciliation will stop and its sync history is removed.`)) return;
    try {
      await gitopsApi.destroy(repo.id);
      addNotification({ type: 'success', message: `Repository "${repo.name}" deleted` });
      void refresh();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Delete failed' });
    }
  }, [addNotification, refresh]);

  return (
    <div className="space-y-4">
      <p className="text-sm text-theme-secondary">
        GitOps repositories describe desired fleet state in git (templates,
        assignments, provider configs). A reconciler ticks every 5 minutes per
        enabled repo, diffs desired vs. live state, and opens proposals for any
        drift. Use "Sync now" to reconcile a repo off-schedule.
      </p>

      <section className="bg-theme-surface rounded-lg border border-theme">
        <header className="px-4 py-3 border-b border-theme flex items-center gap-2">
          <GitBranch size={16} className="text-theme-info" />
          <h2 className="font-medium text-theme-primary">Repositories</h2>
          {repositories.length > 0 && (
            <Badge variant="info" size="xs">{repositories.length}</Badge>
          )}
        </header>
        <div className="p-2">
          {loading ? (
            <p className="text-sm text-theme-tertiary p-3">Loading…</p>
          ) : repositories.length === 0 ? (
            <p className="text-sm text-theme-secondary p-3">
              No GitOps repositories yet. Click "New repository" to register a git repo for fleet reconciliation.
            </p>
          ) : (
            <ul className="divide-y divide-theme">
              {repositories.map((repo) => (
                <li key={repo.id} className="px-3 py-2.5">
                  <div className="flex items-center justify-between gap-3">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 text-sm">
                        <span className="font-medium text-theme-primary">{repo.name}</span>
                        <Badge variant={statusVariant(repo.last_status)} size="xs">
                          {repo.last_status}
                        </Badge>
                        {!repo.enabled && (
                          <Badge variant="secondary" size="xs">disabled</Badge>
                        )}
                        {repo.auto_apply && (
                          <Badge variant="warning" size="xs">auto-apply</Badge>
                        )}
                      </div>
                      <div className="mt-1 text-xs text-theme-tertiary truncate">
                        <code className="text-xs">{repo.repo_url}</code>
                        <span className="mx-1">·</span>
                        <span>{repo.branch}</span>
                        {repo.path_prefix ? <span className="mx-1">·</span> : null}
                        {repo.path_prefix ? <code className="text-xs">{repo.path_prefix}</code> : null}
                      </div>
                      <div className="mt-0.5 text-xs text-theme-tertiary">
                        {repo.last_synced_at
                          ? <>Last synced {new Date(repo.last_synced_at).toLocaleString()} · {repo.last_diff_count} diff(s)</>
                          : 'Never synced'}
                        {repo.last_error ? (
                          <span className="text-theme-danger"> · {repo.last_error}</span>
                        ) : null}
                      </div>
                    </div>
                    <div className="flex items-center gap-1">
                      {canSync && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => handleSyncNow(repo)}
                          disabled={syncingId === repo.id || !repo.enabled}
                          title="Sync now"
                        >
                          <RefreshCw size={14} className={syncingId === repo.id ? 'animate-spin' : undefined} />
                        </Button>
                      )}
                      {canWrite && (
                        <Button size="sm" variant="ghost" onClick={() => handleDelete(repo)} title="Delete repository">
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
        <CreateGitopsRepositoryModal
          onClose={() => setShowCreateModal(false)}
          onCreated={() => {
            setShowCreateModal(false);
            void refresh();
          }}
        />
      )}
    </div>
  );
};

const CreateGitopsRepositoryModal: React.FC<{
  onClose: () => void;
  onCreated: () => void;
}> = ({ onClose, onCreated }) => {
  const [name, setName] = useState('');
  const [repoUrl, setRepoUrl] = useState('');
  const [branch, setBranch] = useState('main');
  const [pathPrefix, setPathPrefix] = useState('');
  const [vaultCredentialPath, setVaultCredentialPath] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const { addNotification } = useNotifications();

  const canSubmit = name.trim().length > 0 && repoUrl.trim().length > 0 && !submitting;

  const handleSubmit = async () => {
    if (!canSubmit) return;
    setSubmitting(true);
    try {
      await gitopsApi.create({
        name: name.trim(),
        repo_url: repoUrl.trim(),
        branch: branch.trim() || 'main',
        path_prefix: pathPrefix.trim() || undefined,
        vault_credential_path: vaultCredentialPath.trim() || undefined,
      });
      addNotification({ type: 'success', message: `Repository "${name.trim()}" registered` });
      onCreated();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Create failed' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-black/50 flex items-center justify-center p-4">
      <div className="bg-theme-surface rounded-lg shadow-xl w-full max-w-md p-6">
        <h3 className="text-lg font-semibold mb-3 text-theme-primary">New GitOps repository</h3>

        <label className="block text-sm text-theme-secondary mb-1" htmlFor="gitops-name-input">Name</label>
        <input
          id="gitops-name-input"
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="fleet-desired-state"
          className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary mb-4"
        />

        <label className="block text-sm text-theme-secondary mb-1" htmlFor="gitops-repo-url-input">Repository URL</label>
        <input
          id="gitops-repo-url-input"
          type="text"
          value={repoUrl}
          onChange={(e) => setRepoUrl(e.target.value)}
          placeholder="https://git.example.com/org/fleet.git"
          className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary mb-4"
        />

        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-sm text-theme-secondary mb-1" htmlFor="gitops-branch-input">Branch</label>
            <input
              id="gitops-branch-input"
              type="text"
              value={branch}
              onChange={(e) => setBranch(e.target.value)}
              placeholder="main"
              className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary mb-4"
            />
          </div>
          <div>
            <label className="block text-sm text-theme-secondary mb-1" htmlFor="gitops-path-prefix-input">Path prefix</label>
            <input
              id="gitops-path-prefix-input"
              type="text"
              value={pathPrefix}
              onChange={(e) => setPathPrefix(e.target.value)}
              placeholder="(repo root)"
              className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary mb-4"
            />
          </div>
        </div>

        <label className="block text-sm text-theme-secondary mb-1" htmlFor="gitops-vault-path-input">
          Vault credential path <span className="text-theme-tertiary">(optional — for private repos)</span>
        </label>
        <input
          id="gitops-vault-path-input"
          type="text"
          value={vaultCredentialPath}
          onChange={(e) => setVaultCredentialPath(e.target.value)}
          placeholder="secret/data/gitops/fleet-deploy-key"
          className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary mb-4"
        />

        <p className="text-xs text-theme-tertiary mb-4">
          The reconciler reads desired fleet state from this repo and opens
          proposals for any drift. Enable auto-apply later from the repo's
          settings to apply diffs without manual approval.
        </p>

        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button variant="primary" onClick={handleSubmit} disabled={!canSubmit}>
            {submitting ? 'Creating…' : 'Register repository'}
          </Button>
        </div>
      </div>
    </div>
  );
};
