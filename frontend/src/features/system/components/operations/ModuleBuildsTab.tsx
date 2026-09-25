import React, { useCallback, useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Hammer } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { useAuth } from '@/shared/hooks/useAuth';
import { useWsSubscription } from '@/shared/hooks/useWsSubscription';
import { moduleBuildsApi } from '@system/features/system/services/api/moduleBuildsApi';
import { BatchList } from './BatchList';
import { BatchDetailModal } from './BatchDetailModal';
import type {
  SystemModuleBuildBatch,
  SystemModuleBuildBatchStatus,
  SystemModuleBuildBatchTrigger,
} from '@system/features/system/types/system.types';
import type { PaginationMeta } from '@system/features/system/services/api/types';

interface ModuleBuildsTabProps {
  onActionsReady?: (handle: { refresh: () => void } | null) => void;
}

// While any listed batch is still active, poll for updates — batches move
// through their AASM ladder server-side (dispatch → sign → publish →
// complete/partial/fail) with no operator action in between, so this is the
// only way the list picks up progress without a manual refresh.
const POLL_INTERVAL_MS = 12_000;

const STATUS_OPTIONS: SystemModuleBuildBatchStatus[] = [
  'planning', 'dispatched', 'awaiting_signature', 'publishing', 'complete', 'partial', 'failed', 'cancelled',
];
const TRIGGER_OPTIONS: SystemModuleBuildBatchTrigger[] = ['push', 'manual', 'cve', 'package'];

/**
 * Module Builds tab (campaign 019f6084 inc5) — operator view over
 * System::ModuleBuildBatch, the agent-pollable build-completion barrier for
 * both platform module builds (push/manual/cve) and on-demand
 * package-closure builds (trigger "package"; routed through the same batch
 * by System::PackageClosureBuildBridge as of inc2-B). Dispatch itself stays
 * worker/webhook-gated (system.module_builds.dispatch) — no "Trigger build"
 * action here.
 *
 * fc-34: this is now the ONE canonical Module Builds surface — the core
 * DevOps → CI/CD tab (ModuleBuildsPage/ModuleBuildDetailPage, a URL-only
 * cross-boundary seam onto this same API) was deleted as a duplicate.
 * BatchList and BatchDetailModal both carry the ported Cancel action
 * (system.module_builds.cancel), so this is no longer read-only.
 *
 * Review fix: restores the parity the deleted core page had that this tab
 * initially lacked — status/trigger filters, real pagination (the server
 * pages 20 at a time; the header badge shows meta.total_count, not just the
 * fetched page's length), and an inline error banner with a retry button
 * instead of only a toast. The selected batch id is mirrored into a
 * `?batch=` query param so a detail link is a real, shareable deep link
 * rather than local-only state.
 */
export const ModuleBuildsTab: React.FC<ModuleBuildsTabProps> = ({ onActionsReady }) => {
  const { currentUser } = useAuth();
  const accountId = (currentUser as { account?: { id?: string } } | null)?.account?.id;
  const [searchParams, setSearchParams] = useSearchParams();

  const [batches, setBatches] = useState<SystemModuleBuildBatch[]>([]);
  const [meta, setMeta] = useState<PaginationMeta | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState('');
  const [triggerFilter, setTriggerFilter] = useState('');
  const [page, setPage] = useState(1);
  const selectedBatchId = searchParams.get('batch');

  const setSelectedBatchId = useCallback(
    (id: string | null) => {
      setSearchParams(
        (prev) => {
          const next = new URLSearchParams(prev);
          if (id) next.set('batch', id); else next.delete('batch');
          return next;
        },
        { replace: !id },
      );
    },
    [setSearchParams],
  );

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await moduleBuildsApi.list({
        status: statusFilter || undefined,
        trigger: triggerFilter || undefined,
        page,
      });
      setBatches(result.module_build_batches);
      setMeta(result.meta);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load module build batches');
    } finally {
      setLoading(false);
    }
  }, [statusFilter, triggerFilter, page]);

  useEffect(() => { void refresh(); }, [refresh]);

  // A filter change makes the current page number meaningless against the
  // new result set — reset to page 1 rather than risk landing past the end.
  useEffect(() => { setPage(1); }, [statusFilter, triggerFilter]);

  useEffect(() => {
    onActionsReady?.({ refresh: () => void refresh() });
    return () => onActionsReady?.(null);
  }, [onActionsReady, refresh]);

  // Poll while any listed batch is still active (not in a terminal state).
  // Stops once every batch has finished — no point polling a static list.
  const hasActiveBatch = batches.some((b) => b.active);
  useEffect(() => {
    if (!hasActiveBatch) return;
    const interval = setInterval(() => { void refresh(); }, POLL_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [hasActiveBatch, refresh]);

  // Live updates via SystemFleetChannel — any system.module_build_* FleetEvent
  // (parity result, per-module success, etc. — see
  // ModuleBuildParityService / NativeModuleBuildOrchestrator emit_event
  // calls) triggers a refetch rather than trying to patch individual rows
  // from the event payload.
  useWsSubscription(
    {
      channel: 'SystemFleetChannel',
      params: { account_id: accountId },
      onMessage: (data: unknown) => {
        const msg = data as { kind?: string };
        if (msg?.kind?.startsWith('system.module_build')) {
          void refresh();
        }
      },
    },
    { enabled: !!accountId, deps: [accountId, refresh] }
  );

  return (
    <div className="space-y-4">
      <p className="text-sm text-theme-secondary">
        Module build batches are the operator-visible unit of a native
        module-build run — one row per push/manual/CVE-triggered platform
        rebuild, or an on-demand package-closure build (trigger
        &quot;package&quot;). Until package-triggered builds accrue this list
        may be sparse; both platform and package builds route through the
        same batch here.
      </p>

      <section className="bg-theme-surface rounded-lg border border-theme">
        <header className="px-4 py-3 border-b border-theme flex flex-wrap items-center gap-3">
          <Hammer size={16} className="text-theme-info-fg" />
          <h2 className="font-medium text-theme-primary">Build batches</h2>
          {meta && meta.total_count > 0 && (
            <Badge variant="info" size="xs">{meta.total_count}</Badge>
          )}
          <div className="flex items-center gap-2 ml-auto">
            <label className="text-xs text-theme-secondary" htmlFor="module-builds-status-filter">
              Status
              <select
                id="module-builds-status-filter"
                value={statusFilter}
                onChange={(e) => setStatusFilter(e.target.value)}
                className="ml-2 px-2 py-1 rounded border border-theme bg-theme-surface text-theme-primary text-xs"
              >
                <option value="">All</option>
                {STATUS_OPTIONS.map((s) => (
                  <option key={s} value={s}>{s.replace(/_/g, ' ')}</option>
                ))}
              </select>
            </label>
            <label className="text-xs text-theme-secondary" htmlFor="module-builds-trigger-filter">
              Trigger
              <select
                id="module-builds-trigger-filter"
                value={triggerFilter}
                onChange={(e) => setTriggerFilter(e.target.value)}
                className="ml-2 px-2 py-1 rounded border border-theme bg-theme-surface text-theme-primary text-xs"
              >
                <option value="">All</option>
                {TRIGGER_OPTIONS.map((t) => (
                  <option key={t} value={t}>{t}</option>
                ))}
              </select>
            </label>
          </div>
        </header>

        {error && (
          <div className="p-4">
            <ErrorAlert message={error} />
            <Button onClick={() => void refresh()} variant="secondary" size="sm" className="mt-2">
              Try Again
            </Button>
          </div>
        )}

        {!error && (
          <div className="p-2">
            {loading && batches.length === 0 ? (
              <p className="text-sm text-theme-tertiary p-3">Loading…</p>
            ) : batches.length === 0 ? (
              <p className="text-sm text-theme-secondary p-3">
                No module build batches yet. Push a module change, or trigger a
                package build, to see it appear here.
              </p>
            ) : (
              <BatchList batches={batches} onSelect={setSelectedBatchId} onCancelled={refresh} />
            )}
          </div>
        )}

        {meta && meta.total_pages > 1 && (
          <div className="flex items-center justify-between px-4 py-3 border-t border-theme">
            <p className="text-xs text-theme-tertiary">
              Showing {batches.length} of {meta.total_count} batches
            </p>
            <div className="flex items-center gap-2">
              <Button
                onClick={() => setPage((p) => Math.max(1, p - 1))}
                disabled={page === 1}
                variant="secondary"
                size="sm"
              >
                Previous
              </Button>
              <span className="text-xs text-theme-secondary">
                Page {meta.current_page} of {meta.total_pages}
              </span>
              <Button
                onClick={() => setPage((p) => Math.min(meta.total_pages, p + 1))}
                disabled={page >= meta.total_pages}
                variant="secondary"
                size="sm"
              >
                Next
              </Button>
            </div>
          </div>
        )}
      </section>

      {selectedBatchId && (
        <BatchDetailModal
          batchId={selectedBatchId}
          onClose={() => setSelectedBatchId(null)}
          onCancelled={refresh}
        />
      )}
    </div>
  );
};

export default ModuleBuildsTab;
