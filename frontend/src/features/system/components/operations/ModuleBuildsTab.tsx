import React, { useCallback, useEffect, useState } from 'react';
import { Hammer } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useAuth } from '@/shared/hooks/useAuth';
import { wsManager } from '@/shared/services/WebSocketManager';
import { moduleBuildsApi } from '@system/features/system/services/api/moduleBuildsApi';
import { BatchList } from './BatchList';
import { BatchDetailModal } from './BatchDetailModal';
import type { SystemModuleBuildBatch } from '@system/features/system/types/system.types';

interface ModuleBuildsTabProps {
  onActionsReady?: (handle: { refresh: () => void } | null) => void;
}

// While any listed batch is still active, poll for updates — batches move
// through their AASM ladder server-side (dispatch → sign → publish →
// complete/partial/fail) with no operator action in between, so this is the
// only way the list picks up progress without a manual refresh.
const POLL_INTERVAL_MS = 12_000;

/**
 * Module Builds tab (campaign 019f6084 inc5) — operator view over
 * System::ModuleBuildBatch, the agent-pollable build-completion barrier for
 * both platform module builds (push/manual/cve) and on-demand
 * package-closure builds (trigger "package"; routed through the same batch
 * by System::PackageClosureBuildBridge as of inc2-B). Read-only: dispatch
 * stays worker/webhook-gated (system.module_builds.dispatch) — a Phase-2
 * "Trigger build" action is out of scope here.
 */
export const ModuleBuildsTab: React.FC<ModuleBuildsTabProps> = ({ onActionsReady }) => {
  const { addNotification } = useNotifications();
  const { currentUser } = useAuth();
  const accountId = (currentUser as { account?: { id?: string } } | null)?.account?.id;

  const [batches, setBatches] = useState<SystemModuleBuildBatch[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedBatchId, setSelectedBatchId] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const result = await moduleBuildsApi.list();
      setBatches(result.module_build_batches);
    } catch (e) {
      addNotification({
        type: 'error',
        message: e instanceof Error ? e.message : 'Failed to load module build batches',
      });
    } finally {
      setLoading(false);
    }
  }, [addNotification]);

  useEffect(() => { void refresh(); }, [refresh]);

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
  useEffect(() => {
    if (!accountId) return;
    const unsubscribe = wsManager.subscribe({
      channel: 'SystemFleetChannel',
      params: { account_id: accountId },
      onMessage: (data: unknown) => {
        const msg = data as { kind?: string };
        if (msg?.kind?.startsWith('system.module_build')) {
          void refresh();
        }
      },
      onError: () => {},
    });
    return () => unsubscribe();
  }, [accountId, refresh]);

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
        <header className="px-4 py-3 border-b border-theme flex items-center gap-2">
          <Hammer size={16} className="text-theme-info-fg" />
          <h2 className="font-medium text-theme-primary">Build batches</h2>
          {batches.length > 0 && (
            <Badge variant="info" size="xs">{batches.length}</Badge>
          )}
        </header>
        <div className="p-2">
          {loading && batches.length === 0 ? (
            <p className="text-sm text-theme-tertiary p-3">Loading…</p>
          ) : batches.length === 0 ? (
            <p className="text-sm text-theme-secondary p-3">
              No module build batches yet. Push a module change, or trigger a
              package build, to see it appear here.
            </p>
          ) : (
            <BatchList batches={batches} onSelect={setSelectedBatchId} />
          )}
        </div>
      </section>

      {selectedBatchId && (
        <BatchDetailModal batchId={selectedBatchId} onClose={() => setSelectedBatchId(null)} />
      )}
    </div>
  );
};

export default ModuleBuildsTab;
