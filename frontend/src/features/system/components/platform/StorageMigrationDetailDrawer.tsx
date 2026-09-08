import React, { useCallback, useEffect, useRef, useState } from 'react';
import { X, Database, AlertTriangle, Clock, Undo2, Trash2 } from 'lucide-react';
import { EntityLink } from '@/shared/components/entity';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useReasonConfirm } from '../../hooks/useReasonConfirm';
import { apiErrorMessage, isPendingApproval } from '../../services/api/helpers';
import { pendingApprovalNotice } from '../../utils/pendingApproval';
import { storageMigrationsApi } from '../../services/api/storageMigrationsApi';
import type {
  StorageMigrationDetail,
  StorageMigrationAuditEntry,
} from '../../types/storageMigration.types';

const TERMINAL: ReadonlyArray<string> = ['completed', 'failed', 'cancelled'];

/**
 * ActiveModel::Type::Boolean's falsy set, so a client-side mirror of a Ruby
 * guard agrees with it. Plain `Boolean(...)` does not: metadata is a free-form
 * JSON column, and `Boolean("false")` is true while Rails casts it to false —
 * which would render a control the backend then refuses.
 */
const RAILS_FALSE = new Set(['', 'false', 'f', '0', 'off', 'no', 'n']);

function castBoolean(value: unknown): boolean {
  if (value === null || value === undefined || value === false) return false;
  if (typeof value === 'string') return !RAILS_FALSE.has(value.trim().toLowerCase());
  if (typeof value === 'number') return value !== 0;
  return Boolean(value);
}

/**
 * Client-side mirrors of System::StorageMigration#can_revert_binding? and
 * #can_cleanup?. They decide only whether to RENDER the control — the backend
 * re-validates both and 422s on anything it will not do, so drift here costs a
 * useless button, never an unauthorized action.
 *
 * Both also refuse once a request is already in flight. The model has NO
 * re-entry guard: request_cleanup! re-runs happily, and cleanup leaves the
 * status at `failed`, so without this the drawer would keep offering to delete
 * target-side artifacts that a previous click already asked the agent to
 * delete. `metadata.<action>_status` is the model's own record of that
 * (requested → completed / failed).
 */
function revertRequested(m: StorageMigrationDetail): boolean {
  return m.metadata?.revert_status === 'requested';
}

function cleanupRequested(m: StorageMigrationDetail): boolean {
  return m.metadata?.cleanup_status === 'requested';
}

function canRevert(m: StorageMigrationDetail): boolean {
  if (revertRequested(m)) return false;
  if (m.status === 'failed') return true;
  return m.status === 'completed' && castBoolean(m.metadata?.promote_failed);
}

function canCleanup(m: StorageMigrationDetail): boolean {
  if (cleanupRequested(m)) return false;
  if (m.status === 'failed') return true;
  return m.status === 'cancelled' && Boolean(m.started_at);
}

/**
 * Slide-out drawer showing the full storage-migration detail: the
 * agent_contract plan, byte counts, full audit log timeline, and
 * per-volume subpath bindings.
 *
 * Plan reference: E8 follow-on (operator UI / detail drawer).
 */

interface StorageMigrationDetailDrawerProps {
  migrationId: string | null;
  onClose: () => void;
}

export const StorageMigrationDetailDrawer: React.FC<StorageMigrationDetailDrawerProps> = ({
  migrationId,
  onClose,
}) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const { confirmWithReason, close: closeConfirmation, ConfirmationDialog } = useReasonConfirm();
  const canScale = hasPermission('system.platform.scale');
  const [migration, setMigration] = useState<StorageMigrationDetail | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Written by the uncontrolled checkbox in the cleanup dialog's body, read
  // once on confirm. A ref, not state, because useConfirmation snapshots the
  // message element: a controlled checkbox driven from here would never move.
  // Uncontrolled means the DOM shows the operator's click without a re-render.
  const immediateRef = useRef(false);

  const fetchDetail = useCallback(
    async (id: string, isInitial: boolean) => {
      if (isInitial) {
        setLoading(true);
        setError(null);
      }
      try {
        const m = await storageMigrationsApi.get(id);
        setMigration(m);
      } catch (err: unknown) {
        if (isInitial) {
          setError(err instanceof Error ? err.message : 'Failed to load migration');
        }
      } finally {
        if (isInitial) setLoading(false);
      }
    },
    [],
  );

  useEffect(() => {
    // Drop any open confirmation on EVERY change of subject, not just on
    // close. The drawer returns null when closed rather than unmounting, so
    // useReasonConfirm's state outlives it — and its onConfirm closed over the
    // migration id from the render that opened it. Left alone, a dialog opened
    // for migration A survives a switch to B and would act on A while the
    // drawer displays B.
    closeConfirmation();
    if (!migrationId) {
      setMigration(null);
      return;
    }
    void fetchDetail(migrationId, true);
  }, [migrationId, fetchDetail, closeConfirmation]);

  // Auto-refresh while non-terminal. Stops when status reaches a
  // terminal state so the audit log freezes naturally.
  useEffect(() => {
    if (!migrationId || !migration) return undefined;
    if (TERMINAL.includes(migration.status)) return undefined;
    const interval = window.setInterval(() => {
      void fetchDetail(migrationId, false);
    }, 5_000);
    return () => window.clearInterval(interval);
  }, [migrationId, migration, fetchDetail]);

  const handleRevert = useCallback(() => {
    if (!migrationId) return;
    confirmWithReason({
      title: 'Revert binding to source',
      message:
        'Ask the on-node agent to re-point the canonical mount back to the source volume. ' +
        'The target volume is left in place — this only moves the binding.',
      confirmLabel: 'Revert binding',
      cancelLabel: 'Leave as is',
      variant: 'warning',
      reasonPlaceholder: 'Why is this binding being reverted?',
      onConfirm: async (reason) => {
        try {
          const result = await storageMigrationsApi.revert(migrationId, reason);
          if (isPendingApproval(result)) {
            addNotification(pendingApprovalNotice('reverting the storage binding', result));
            return;
          }
          addNotification({
            type: 'success',
            message: 'Revert requested — the agent picks it up on its next tick.',
          });
          await fetchDetail(migrationId, false);
        } catch (err: unknown) {
          addNotification({ type: 'error', message: apiErrorMessage(err, 'Revert failed') });
        }
      },
    });
  }, [migrationId, confirmWithReason, addNotification, fetchDetail]);

  const handleCleanup = useCallback(() => {
    if (!migrationId) return;
    // Reset per dialog: the ref outlives any single confirmation, so without
    // this an override ticked into a cancelled dialog would apply to the next.
    immediateRef.current = false;
    confirmWithReason({
      title: 'Clean up target-side artifacts',
      message: (
        <div className="space-y-3">
          <p>
            DESTRUCTIVE and irreversible: deletes the target-side scratch artifacts under
            this migration&apos;s target subpath. Nothing on the source is touched. The
            platform never runs this automatically on failure — it is an explicit operator
            action, and the reason you give here is what lands in the audit log.
          </p>
          <label className="flex items-start gap-2 text-sm text-theme-secondary">
            <input
              type="checkbox"
              onChange={(e) => {
                immediateRef.current = e.target.checked;
              }}
              className="mt-0.5 w-4 h-4 rounded border-theme bg-theme-surface"
            />
            <span>
              Skip the cleanup grace window.
              <span className="block text-xs text-theme-tertiary">
                Cleanup is otherwise held for a grace period after the migration failed or
                was cancelled (24 hours unless this account overrides it), and the request
                is refused until it elapses.
              </span>
            </span>
          </label>
        </div>
      ),
      confirmLabel: 'Delete target artifacts',
      cancelLabel: 'Keep artifacts',
      variant: 'danger',
      reasonRequired: true,
      reasonPlaceholder: 'Why are these artifacts being deleted?',
      onConfirm: async (reason) => {
        // reasonRequired keeps the confirm button disabled while the reason is
        // blank, so `reason` is defined here by the hook's contract; the `??`
        // is a type-level formality, not a guess about operator behaviour.
        try {
          const result = await storageMigrationsApi.cleanup(migrationId, {
            reason: reason ?? '',
            immediate: immediateRef.current,
          });
          if (isPendingApproval(result)) {
            addNotification(pendingApprovalNotice('cleaning up the migration target', result));
            return;
          }
          addNotification({
            type: 'success',
            message: 'Cleanup requested — the agent removes the target-side artifacts.',
          });
          await fetchDetail(migrationId, false);
        } catch (err: unknown) {
          addNotification({ type: 'error', message: apiErrorMessage(err, 'Cleanup failed') });
        }
      },
    });
  }, [migrationId, confirmWithReason, addNotification, fetchDetail]);

  if (!migrationId) return null;

  return (
    <>
      <div
        className="fixed inset-0 bg-black/40 z-30"
        onClick={onClose}
        aria-hidden="true"
      />
      <aside className="fixed top-0 right-0 h-full w-full max-w-lg bg-theme-surface border-l border-theme z-40 shadow-lg overflow-y-auto">
        <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3 sticky top-0 bg-theme-surface">
          <div className="flex items-center gap-2">
            <Database className="w-5 h-5 text-theme-info-fg" />
            <h3 className="font-semibold text-theme-primary">Storage Migration</h3>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors"
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

        {migration && (
          <div className="p-4 space-y-5">
            <section className="grid grid-cols-2 gap-3">
              <KeyValue label="Status" value={migration.status} mono />
              <KeyValue label="Role" value={migration.role} mono />
              <LinkedValue
                label="Source Volume"
                type="provider_volume"
                id={migration.source_volume_id}
                label2={migration.source_volume_id.slice(0, 8) + '…'}
              />
              <LinkedValue
                label="Target Volume"
                type="provider_volume"
                id={migration.target_volume_id}
                label2={migration.target_volume_id.slice(0, 8) + '…'}
              />
              <KeyValue label="Source Subpath" value={migration.source_subpath ?? '—'} mono />
              <KeyValue label="Target Subpath" value={migration.target_subpath ?? '—'} mono />
            </section>

            <section>
              <div className="text-xs uppercase text-theme-tertiary mb-2">Progress</div>
              <ByteCounters
                copied={migration.bytes_copied}
                total={migration.bytes_total}
                verified={migration.bytes_verified ?? null}
              />
            </section>

            <section className="space-y-2">
              <div className="text-xs uppercase text-theme-tertiary">Lifecycle</div>
              <div className="grid grid-cols-2 gap-2 text-xs">
                <Stamp label="Created"    iso={migration.created_at} />
                <Stamp label="Approved"   iso={migration.approved_at} />
                <Stamp label="Started"    iso={migration.started_at} />
                <Stamp label="Completed"  iso={migration.completed_at} />
                <Stamp label="Failed"     iso={migration.failed_at} />
                <Stamp label="Cancelled"  iso={migration.cancelled_at} />
              </div>
              {migration.error_message && (
                <div className="mt-2 text-xs text-theme-danger-fg flex items-start gap-2">
                  <AlertTriangle className="w-3 h-3 mt-0.5 flex-shrink-0" />
                  <span>{migration.error_message}</span>
                </div>
              )}
            </section>

            <section>
              <div className="text-xs uppercase text-theme-tertiary mb-2">Plan</div>
              <pre className="bg-theme-background-secondary rounded p-3 text-xs font-mono text-theme-secondary overflow-x-auto max-h-48 overflow-y-auto">
                {JSON.stringify(migration.plan, null, 2)}
              </pre>
            </section>

            {canScale &&
              (canRevert(migration) ||
                canCleanup(migration) ||
                revertRequested(migration) ||
                cleanupRequested(migration)) && (
                <section className="space-y-2">
                  <div className="text-xs uppercase text-theme-tertiary">Recovery</div>
                  <div className="flex flex-wrap gap-2">
                    {canRevert(migration) && (
                      <Button size="sm" variant="outline" onClick={handleRevert}>
                        <Undo2 className="w-4 h-4" />
                        Revert to source
                      </Button>
                    )}
                    {canCleanup(migration) && (
                      <Button size="sm" variant="danger" onClick={handleCleanup}>
                        <Trash2 className="w-4 h-4" />
                        Clean up target
                      </Button>
                    )}
                  </div>
                  {revertRequested(migration) && (
                    <p className="text-xs text-theme-secondary">
                      Revert requested — waiting for the agent to report the mount is back
                      on source.
                    </p>
                  )}
                  {cleanupRequested(migration) && (
                    <p className="text-xs text-theme-secondary">
                      Cleanup requested — waiting for the agent to report the target-side
                      artifacts are gone.
                    </p>
                  )}
                  {(canRevert(migration) || canCleanup(migration)) && (
                    <p className="text-xs text-theme-tertiary">
                      Revert moves the canonical mount back to source. Cleanup deletes the
                      target-side scratch artifacts and cannot be undone.
                    </p>
                  )}
                </section>
              )}

            <section>
              <div className="text-xs uppercase text-theme-tertiary mb-2">Audit log</div>
              {migration.audit_log.length === 0 ? (
                <div className="text-xs text-theme-tertiary">No entries.</div>
              ) : (
                <ol className="space-y-2">
                  {migration.audit_log.map((entry, i) => (
                    <AuditEntry key={i} entry={entry} />
                  ))}
                </ol>
              )}
            </section>
          </div>
        )}
      </aside>

      {ConfirmationDialog}
    </>
  );
};

const KeyValue: React.FC<{ label: string; value: string; mono?: boolean }> = ({
  label,
  value,
  mono,
}) => (
  <div>
    <div className="text-xs text-theme-tertiary uppercase mb-0.5">{label}</div>
    <div className={`text-sm text-theme-primary ${mono ? 'font-mono' : ''}`}>{value}</div>
  </div>
);

/**
 * Labeled cross-reference value mirroring KeyValue's layout but rendering the
 * value as an <EntityLink> (degrades to plain mono text when the type is
 * unregistered, the id is missing, or the viewer lacks the read permission).
 */
const LinkedValue: React.FC<{ label: string; type: string; id: string; label2: string }> = ({
  label,
  type,
  id,
  label2,
}) => (
  <div>
    <div className="text-xs text-theme-tertiary uppercase mb-0.5">{label}</div>
    <div className="text-sm font-mono">
      <EntityLink type={type} id={id} label={label2} className="text-theme-primary" />
    </div>
  </div>
);

const Stamp: React.FC<{ label: string; iso: string | null }> = ({ label, iso }) => (
  <div className="flex items-center gap-2 text-theme-secondary">
    <span className="text-theme-tertiary uppercase text-[10px] w-16">{label}</span>
    <span className="tabular-nums">{iso ? new Date(iso).toLocaleString() : '—'}</span>
  </div>
);

const ByteCounters: React.FC<{
  copied: number | null;
  total: number | null;
  verified: number | null;
}> = ({ copied, total, verified }) => {
  const fmt = (n: number | null) =>
    n === null || n === undefined ? '—' : `${(n / (1024 * 1024)).toFixed(1)} MB`;
  const pct =
    total && total > 0 && copied !== null
      ? Math.min(100, Math.round((copied / total) * 100))
      : null;
  return (
    <div className="space-y-2 text-sm">
      <div className="flex gap-4">
        <span>
          <span className="text-theme-tertiary text-xs uppercase mr-1">Copied:</span>
          <span className="tabular-nums">{fmt(copied)}</span>
        </span>
        <span>
          <span className="text-theme-tertiary text-xs uppercase mr-1">Total:</span>
          <span className="tabular-nums">{fmt(total)}</span>
        </span>
        <span>
          <span className="text-theme-tertiary text-xs uppercase mr-1">Verified:</span>
          <span className="tabular-nums">{fmt(verified)}</span>
        </span>
      </div>
      {pct !== null && (
        <div className="flex items-center gap-2">
          <div className="flex-1 h-2 bg-theme-background-secondary rounded overflow-hidden">
            <div className="h-full bg-theme-info-bg" style={{ width: `${pct}%` }} />
          </div>
          <span className="text-xs text-theme-secondary tabular-nums w-10 text-right">{pct}%</span>
        </div>
      )}
    </div>
  );
};

const AuditEntry: React.FC<{ entry: StorageMigrationAuditEntry }> = ({ entry }) => {
  const transition =
    entry.status_before && entry.status_after
      ? `${entry.status_before} → ${entry.status_after}`
      : null;
  return (
    <li className="text-xs border-l-2 border-theme pl-3 py-1">
      <div className="flex items-center gap-2 text-theme-secondary">
        <Clock className="w-3 h-3 flex-shrink-0" />
        <span className="tabular-nums">
          {entry.at ? new Date(entry.at).toLocaleString() : '—'}
        </span>
        {transition && (
          <span className="font-mono text-theme-primary">{transition}</span>
        )}
      </div>
      {entry.message && (
        <div className="mt-1 text-theme-primary">{entry.message}</div>
      )}
      {entry.details && Object.keys(entry.details).length > 0 && (
        <pre className="mt-1 bg-theme-background-secondary rounded p-2 text-[10px] font-mono text-theme-tertiary overflow-x-auto">
          {JSON.stringify(entry.details, null, 2)}
        </pre>
      )}
    </li>
  );
};
