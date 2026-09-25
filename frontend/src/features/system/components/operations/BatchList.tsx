import React, { useState } from 'react';
import { Ban } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { StatusBadge } from '../shared/StatusBadge';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { moduleBuildsApi } from '@system/features/system/services/api/moduleBuildsApi';
import { capitalize, formatRelativeTime } from '@/shared/utils/formatters';
import type {
  SystemModuleBuildBatch,
  SystemModuleBuildBatchStatus,
} from '@system/features/system/types/system.types';

interface BatchListProps {
  batches: SystemModuleBuildBatch[];
  onSelect: (id: string) => void;
  /** Called after a successful cancel, so the parent can refetch the list. */
  onCancelled?: () => void;
}

const STATUS_LABELS: Record<SystemModuleBuildBatchStatus, string> = {
  planning: 'Planning',
  dispatched: 'Dispatched',
  awaiting_signature: 'Awaiting signature',
  publishing: 'Publishing',
  complete: 'Complete',
  partial: 'Partial',
  failed: 'Failed',
  cancelled: 'Cancelled',
};

// base_sha/head_sha are full 40-char shas for git-driven triggers, or an
// opaque package-repo sync-snapshot token for "package" batches (see
// System::ModuleBuildBatch's class doc) — either way, the first 7 chars are
// a reasonable short identifier.
function shortRef(ref: string): string {
  return ref.slice(0, 7);
}

export const BatchList: React.FC<BatchListProps> = ({ batches, onSelect, onCancelled }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const { confirm, ConfirmationDialog } = useConfirmation();
  const [cancellingId, setCancellingId] = useState<string | null>(null);
  const canCancel = hasPermission('system.module_builds.cancel');

  // fc-34: ported from the deleted core CancelBatchButton — same confirm
  // copy, same permission (system.module_builds.cancel), same "active batch
  // only" visibility rule.
  const handleCancel = (batch: SystemModuleBuildBatch) => {
    confirm({
      title: 'Cancel Module Build',
      message: `This stops in-flight builds for batch ${batch.id.slice(0, 8)}. Modules already published are unaffected. Continue?`,
      confirmLabel: 'Cancel Batch',
      variant: 'danger',
      onConfirm: async () => {
        setCancellingId(batch.id);
        try {
          await moduleBuildsApi.cancel(batch.id);
          addNotification({ type: 'success', message: 'Module build batch cancelled' });
          onCancelled?.();
        } catch (e) {
          addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Failed to cancel batch' });
        } finally {
          setCancellingId(null);
        }
      },
    });
  };

  return (
    <ul className="divide-y divide-theme">
      {batches.map((batch) => (
        <li key={batch.id} className="px-3 py-2.5">
          <div className="flex items-start justify-between gap-3">
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2 text-sm flex-wrap">
                <button
                  type="button"
                  onClick={() => onSelect(batch.id)}
                  className="font-mono text-theme-link hover:underline cursor-pointer"
                  title="View batch details"
                >
                  {shortRef(batch.base_sha)}→{shortRef(batch.head_sha)}
                </button>
                <StatusBadge
                  status={batch.status}
                  size="xs"
                  label={STATUS_LABELS[batch.status] ?? batch.status}
                />
                {batch.shadow && (
                  <Badge variant="outline" size="xs">shadow</Badge>
                )}
                <Badge variant="secondary" size="xs">{capitalize(batch.trigger)}</Badge>
              </div>
              <div className="mt-1 text-xs text-theme-tertiary flex items-center gap-3 flex-wrap">
                <span>
                  {batch.module_slugs.length} module{batch.module_slugs.length === 1 ? '' : 's'} ·{' '}
                  {batch.succeeded_count}/{batch.planned_count} succeeded
                </span>
                {batch.failed_count > 0 && (
                  <span className="text-theme-error-fg">{batch.failed_count} failed</span>
                )}
                <span>{formatRelativeTime(batch.created_at)}</span>
              </div>
            </div>
            {canCancel && batch.active && (
              <Button
                size="sm"
                variant="ghost"
                iconOnly
                aria-label="Cancel build batch"
                title="Cancel build batch"
                disabled={cancellingId === batch.id}
                onClick={() => handleCancel(batch)}
              >
                <Ban className="w-3.5 h-3.5 text-theme-danger-fg" />
              </Button>
            )}
          </div>
        </li>
      ))}
      {ConfirmationDialog}
    </ul>
  );
};

export default BatchList;
