import React, { useCallback, useEffect, useState } from 'react';
import {
  History,
  RotateCcw,
  ShieldCheck,
  AlertTriangle,
  RefreshCw,
  ChevronRight,
  ChevronDown,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { EntityLink } from '@/shared/components/entity';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { wsManager } from '@/shared/services/WebSocketManager';
import { useAuth } from '@/shared/hooks/useAuth';
import { diskImagePublicationsApi } from '@system/features/system/services/api/diskImagePublicationsApi';
import type {
  SystemDiskImagePublication,
  SystemNodePlatform,
} from '@system/features/system/types/system.types';

interface Props {
  platform: SystemNodePlatform;
}

/**
 * Disk-image publication history for a platform. Shows every CI build
 * that's been registered, with the active row highlighted. Operators
 * with system.platforms.rollback_disk_image can re-activate any prior
 * published or retired publication (purged rows are read-only).
 *
 * Live updates via SystemFleetChannel: refresh on
 *   system.disk_image_published / system.disk_image_rolled_back /
 *   system.disk_image_retention_swept
 *
 * Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 4).
 */
export const DiskImageHistoryTab: React.FC<Props> = ({ platform }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const { currentUser } = useAuth();
  const accountId = (currentUser as { account?: { id?: string } } | null)?.account?.id;

  const canRollback = hasPermission('system.platforms.rollback_disk_image');

  const [publications, setPublications] = useState<SystemDiskImagePublication[]>([]);
  const [loading, setLoading] = useState(true);
  const [rollingBackId, setRollingBackId] = useState<string | null>(null);
  const [confirmTarget, setConfirmTarget] = useState<SystemDiskImagePublication | null>(null);

  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  const toggleExpanded = useCallback((id: string) => {
    setExpandedIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const result = await diskImagePublicationsApi.list(platform.id);
      setPublications(result.publications);
    } catch (e) {
      addNotification({
        type: 'error',
        message: e instanceof Error ? e.message : 'Failed to load publication history',
      });
    } finally {
      setLoading(false);
    }
  }, [platform.id, addNotification]);

  useEffect(() => { void refresh(); }, [refresh]);

  // Live updates via SystemFleetChannel.
  useEffect(() => {
    if (!accountId) return;
    const unsubscribe = wsManager.subscribe({
      channel: 'SystemFleetChannel',
      params: { account_id: accountId },
      onMessage: (data: unknown) => {
        const msg = data as { kind?: string; payload?: { platform_id?: string } };
        const relevant = ['system.disk_image_published', 'system.disk_image_publish_failed',
                          'system.disk_image_rolled_back', 'system.disk_image_retention_swept'];
        if (msg?.kind && relevant.includes(msg.kind) && msg.payload?.platform_id === platform.id) {
          void refresh();
        }
      },
      onError: () => {},
    });
    return () => unsubscribe();
  }, [accountId, platform.id, refresh]);

  const handleRollback = useCallback(async (publication: SystemDiskImagePublication) => {
    setRollingBackId(publication.id);
    try {
      await diskImagePublicationsApi.rollback(platform.id, publication.id);
      addNotification({
        type: 'success',
        message: `Activated publication for git_sha ${publication.git_sha_short}`,
      });
      setConfirmTarget(null);
      void refresh();
    } catch (e) {
      addNotification({
        type: 'error',
        message: e instanceof Error ? e.message : 'Rollback failed',
      });
    } finally {
      setRollingBackId(null);
    }
  }, [platform.id, addNotification, refresh]);

  const formatBytes = (n: number): string => {
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
    if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
    return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
  };

  const statusVariant = (status: string): 'success' | 'warning' | 'danger' | 'secondary' => {
    if (status === 'published') return 'success';
    if (status === 'failed') return 'danger';
    if (status === 'verifying' || status === 'awaiting_upload' || status === 'queued') return 'warning';
    return 'secondary';
  };

  return (
    <section className="bg-theme-surface rounded-lg border border-theme">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between">
        <div className="flex items-center gap-2">
          <History size={16} className="text-theme-info-fg" />
          <h2 className="font-medium text-theme-primary">Publication history</h2>
          {publications.length > 0 && (
            <Badge variant="info" size="xs">{publications.length}</Badge>
          )}
        </div>
        <Button size="xs" variant="ghost" onClick={refresh} disabled={loading} title="Refresh">
          <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
        </Button>
      </header>

      <div className="p-2">
        {loading && publications.length === 0 ? (
          <p className="text-sm text-theme-tertiary p-3">Loading…</p>
        ) : publications.length === 0 ? (
          <p className="text-sm text-theme-secondary p-3">
            No disk-image publications yet. Trigger a CI build to register one.
          </p>
        ) : (
          <ul className="divide-y divide-theme-border">
            {publications.map((p) => {
              const expanded = expandedIds.has(p.id);
              return (
              <li key={p.id} className={p.active ? 'bg-theme-surface-hover' : ''}>
                <div className="flex items-center justify-between gap-3 px-3 py-2.5">
                  <div className="flex items-start gap-2 flex-1 min-w-0">
                    <button
                      type="button"
                      onClick={() => toggleExpanded(p.id)}
                      className="p-1 -ml-1 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
                      title={expanded ? 'Collapse details' : 'Expand details'}
                    >
                      {expanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
                    </button>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 text-sm flex-wrap">
                        <code className="text-theme-primary font-mono">{p.git_sha_short}</code>
                        <Badge variant={statusVariant(p.status)} size="xs">{p.status}</Badge>
                        {p.active && <Badge variant="info" size="xs">active</Badge>}
                        <Badge variant="secondary" size="xs">{p.arch}</Badge>
                        {p.attestation_present && (
                          <span title="cosign attestation verified">
                            <ShieldCheck size={12} className="text-theme-success-fg" />
                          </span>
                        )}
                      </div>
                      <div className="mt-1 text-xs text-theme-tertiary flex items-center gap-3 flex-wrap">
                        <code className="font-mono">sha:{p.sha256_short}…</code>
                        <span>{formatBytes(p.size_bytes)}</span>
                        {p.published_at && (
                          <span>published {new Date(p.published_at).toLocaleString()}</span>
                        )}
                        {p.attempt_count > 1 && (
                          <span title="Retried after failure">
                            <AlertTriangle size={12} className="inline text-theme-warning-fg" /> {p.attempt_count} attempts
                          </span>
                        )}
                      </div>
                    </div>
                  </div>
                  <div className="flex items-center gap-1">
                    {canRollback && !p.active && p.status !== 'purged' && p.status !== 'failed' && p.status !== 'queued' && (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => setConfirmTarget(p)}
                        disabled={rollingBackId === p.id}
                        title="Activate this publication"
                      >
                        <RotateCcw size={14} />
                        Activate
                      </Button>
                    )}
                  </div>
                </div>

                {expanded && (
                  <div className="px-3 pb-3 pt-1 bg-theme-background border-t border-theme">
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-3 text-sm">
                      <div className="md:col-span-2">
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">SHA-256</label>
                        <p className="text-theme-primary font-mono text-xs break-all">{p.sha256}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Git SHA</label>
                        <p className="text-theme-primary font-mono text-xs break-all">{p.git_sha}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Architecture</label>
                        <p className="text-theme-primary">{p.arch}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Size</label>
                        <p className="text-theme-primary">{formatBytes(p.size_bytes)}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Firmware ref</label>
                        <p className="text-theme-primary font-mono text-xs break-all">{p.firmware_ref || '—'}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Attestation</label>
                        <p className="text-theme-primary flex items-center gap-1">
                          {p.attestation_present ? (
                            <><ShieldCheck size={14} className="text-theme-success-fg" /> present</>
                          ) : 'absent'}
                          {p.cosign_bundle_present && <span className="text-theme-tertiary">· cosign bundle</span>}
                        </p>
                      </div>
                      {p.oci_ref && (
                        <div className="md:col-span-2">
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">OCI ref</label>
                          <p className="text-theme-primary font-mono text-xs break-all">{p.oci_ref}</p>
                        </div>
                      )}
                      {p.webhook_label && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Webhook</label>
                          <p className="text-theme-primary">{p.webhook_label}</p>
                        </div>
                      )}
                      {p.triggered_by_worker_id && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Triggered by</label>
                          <p className="text-theme-primary">
                            <EntityLink
                              type="ci_worker"
                              id={p.triggered_by_worker_id}
                              label={p.triggered_by_worker_id}
                            />
                          </p>
                        </div>
                      )}
                      {p.verified_at && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Verified</label>
                          <p className="text-theme-primary text-xs">{new Date(p.verified_at).toLocaleString()}</p>
                        </div>
                      )}
                      {p.published_at && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Published</label>
                          <p className="text-theme-primary text-xs">{new Date(p.published_at).toLocaleString()}</p>
                        </div>
                      )}
                      {p.retired_at && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Retired</label>
                          <p className="text-theme-primary text-xs">{new Date(p.retired_at).toLocaleString()}</p>
                        </div>
                      )}
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                        <p className="text-theme-primary text-xs">{new Date(p.created_at).toLocaleString()}</p>
                      </div>
                    </div>
                    {p.error_message && (
                      <div className="mt-3">
                        <label className="block text-xs font-semibold text-theme-error-fg uppercase tracking-wide mb-1">Error</label>
                        <p className="text-xs text-theme-error-fg break-all">{p.error_message}</p>
                      </div>
                    )}
                  </div>
                )}
              </li>
              );
            })}
          </ul>
        )}
      </div>

      {confirmTarget && (
        <RollbackConfirmModal
          publication={confirmTarget}
          onConfirm={() => handleRollback(confirmTarget)}
          onCancel={() => setConfirmTarget(null)}
          submitting={rollingBackId === confirmTarget.id}
        />
      )}
    </section>
  );
};

const RollbackConfirmModal: React.FC<{
  publication: SystemDiskImagePublication;
  onConfirm: () => void;
  onCancel: () => void;
  submitting: boolean;
}> = ({ publication, onConfirm, onCancel, submitting }) => {
  return (
    <div className="fixed inset-0 z-50 bg-black/50 flex items-center justify-center p-4">
      <div className="bg-theme-surface rounded-lg shadow-xl w-full max-w-md p-6">
        <h3 className="text-lg font-semibold mb-3 text-theme-primary">Activate publication?</h3>
        <p className="text-sm text-theme-secondary mb-2">
          Re-activate publication{' '}
          <code className="font-mono">{publication.git_sha_short}</code>{' '}
          (sha {publication.sha256_short}…)?
        </p>
        <p className="text-xs text-theme-tertiary mb-4">
          The platform's disk-image pointer will flip to this publication. The
          currently-active publication will be retired (file_object soft-deleted,
          recoverable for the next 7 days).
        </p>
        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onCancel}>Cancel</Button>
          <Button variant="primary" onClick={onConfirm} disabled={submitting}>
            {submitting ? 'Activating…' : 'Activate'}
          </Button>
        </div>
      </div>
    </div>
  );
};

export default DiskImageHistoryTab;
