import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Database,
  AlertTriangle,
  X,
  RefreshCw,
  CheckCircle2,
  XCircle,
  Clock,
  Plus,
} from 'lucide-react';
import { storageMigrationsApi } from '../../services/api/storageMigrationsApi';
import type {
  StorageMigrationStatus,
  StorageMigrationSummary,
} from '../../types/storageMigration.types';
import { PlanStorageMigrationModal } from './PlanStorageMigrationModal';
import { StorageMigrationDetailDrawer } from './StorageMigrationDetailDrawer';

/**
 * Operator-facing storage migrations panel. Lists all
 * System::StorageMigration rows for the account with approve/cancel
 * controls for non-terminal migrations.
 *
 * The Plan-a-migration wizard (volume picker, role selector) is a
 * follow-on slice — operators currently plan via MCP
 * (`system_migrate_storage_component`) or the platform deployment
 * wizard's volume selector. This panel covers the lifecycle of
 * already-planned migrations.
 *
 * Plan reference: E8 follow-on (operator UI).
 */
export const StorageMigrationsPanel: React.FC = () => {
  const [migrations, setMigrations] = useState<StorageMigrationSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionPending, setActionPending] = useState<string | null>(null);
  const [planOpen, setPlanOpen] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const fetchMigrations = useCallback(async () => {
    setError(null);
    try {
      const result = await storageMigrationsApi.list();
      setMigrations(result.storage_migrations);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load storage migrations');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void fetchMigrations();
  }, [fetchMigrations]);

  // Auto-refresh while any non-terminal migration is in flight.
  // Stops polling once everything reaches completed/failed/cancelled,
  // so an idle panel doesn't burn requests in the background.
  useEffect(() => {
    const hasActive = migrations.some((m) => !m.terminal);
    if (!hasActive) return undefined;
    const interval = window.setInterval(() => {
      void fetchMigrations();
    }, 10_000);
    return () => window.clearInterval(interval);
  }, [migrations, fetchMigrations]);

  const handleApprove = useCallback(
    async (id: string) => {
      setActionPending(id);
      setError(null);
      try {
        await storageMigrationsApi.approve(id);
        await fetchMigrations();
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : 'Approve failed');
      } finally {
        setActionPending(null);
      }
    },
    [fetchMigrations],
  );

  const handleCancel = useCallback(
    async (id: string) => {
      const reason = window.prompt('Cancel reason (optional)') ?? undefined;
      setActionPending(id);
      setError(null);
      try {
        await storageMigrationsApi.cancel(id, reason);
        await fetchMigrations();
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : 'Cancel failed');
      } finally {
        setActionPending(null);
      }
    },
    [fetchMigrations],
  );

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Database className="w-5 h-5 text-theme-info" />
          <h2 className="font-semibold text-theme-primary">Storage Migrations</h2>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${migrations.length} record${migrations.length === 1 ? '' : 's'}`}
          </span>
        </div>
        <div className="flex items-center gap-1">
          <button
            type="button"
            onClick={() => setPlanOpen(true)}
            className="px-2 py-1 text-xs rounded bg-theme-info text-theme-info hover:opacity-80 inline-flex items-center gap-1"
          >
            <Plus className="w-3 h-3" /> Plan
          </button>
          <button
            type="button"
            onClick={() => void fetchMigrations()}
            disabled={loading}
            className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
            title="Refresh"
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
          </button>
        </div>
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
          <div>No storage migrations recorded yet.</div>
          <div className="text-xs text-theme-tertiary max-w-2xl mx-auto">
            Storage migrations move a stateful component's data between volumes
            on a single instance — e.g. switching the Postgres data directory
            from one NFS pool to another. Plan one via the MCP action
            <code className="font-mono mx-1">system_migrate_storage_component</code>
            or from the platform deployment wizard.
          </div>
        </div>
      )}

      {migrations.length > 0 && (
        <table className="w-full text-sm">
          <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
            <tr>
              <th className="text-left px-4 py-2 font-medium">Role</th>
              <th className="text-left px-4 py-2 font-medium">Source → Target</th>
              <th className="text-left px-4 py-2 font-medium">Status</th>
              <th className="text-left px-4 py-2 font-medium">Progress</th>
              <th className="text-left px-4 py-2 font-medium">Created</th>
              <th className="text-right px-4 py-2 font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {migrations.map((m) => (
              <MigrationRow
                key={m.id}
                migration={m}
                pending={actionPending === m.id}
                onApprove={() => void handleApprove(m.id)}
                onCancel={() => void handleCancel(m.id)}
                onOpen={() => setSelectedId(m.id)}
              />
            ))}
          </tbody>
        </table>
      )}

      <PlanStorageMigrationModal
        isOpen={planOpen}
        onClose={() => setPlanOpen(false)}
        onPlanned={() => void fetchMigrations()}
      />
      <StorageMigrationDetailDrawer
        migrationId={selectedId}
        onClose={() => setSelectedId(null)}
      />
    </div>
  );
};

interface MigrationRowProps {
  migration: StorageMigrationSummary;
  pending: boolean;
  onApprove: () => void;
  onCancel: () => void;
  onOpen: () => void;
}

const MigrationRow: React.FC<MigrationRowProps> = ({
  migration,
  pending,
  onApprove,
  onCancel,
  onOpen,
}) => {
  const canApprove = migration.status === 'planned';
  const canCancel = ['planned', 'approved', 'preparing'].includes(migration.status);
  const progressPct = useMemo(() => {
    if (!migration.bytes_total || migration.bytes_total === 0) return null;
    const copied = migration.bytes_copied ?? 0;
    return Math.min(100, Math.round((copied / migration.bytes_total) * 100));
  }, [migration.bytes_copied, migration.bytes_total]);

  return (
    <tr
      className="border-t border-theme hover:bg-theme-surface-hover transition-colors cursor-pointer"
      onClick={onOpen}
    >
      <td className="px-4 py-3">
        <span className="font-mono text-theme-primary text-xs">{migration.role}</span>
      </td>
      <td className="px-4 py-3 text-xs text-theme-secondary">
        <span className="font-mono">{migration.source_volume_id.slice(0, 8)}</span>
        <span className="mx-2 text-theme-tertiary">→</span>
        <span className="font-mono">{migration.target_volume_id.slice(0, 8)}</span>
      </td>
      <td className="px-4 py-3"><StatusPill status={migration.status} /></td>
      <td className="px-4 py-3 text-xs">
        {progressPct !== null ? (
          <div className="flex items-center gap-2">
            <div className="flex-1 h-2 bg-theme-background-secondary rounded overflow-hidden min-w-[60px]">
              <div className="h-full bg-theme-info" style={{ width: `${progressPct}%` }} />
            </div>
            <span className="text-theme-secondary tabular-nums w-10 text-right">{progressPct}%</span>
          </div>
        ) : (
          <span className="text-theme-tertiary">—</span>
        )}
      </td>
      <td className="px-4 py-3 text-xs text-theme-secondary tabular-nums">
        {new Date(migration.created_at).toLocaleString()}
      </td>
      <td className="px-4 py-3 text-right" onClick={(e) => e.stopPropagation()}>
        <div className="inline-flex gap-2">
          {canApprove && (
            <button
              type="button"
              onClick={onApprove}
              disabled={pending}
              className="px-2 py-1 text-xs rounded bg-theme-success text-theme-success hover:opacity-80 disabled:opacity-40 inline-flex items-center gap-1"
            >
              <CheckCircle2 className="w-3 h-3" /> Approve
            </button>
          )}
          {canCancel && (
            <button
              type="button"
              onClick={onCancel}
              disabled={pending}
              className="px-2 py-1 text-xs rounded bg-theme-danger text-theme-danger hover:opacity-80 disabled:opacity-40 inline-flex items-center gap-1"
            >
              <XCircle className="w-3 h-3" /> Cancel
            </button>
          )}
          {!canApprove && !canCancel && (
            <span className="text-xs text-theme-tertiary">—</span>
          )}
        </div>
      </td>
    </tr>
  );
};

const STATUS_TONE: Record<StorageMigrationStatus, string> = {
  planned: 'bg-theme-background-secondary text-theme-secondary',
  approved: 'bg-theme-info text-theme-info',
  preparing: 'bg-theme-info text-theme-info',
  syncing: 'bg-theme-warning text-theme-warning',
  verifying: 'bg-theme-warning text-theme-warning',
  cutover: 'bg-theme-warning text-theme-warning',
  completed: 'bg-theme-success text-theme-success',
  failed: 'bg-theme-danger text-theme-danger',
  cancelled: 'bg-theme-background-secondary text-theme-tertiary',
};

const StatusPill: React.FC<{ status: StorageMigrationStatus }> = ({ status }) => (
  <span
    className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium ${STATUS_TONE[status]}`}
  >
    <Clock className="w-3 h-3" />
    {status}
  </span>
);
