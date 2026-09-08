import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Link2,
  AlertTriangle,
  X,
  RefreshCw,
  Clock,
  ChevronsRight,
  FastForward,
  Ban,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { apiErrorMessage } from '../../services/api/helpers';
import { platformMigrationChainsApi } from '../../services/api/platformMigrationChainsApi';
import { MIGRATION_STATUS_STYLE, OperationBadge, StatusPill } from './MigrationsPanel';
import type {
  MigrationChainAuditEntry,
  MigrationChainDetail,
  MigrationChainHop,
  MigrationChainStatus,
  MigrationChainSummary,
} from '../../types/migrationChain.types';

/**
 * Multi-hop migration chains (P9.5) — list, detail drawer, and the three
 * operator actions the API has always exposed and no surface reached:
 * advance one hop, run to completion, cancel.
 *
 * A chain envelopes N-1 ordinary Migration rows. MigrationChainAdvanceJob
 * sweeps active chains every 60s, so the common case needs no operator at all
 * — this exists for the case the finding names, a chain STALLED between hops,
 * which was previously invisible and unrecoverable from the console.
 *
 * Plan reference: Decentralized Federation §F + P9.5.
 */
export const MigrationChainsPanel: React.FC = () => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const { confirm, close: closeConfirmation, ConfirmationDialog } = useConfirmation();
  const canApply = hasPermission('system.migrations.apply');
  const canCancel = hasPermission('system.migrations.cancel');

  const [chains, setChains] = useState<MigrationChainSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const fetchChains = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await platformMigrationChainsApi.list();
      setChains(result.migration_chains);
    } catch (err: unknown) {
      setError(apiErrorMessage(err, 'Failed to load migration chains'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void fetchChains();
  }, [fetchChains, refreshKey]);

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Link2 className="w-5 h-5 text-theme-info-fg" />
          <h2 className="font-semibold text-theme-primary">Migration Chains</h2>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${chains.length} chain${chains.length === 1 ? '' : 's'}`}
          </span>
        </div>
        <button
          type="button"
          onClick={() => setRefreshKey((k) => k + 1)}
          disabled={loading}
          className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
          title="Refresh"
        >
          <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
        </button>
      </header>

      {error && (
        <div className="p-3 bg-theme-danger-bg text-theme-danger-fg flex items-center gap-2 text-sm">
          <AlertTriangle className="w-4 h-4 flex-shrink-0" />
          <span className="flex-1">{error}</span>
          <button type="button" onClick={() => setError(null)} className="p-1">
            <X className="w-3 h-3" />
          </button>
        </div>
      )}

      {!loading && chains.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm space-y-2">
          <div>No migration chains yet.</div>
          <div className="text-xs text-theme-tertiary max-w-2xl mx-auto">
            A chain moves one resource across several peers in order, one hop at a time.
            The worker advances active chains on its own every 60 seconds; the controls
            here are for a chain that has stalled.
          </div>
        </div>
      )}

      {chains.length > 0 && (
        <table className="w-full text-sm">
          <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
            <tr>
              <th className="text-left px-4 py-2 font-medium">Operation</th>
              <th className="text-left px-4 py-2 font-medium">Resource</th>
              <th className="text-left px-4 py-2 font-medium">Status</th>
              <th className="text-left px-4 py-2 font-medium">Progress</th>
              <th className="text-left px-4 py-2 font-medium">Created</th>
            </tr>
          </thead>
          <tbody>
            {chains.map((c) => (
              <tr
                key={c.id}
                className="border-t border-theme cursor-pointer hover:bg-theme-surface-hover transition-colors"
                onClick={() => setSelectedId(c.id)}
                data-testid={`chain-row-${c.id}`}
              >
                <td className="px-4 py-3"><OperationBadge op={c.operation} /></td>
                <td className="px-4 py-3 text-xs">
                  <span className="font-mono text-theme-primary">{c.root_resource_kind}</span>
                  {c.root_resource_id && (
                    <span className="block text-theme-tertiary font-mono">
                      {c.root_resource_id.slice(0, 8)}…
                    </span>
                  )}
                </td>
                <td className="px-4 py-3"><ChainStatusPill status={c.status} /></td>
                <td className="px-4 py-3 text-xs text-theme-secondary">
                  <HopProgress
                    currentHopIndex={c.current_hop_index}
                    totalHops={c.total_hops}
                    status={c.status}
                  />
                </td>
                <td className="px-4 py-3 text-xs text-theme-secondary">
                  <span className="inline-flex items-center gap-1">
                    <Clock className="w-3 h-3" />
                    {c.created_at ? new Date(c.created_at).toLocaleString() : '—'}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <ChainDetailDrawer
        chainId={selectedId}
        canApply={canApply}
        canCancel={canCancel}
        confirm={confirm}
        closeConfirmation={closeConfirmation}
        addNotification={addNotification}
        onChanged={() => setRefreshKey((k) => k + 1)}
        onClose={() => setSelectedId(null)}
      />

      {ConfirmationDialog}
    </div>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Status + progress

/**
 * A chain's own lifecycle. Four of its five states are shared with the
 * migration lifecycle and reuse MIGRATION_STATUS_STYLE verbatim; `in_flight`
 * is chain-only and takes the same treatment the migration enum gives its
 * working states.
 */
const CHAIN_STATUS_STYLE: Record<MigrationChainStatus, string> = {
  planned: MIGRATION_STATUS_STYLE.planned,
  in_flight: MIGRATION_STATUS_STYLE.applying,
  completed: MIGRATION_STATUS_STYLE.completed,
  failed: MIGRATION_STATUS_STYLE.failed,
  cancelled: MIGRATION_STATUS_STYLE.cancelled,
};

export const ChainStatusPill: React.FC<{ status: MigrationChainStatus }> = ({ status }) => (
  <span
    className={`inline-block px-2 py-0.5 rounded text-xs font-medium ${CHAIN_STATUS_STYLE[status]}`}
  >
    {status}
  </span>
);

/**
 * current_hop_index is the position the chain is AT, so it doubles as the count
 * of hops already applied — the executor bumps it only after a hop succeeds,
 * and a completed chain carries total_hops. A FAILED chain carries K+1 when hop
 * K applied and K+1 did not, so this reads "K+1 of N" there too, which is the
 * number the operator needs to decide whether to retry the hop or abandon the
 * chain at its current destination.
 *
 * The clamp is defensive: the model validates 0..total_hops, so the bar is
 * pinned to a real fraction rather than trusting the column.
 */
const HopProgress: React.FC<{
  currentHopIndex: number;
  totalHops: number;
  status: MigrationChainStatus;
}> = ({ currentHopIndex, totalHops, status }) => {
  const done = Math.max(0, Math.min(currentHopIndex, totalHops));
  const pct = totalHops > 0 ? Math.round((done / totalHops) * 100) : 0;
  return (
    <div className="space-y-1 min-w-[7rem]">
      <span className="font-mono">
        {done} / {totalHops} hops
      </span>
      <div className="h-1.5 bg-theme-background-secondary rounded overflow-hidden">
        <div
          data-testid="hop-progress-bar"
          className={status === 'failed' ? 'h-full bg-theme-danger-bg' : 'h-full bg-theme-info-bg'}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Detail drawer

type ConfirmFn = ReturnType<typeof useConfirmation>['confirm'];
type NotifyFn = ReturnType<typeof useNotifications>['addNotification'];

interface ChainDetailDrawerProps {
  chainId: string | null;
  canApply: boolean;
  canCancel: boolean;
  confirm: ConfirmFn;
  closeConfirmation: () => void;
  addNotification: NotifyFn;
  onChanged: () => void;
  onClose: () => void;
}

const ChainDetailDrawer: React.FC<ChainDetailDrawerProps> = ({
  chainId,
  canApply,
  canCancel,
  confirm,
  closeConfirmation,
  addNotification,
  onChanged,
  onClose,
}) => {
  const [chain, setChain] = useState<MigrationChainDetail | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<'advance' | 'run' | 'cancel' | null>(null);

  // The id the drawer is currently showing. A refetch started for chain A can
  // resolve after the operator has switched to B, and setChain would then paint
  // A's detail under B's header.
  const currentIdRef = useRef<string | null>(chainId);
  currentIdRef.current = chainId;

  const fetchDetail = useCallback(async (id: string, isInitial: boolean) => {
    if (isInitial) {
      setLoading(true);
      setError(null);
    }
    try {
      const c = await platformMigrationChainsApi.get(id);
      if (currentIdRef.current === id) setChain(c);
    } catch (err: unknown) {
      if (isInitial && currentIdRef.current === id) {
        setError(apiErrorMessage(err, 'Failed to load chain'));
      }
    } finally {
      if (isInitial) setLoading(false);
    }
  }, []);

  useEffect(() => {
    // Drop any open confirmation on EVERY change of subject. This drawer
    // returns null when closed rather than unmounting, so the hook's state
    // outlives it and a cancel dialog opened for chain A would otherwise
    // survive a switch to B and act on A.
    closeConfirmation();
    // Clear on EVERY switch, not just on close. Leaving the previous chain's
    // body up while the next one loads would render its Actions section — gated
    // on the PREVIOUS chain's status — while the handlers already target the new
    // id, so one click would fire A's affordance at B.
    setChain(null);
    setBusy(null);
    setError(null);
    if (!chainId) return;
    void fetchDetail(chainId, true);
  }, [chainId, fetchDetail, closeConfirmation]);

  const runAction = useCallback(
    async (
      kind: 'advance' | 'run' | 'cancel',
      call: (id: string) => Promise<unknown>,
      success: string,
      failure: string,
    ) => {
      if (!chainId) return;
      setBusy(kind);
      try {
        await call(chainId);
        addNotification({ type: 'success', message: success });
      } catch (err: unknown) {
        // The chain executor's refusals ("chain is completed and cannot be
        // advanced", "Chain is cancelled and cannot be cancelled") are the only
        // explanation the operator gets, and axios's own .message would replace
        // them with the status code.
        addNotification({ type: 'error', message: apiErrorMessage(err, failure) });
      } finally {
        setBusy(null);
        // Refresh on BOTH paths. A failed advance is not a no-op: the executor's
        // fail_chain! writes error_message and moves the chain to `failed`, so
        // leaving the old detail up would show an in_flight chain with live
        // Advance / Run buttons and hide the error that explains what happened.
        await fetchDetail(chainId, false);
        onChanged();
      }
    },
    [chainId, addNotification, fetchDetail, onChanged],
  );

  const handleAdvance = useCallback(
    () =>
      runAction(
        'advance',
        (id) => platformMigrationChainsApi.advance(id),
        'Chain advanced one hop.',
        'Advance failed',
      ),
    [runAction],
  );

  const handleRun = useCallback(
    () =>
      runAction(
        'run',
        (id) => platformMigrationChainsApi.run(id),
        'Chain run finished — check the hops for where it landed.',
        'Run failed',
      ),
    [runAction],
  );

  const handleCancel = useCallback(() => {
    confirm({
      title: 'Cancel migration chain',
      message:
        'Cancelling is terminal: the chain cannot be resumed and any hops it has not ' +
        'reached will never run. Hops already applied on earlier peers are NOT rolled back.',
      confirmLabel: 'Cancel chain',
      cancelLabel: 'Keep chain',
      variant: 'danger',
      onConfirm: () =>
        runAction(
          'cancel',
          (id) => platformMigrationChainsApi.cancel(id),
          'Chain cancelled.',
          'Cancel failed',
        ),
    });
  }, [confirm, runAction]);

  if (!chainId) return null;

  // Mirrors System::MigrationChain::TRANSITIONS, which is the authority — NOT
  // the controller's header comment, which says "planned/in_flight → cancelled"
  // and is wrong. TRANSITIONS gives in_flight only completed|failed, and the
  // cancel action guards on can_transition_to?("cancelled"), so offering Cancel
  // on an in-flight chain would be a button that always 422s.
  //
  // advance / run are different: ChainExecutor refuses only on terminal?, so
  // both are live for planned and in_flight.
  const advanceable = chain ? chain.status === 'planned' || chain.status === 'in_flight' : false;
  const cancellable = chain ? chain.status === 'planned' : false;

  return (
    <>
      <div className="fixed inset-0 bg-black/40 z-30" onClick={onClose} aria-hidden="true" />
      <aside className="fixed top-0 right-0 h-full w-full max-w-lg bg-theme-surface border-l border-theme z-40 shadow-lg overflow-y-auto">
        <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3 sticky top-0 bg-theme-surface">
          <div className="flex items-center gap-2">
            <Link2 className="w-5 h-5 text-theme-info-fg" />
            <h3 className="font-semibold text-theme-primary">Migration Chain</h3>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors"
            aria-label="Close chain detail"
          >
            <X className="w-4 h-4" />
          </button>
        </header>

        {error && (
          <div className="p-3 bg-theme-danger-bg text-theme-danger-fg flex items-center gap-2 text-sm">
            <AlertTriangle className="w-4 h-4 flex-shrink-0" />
            <span className="flex-1">{error}</span>
          </div>
        )}

        {loading && <div className="p-6 text-sm text-theme-secondary">Loading…</div>}

        {chain && (
          <div className="p-4 space-y-5">
            <section className="grid grid-cols-2 gap-3">
              <KeyValue label="Status"><ChainStatusPill status={chain.status} /></KeyValue>
              <KeyValue label="Operation"><OperationBadge op={chain.operation} /></KeyValue>
              <KeyValue label="Resource">
                <span className="font-mono text-xs">{chain.root_resource_kind}</span>
              </KeyValue>
              <KeyValue label="Resource ID">
                <span className="font-mono text-xs break-all">{chain.root_resource_id ?? '—'}</span>
              </KeyValue>
            </section>

            <section>
              <div className="text-xs uppercase text-theme-tertiary mb-2">Progress</div>
              <HopProgress
                currentHopIndex={chain.current_hop_index}
                totalHops={chain.total_hops}
                status={chain.status}
              />
              {chain.error_message && (
                <div className="mt-2 text-xs text-theme-danger-fg flex items-start gap-2">
                  <AlertTriangle className="w-3 h-3 mt-0.5 flex-shrink-0" />
                  <span>{chain.error_message}</span>
                </div>
              )}
            </section>

            {(canApply || canCancel) && (advanceable || cancellable) && (
              <section className="space-y-2">
                <div className="text-xs uppercase text-theme-tertiary">Actions</div>
                <div className="flex flex-wrap gap-2">
                  {canApply && advanceable && (
                    <Button size="sm" variant="outline" disabled={busy !== null} onClick={handleAdvance}>
                      <ChevronsRight className="w-4 h-4" />
                      {busy === 'advance' ? 'Advancing…' : 'Advance one hop'}
                    </Button>
                  )}
                  {canApply && advanceable && (
                    <Button size="sm" variant="outline" disabled={busy !== null} onClick={handleRun}>
                      <FastForward className="w-4 h-4" />
                      {busy === 'run' ? 'Running…' : 'Run to completion'}
                    </Button>
                  )}
                  {canCancel && cancellable && (
                    <Button size="sm" variant="danger" disabled={busy !== null} onClick={handleCancel}>
                      <Ban className="w-4 h-4" />
                      {busy === 'cancel' ? 'Cancelling…' : 'Cancel chain'}
                    </Button>
                  )}
                </div>
                <p className="text-xs text-theme-tertiary">
                  The worker advances active chains every 60 seconds on its own. Run to
                  completion is synchronous on the server and is meant for short chains.
                  {chain.status === 'in_flight' && (
                    <>
                      {' '}An in-flight chain cannot be cancelled — it can only run to
                      completion or fail.
                    </>
                  )}
                </p>
              </section>
            )}

            <section>
              <div className="text-xs uppercase text-theme-tertiary mb-2">
                Hops ({chain.hops.length})
              </div>
              {chain.hops.length === 0 ? (
                <div className="text-xs text-theme-tertiary">No hop rows.</div>
              ) : (
                <ol className="space-y-2">
                  {chain.hops.map((hop) => (
                    <HopRow
                      key={hop.id}
                      hop={hop}
                      isCurrent={hop.chain_position === chain.current_hop_index}
                    />
                  ))}
                </ol>
              )}
            </section>

            <section>
              <div className="text-xs uppercase text-theme-tertiary mb-2">Audit log</div>
              {chain.audit_log.length === 0 ? (
                <div className="text-xs text-theme-tertiary">No entries.</div>
              ) : (
                <ol className="space-y-2">
                  {chain.audit_log.map((entry, i) => (
                    <AuditEntry key={i} entry={entry} />
                  ))}
                </ol>
              )}
            </section>
          </div>
        )}
      </aside>
    </>
  );
};

const KeyValue: React.FC<{ label: string; children: React.ReactNode }> = ({ label, children }) => (
  <div>
    <div className="text-xs text-theme-tertiary uppercase mb-0.5">{label}</div>
    <div className="text-sm text-theme-primary">{children}</div>
  </div>
);

/**
 * The hop's destination comes from the hop row itself, NOT from indexing the
 * chain's hop_peer_ids by chain_position. Those two are off by one on purpose:
 * ChainComposer creates a row per DESTINATION, with `chain_position: idx - 1`
 * and `destination_peer_id: hop_peer_ids[idx]`, so hop P goes to
 * hop_peer_ids[P + 1]. Indexing by position would name each hop's SOURCE, and
 * would never show the final destination at all. There is no row for the
 * origin — it is a peer in the list, not a hop.
 */
const HopRow: React.FC<{ hop: MigrationChainHop; isCurrent: boolean }> = ({
  hop,
  isCurrent,
}) => (
  <li
    className={`text-xs border-l-2 pl-3 py-1 ${
      isCurrent ? 'border-theme-info-fg' : 'border-theme'
    }`}
    data-testid={`chain-hop-${hop.chain_position}`}
  >
    <div className="flex items-center gap-2">
      <span className="font-mono text-theme-secondary">#{hop.chain_position}</span>
      <StatusPill status={hop.status} />
      {isCurrent && <span className="text-theme-info-fg">current</span>}
    </div>
    <div className="mt-1 text-theme-secondary">
      <span className="text-theme-tertiary">to </span>
      <span className="font-mono">{hop.destination_peer_id ?? '—'}</span>
    </div>
    {hop.error_message && (
      <div className="mt-1 text-theme-danger-fg">{hop.error_message}</div>
    )}
  </li>
);

const AuditEntry: React.FC<{ entry: MigrationChainAuditEntry }> = ({ entry }) => (
  <li className="text-xs border-l-2 border-theme pl-3 py-1">
    <div className="flex items-center gap-2 text-theme-secondary">
      <Clock className="w-3 h-3 flex-shrink-0" />
      <span className="tabular-nums">{entry.at ? new Date(entry.at).toLocaleString() : '—'}</span>
      {entry.event && <span className="font-mono text-theme-primary">{entry.event}</span>}
    </div>
    {entry.message && <div className="mt-1 text-theme-primary">{entry.message}</div>}
  </li>
);
