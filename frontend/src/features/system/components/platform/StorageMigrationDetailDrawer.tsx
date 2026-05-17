import React, { useCallback, useEffect, useState } from 'react';
import { X, Database, AlertTriangle, Clock } from 'lucide-react';
import { storageMigrationsApi } from '../../services/api/storageMigrationsApi';
import type {
  StorageMigrationDetail,
  StorageMigrationAuditEntry,
} from '../../types/storageMigration.types';

const TERMINAL: ReadonlyArray<string> = ['completed', 'failed', 'cancelled'];

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
  const [migration, setMigration] = useState<StorageMigrationDetail | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

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
    if (!migrationId) {
      setMigration(null);
      return;
    }
    void fetchDetail(migrationId, true);
  }, [migrationId, fetchDetail]);

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
            <Database className="w-5 h-5 text-theme-info" />
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
          <div className="p-3 bg-theme-danger/10 text-theme-danger flex items-center gap-2 text-sm">
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
              <KeyValue
                label="Source Volume"
                value={migration.source_volume_id.slice(0, 8) + '…'}
                mono
              />
              <KeyValue
                label="Target Volume"
                value={migration.target_volume_id.slice(0, 8) + '…'}
                mono
              />
              <KeyValue label="Source Subpath" value={migration.source_subpath ?? '—'} mono />
              <KeyValue label="Target Subpath" value={migration.target_subpath ?? '—'} mono />
            </section>

            <section>
              <div className="text-xs uppercase text-theme-tertiary mb-2">Progress</div>
              <ByteCounters
                copied={migration.bytes_copied}
                total={migration.bytes_total}
                verified={migration.bytes_verified}
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
                <div className="mt-2 text-xs text-theme-danger flex items-start gap-2">
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
            <div className="h-full bg-theme-info" style={{ width: `${pct}%` }} />
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
