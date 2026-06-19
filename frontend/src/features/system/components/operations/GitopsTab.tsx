import React, { useCallback, useEffect, useState } from 'react';
import { GitBranch, RefreshCw, Trash2, ChevronRight, ChevronDown } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { EntityLink } from '@/shared/components/entity';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { gitopsApi } from '@system/features/system/services/api/gitopsApi';
import type {
  SystemGitopsRepository,
  SystemGitopsSyncRun,
} from '@system/features/system/types/system.types';

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

  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  // Per-repo sync-run history, lazily fetched on first expand.
  const [syncRuns, setSyncRuns] = useState<Record<string, SystemGitopsSyncRun[]>>({});
  const [runsLoadingId, setRunsLoadingId] = useState<string | null>(null);

  const loadSyncRuns = useCallback(async (id: string) => {
    setRunsLoadingId(id);
    try {
      const runs = await gitopsApi.syncRuns(id);
      setSyncRuns(prev => ({ ...prev, [id]: runs }));
    } catch {
      addNotification({ type: 'error', message: 'Failed to load sync history' });
    } finally {
      setRunsLoadingId(null);
    }
  }, [addNotification]);

  const toggleExpanded = useCallback((id: string) => {
    const willExpand = !expandedIds.has(id);
    setExpandedIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
    // Lazy-load sync history the first time a repo is expanded. Fired outside
    // the state updater so it runs exactly once (updaters can re-run).
    if (willExpand && !syncRuns[id]) void loadSyncRuns(id);
  }, [expandedIds, syncRuns, loadSyncRuns]);

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
      // The just-fired tick added a new sync run — invalidate cached history so
      // an expanded row reflects it (refetch now if open, else on next expand).
      setSyncRuns(prev => {
        const next = { ...prev };
        delete next[repo.id];
        return next;
      });
      if (expandedIds.has(repo.id)) void loadSyncRuns(repo.id);
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Sync failed' });
    } finally {
      setSyncingId(null);
    }
  }, [addNotification, refresh, expandedIds, loadSyncRuns]);

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
          <GitBranch size={16} className="text-theme-info-fg" />
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
              {repositories.map((repo) => {
                const expanded = expandedIds.has(repo.id);
                const runs = syncRuns[repo.id];
                return (
                <li key={repo.id} className="px-3 py-2.5">
                  <div className="flex items-start justify-between gap-3">
                    <button
                      type="button"
                      onClick={() => toggleExpanded(repo.id)}
                      className="p-1 -ml-1 mt-0.5 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
                      title={expanded ? 'Collapse details' : 'Expand details'}
                    >
                      {expanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
                    </button>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 text-sm">
                        <EntityLink
                          type="gitops_repository"
                          id={repo.id}
                          label={repo.name}
                          className="font-medium"
                        />
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
                          <span className="text-theme-danger-fg"> · {repo.last_error}</span>
                        ) : null}
                      </div>

                      {expanded && (
                        <div className="mt-2 pt-2 border-t border-theme space-y-3">
                          <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last status</label>
                              <p className="text-theme-primary">{repo.last_status}</p>
                            </div>
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last diff count</label>
                              <p className="text-theme-primary">{repo.last_diff_count}</p>
                            </div>
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last synced</label>
                              <p className="text-theme-primary text-xs">{repo.last_synced_at ? new Date(repo.last_synced_at).toLocaleString() : 'Never'}</p>
                            </div>
                            {repo.last_synced_revision && (
                              <div>
                                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last revision</label>
                                <p className="text-theme-primary font-mono text-xs truncate" title={repo.last_synced_revision}>{repo.last_synced_revision}</p>
                              </div>
                            )}
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Auto-apply</label>
                              <p className="text-theme-primary">{repo.auto_apply ? 'Enabled' : 'Disabled'}</p>
                            </div>
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Enabled</label>
                              <p className="text-theme-primary">{repo.enabled ? 'Yes' : 'No'}</p>
                            </div>
                            {repo.last_error && (
                              <div className="col-span-full">
                                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last error</label>
                                <pre className="text-xs text-theme-error-fg whitespace-pre-wrap font-mono">{repo.last_error}</pre>
                              </div>
                            )}
                          </div>

                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Sync history</label>
                            {runsLoadingId === repo.id && !runs ? (
                              <p className="text-xs text-theme-tertiary">Loading history…</p>
                            ) : !runs || runs.length === 0 ? (
                              <p className="text-xs text-theme-tertiary">No sync runs recorded yet.</p>
                            ) : (
                              <ul className="space-y-1">
                                {runs.map((run) => (
                                  <li key={run.id} className="flex items-center gap-2 text-xs flex-wrap">
                                    <Badge variant={statusVariant(run.status)} size="xs">{run.status}</Badge>
                                    <span className="text-theme-secondary">{new Date(run.started_at).toLocaleString()}</span>
                                    <span className="text-theme-tertiary">· {run.diff_count} diff(s)</span>
                                    {run.proposal_ids.length > 0 && (
                                      <span className="text-theme-tertiary">· {run.proposal_ids.length} proposal(s)</span>
                                    )}
                                    {typeof run.duration_seconds === 'number' && (
                                      <span className="text-theme-tertiary">· {run.duration_seconds}s</span>
                                    )}
                                    {run.synced_revision && (
                                      <code className="text-theme-tertiary font-mono truncate max-w-[8rem]" title={run.synced_revision}>{run.synced_revision}</code>
                                    )}
                                    {run.error_message && (
                                      <span className="text-theme-danger-fg">· {run.error_message}</span>
                                    )}
                                  </li>
                                ))}
                              </ul>
                            )}
                          </div>
                        </div>
                      )}
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
                          <Trash2 size={14} className="text-theme-danger-fg" />
                        </Button>
                      )}
                    </div>
                  </div>
                </li>
                );
              })}
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
