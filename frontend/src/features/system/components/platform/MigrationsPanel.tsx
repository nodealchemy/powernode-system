import React, { useCallback, useEffect, useState } from 'react';
import {
  Move,
  AlertTriangle,
  X,
  RefreshCw,
  ArrowRightLeft,
  Copy as CopyIcon,
  Clock,
} from 'lucide-react';
import { platformMigrationsApi } from '../../services/api/platformMigrationsApi';
import type {
  MigrationDetail,
  MigrationOperation,
  MigrationStatus,
  MigrationSummary,
} from '../../types/migration.types';

/**
 * Read-only Migrations panel. Lists System::Migration rows with status
 * pills + lets the operator drill into plan_summary / conflict_log /
 * audit_log. Creation flow (compose → resolve conflicts → apply) ships
 * in a dedicated MigrationWizard slice; programmatic migrations
 * (Migration::PlanComposer → MigrationApplyJob) remain available.
 *
 * Plan reference: Decentralized Federation §F + §I + P5 + P7.4.
 */
export const MigrationsPanel: React.FC = () => {
  const [migrations, setMigrations] = useState<MigrationSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const fetchMigrations = useCallback(async () => {
    setError(null);
    try {
      const result = await platformMigrationsApi.list();
      setMigrations(result.migrations);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load migrations');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void fetchMigrations();
  }, [fetchMigrations]);

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Move className="w-5 h-5 text-theme-info" />
          <h2 className="font-semibold text-theme-primary">Migrations</h2>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${migrations.length} record${migrations.length === 1 ? '' : 's'}`}
          </span>
        </div>
        <button
          type="button"
          onClick={() => void fetchMigrations()}
          disabled={loading}
          className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
          title="Refresh"
        >
          <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
        </button>
      </header>

      {error && (
        <div className="p-3 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm">
          <AlertTriangle className="w-4 h-4 flex-shrink-0" />
          <span className="flex-1">{error}</span>
          <button type="button" onClick={() => setError(null)} className="p-1">
            <X className="w-3 h-3" />
          </button>
        </div>
      )}

      {!loading && migrations.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm space-y-2">
          <div>No migrations recorded yet.</div>
          <div className="text-xs text-theme-tertiary max-w-2xl mx-auto">
            The interactive wizard for composing a plan, surfacing conflicts, and
            one-clicking apply is the next slice. For now operators can compose +
            apply programmatically via <code className="font-mono">Migration::PlanComposer</code>
            + <code className="font-mono">MigrationApplyJob</code>; completed
            and in-flight migrations will appear here.
          </div>
        </div>
      )}

      {migrations.length > 0 && (
        <table className="w-full text-sm">
          <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
            <tr>
              <th className="text-left px-4 py-2 font-medium">Operation</th>
              <th className="text-left px-4 py-2 font-medium">Resource</th>
              <th className="text-left px-4 py-2 font-medium">Status</th>
              <th className="text-left px-4 py-2 font-medium">Dry Run</th>
              <th className="text-left px-4 py-2 font-medium">Steps</th>
              <th className="text-left px-4 py-2 font-medium">Created</th>
            </tr>
          </thead>
          <tbody>
            {migrations.map((m) => (
              <tr
                key={m.id}
                className="border-t border-theme cursor-pointer hover:bg-theme-surface-hover transition-colors"
                onClick={() => setSelectedId(m.id)}
              >
                <td className="px-4 py-3"><OperationBadge op={m.operation} /></td>
                <td className="px-4 py-3 text-xs">
                  <span className="font-mono text-theme-primary">{m.root_resource_kind}</span>
                  {m.root_resource_id && (
                    <span className="block text-theme-tertiary font-mono">{m.root_resource_id.slice(0, 8)}…</span>
                  )}
                </td>
                <td className="px-4 py-3"><StatusPill status={m.status} /></td>
                <td className="px-4 py-3 text-xs text-theme-secondary">
                  {m.dry_run ? <span className="text-theme-info">dry-run</span> : 'no'}
                </td>
                <td className="px-4 py-3 text-xs text-theme-secondary font-mono">
                  {m.step_count} / {m.total_steps}
                </td>
                <td className="px-4 py-3 text-xs text-theme-secondary">
                  <span className="inline-flex items-center gap-1">
                    <Clock className="w-3 h-3" />
                    {new Date(m.created_at).toLocaleString()}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <MigrationDetailDrawer
        migrationId={selectedId}
        onClose={() => setSelectedId(null)}
      />
    </div>
  );
};

const OPERATION_LABEL: Record<MigrationOperation, { icon: React.ReactNode; label: string }> = {
  duplicate: { icon: <CopyIcon className="w-3 h-3" />, label: 'duplicate' },
  migrate: { icon: <ArrowRightLeft className="w-3 h-3" />, label: 'migrate' },
};

const OperationBadge: React.FC<{ op: MigrationOperation }> = ({ op }) => {
  const c = OPERATION_LABEL[op];
  return (
    <span className="inline-flex items-center gap-1 px-2 py-0.5 bg-theme-background-secondary rounded text-xs font-mono">
      {c.icon}
      {c.label}
    </span>
  );
};

const StatusPill: React.FC<{ status: MigrationStatus }> = ({ status }) => {
  const styleByStatus: Record<MigrationStatus, string> = {
    planned: 'bg-theme-background-tertiary text-theme-secondary',
    validating: 'bg-theme-info text-theme-info',
    transferring: 'bg-theme-info text-theme-info',
    conflict: 'bg-theme-warning text-theme-warning',
    applying: 'bg-theme-info text-theme-info',
    completed: 'bg-theme-success text-theme-success',
    failed: 'bg-theme-danger text-theme-danger',
    cancelled: 'bg-theme-background-tertiary text-theme-secondary',
  };
  return (
    <span className={`inline-block px-2 py-0.5 rounded text-xs font-medium ${styleByStatus[status]}`}>
      {status}
    </span>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Detail drawer

interface MigrationDetailDrawerProps {
  migrationId: string | null;
  onClose: () => void;
}

const MigrationDetailDrawer: React.FC<MigrationDetailDrawerProps> = ({ migrationId, onClose }) => {
  const [migration, setMigration] = useState<MigrationDetail | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!migrationId) {
      setMigration(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    platformMigrationsApi
      .get(migrationId)
      .then((m) => {
        if (!cancelled) setMigration(m);
      })
      .catch((err: unknown) => {
        if (!cancelled) setError(err instanceof Error ? err.message : 'Failed to load migration');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [migrationId]);

  if (!migrationId) return null;

  return (
    <>
      <div className="fixed inset-0 bg-black/40 z-30" onClick={onClose} aria-hidden="true" />
      <aside className="fixed top-0 right-0 h-full w-full max-w-2xl bg-theme-surface border-l border-theme z-40 shadow-lg overflow-y-auto">
        <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3 sticky top-0 bg-theme-surface">
          <div className="flex items-center gap-2">
            <Move className="w-5 h-5 text-theme-info" />
            <h3 className="font-semibold text-theme-primary">Migration Detail</h3>
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
          <div className="p-3 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm">
            <AlertTriangle className="w-4 h-4 flex-shrink-0" />
            <span className="flex-1">{error}</span>
          </div>
        )}

        {loading && <div className="p-6 text-sm text-theme-secondary">Loading…</div>}

        {migration && (
          <div className="p-4 space-y-5">
            <section className="grid grid-cols-2 gap-3">
              <KV label="Operation" value={migration.operation} mono />
              <KV label="Status" value={migration.status} mono />
              <KV label="Resource Kind" value={migration.root_resource_kind} mono />
              <KV label="Resource ID" value={migration.root_resource_id ?? '—'} mono />
              <KV label="Destination Peer" value={migration.destination_peer_id ?? '—'} mono />
              <KV label="Dry Run" value={migration.dry_run ? 'yes' : 'no'} />
              <KV
                label="Steps"
                value={`${migration.step_count} / ${migration.total_steps}`}
                mono
              />
              <KV
                label="Created"
                value={new Date(migration.created_at).toLocaleString()}
              />
            </section>

            {migration.error_message && (
              <section className="p-3 bg-theme-danger text-theme-danger text-xs rounded">
                <div className="font-medium mb-1">Error</div>
                <div className="font-mono">{migration.error_message}</div>
              </section>
            )}

            <Collapsible title="Plan Summary" count={Object.keys(migration.plan_summary).length}>
              <pre className="text-xs bg-theme-background-secondary p-2 rounded overflow-x-auto font-mono text-theme-primary max-h-72">
                {JSON.stringify(migration.plan_summary, null, 2)}
              </pre>
            </Collapsible>

            <Collapsible title="Conflicts" count={migration.conflict_log.length}>
              {migration.conflict_log.length === 0 ? (
                <div className="text-xs text-theme-tertiary">No conflicts recorded.</div>
              ) : (
                <pre className="text-xs bg-theme-background-secondary p-2 rounded overflow-x-auto font-mono text-theme-primary max-h-72">
                  {JSON.stringify(migration.conflict_log, null, 2)}
                </pre>
              )}
            </Collapsible>

            <Collapsible title="Audit Log" count={migration.audit_log.length}>
              {migration.audit_log.length === 0 ? (
                <div className="text-xs text-theme-tertiary">No audit entries.</div>
              ) : (
                <ol className="space-y-1 text-xs">
                  {migration.audit_log.map((entry, idx) => (
                    <li key={idx} className="p-2 bg-theme-background-secondary rounded">
                      {entry.at && (
                        <span className="font-mono text-theme-tertiary mr-2">
                          {new Date(entry.at).toLocaleString()}
                        </span>
                      )}
                      <span className="font-mono text-theme-primary">{entry.event ?? '—'}</span>
                      {entry.message && (
                        <span className="text-theme-secondary ml-2">{entry.message}</span>
                      )}
                    </li>
                  ))}
                </ol>
              )}
            </Collapsible>
          </div>
        )}
      </aside>
    </>
  );
};

const KV: React.FC<{ label: string; value: string; mono?: boolean }> = ({ label, value, mono }) => (
  <div>
    <div className="text-xs text-theme-tertiary uppercase mb-0.5">{label}</div>
    <div className={`text-sm text-theme-primary ${mono ? 'font-mono break-all' : ''}`}>{value}</div>
  </div>
);

const Collapsible: React.FC<{ title: string; count: number; children: React.ReactNode }> = ({
  title,
  count,
  children,
}) => (
  <section>
    <div className="flex items-center justify-between mb-2">
      <div className="text-xs text-theme-tertiary uppercase">{title}</div>
      <span className="text-xs text-theme-secondary font-mono">{count}</span>
    </div>
    {children}
  </section>
);
