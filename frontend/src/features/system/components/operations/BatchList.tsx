import React from 'react';
import { Badge } from '@/shared/components/ui/Badge';
import { capitalize, formatRelativeTime } from '@/shared/utils/formatters';
import type {
  SystemModuleBuildBatch,
  SystemModuleBuildBatchStatus,
} from '@system/features/system/types/system.types';

interface BatchListProps {
  batches: SystemModuleBuildBatch[];
  onSelect: (id: string) => void;
}

const STATUS_LABELS: Record<SystemModuleBuildBatchStatus, string> = {
  planning: 'Planning',
  dispatched: 'Dispatched',
  awaiting_signature: 'Awaiting signature',
  publishing: 'Publishing',
  complete: 'Complete',
  partial: 'Partial',
  failed: 'Failed',
};

// System::ModuleBuildBatch::STATUSES → Badge variant. planning is neutral
// (not started yet); dispatched/awaiting_signature/publishing are all
// in-flight (warning); partial also gets warning — it succeeded, but not
// completely, so it still needs a look.
function statusVariant(
  status: SystemModuleBuildBatchStatus
): 'outline' | 'warning' | 'success' | 'danger' {
  switch (status) {
    case 'planning':
      return 'outline';
    case 'dispatched':
    case 'awaiting_signature':
    case 'publishing':
      return 'warning';
    case 'complete':
      return 'success';
    case 'partial':
      return 'warning';
    case 'failed':
      return 'danger';
    default:
      return 'outline';
  }
}

// base_sha/head_sha are full 40-char shas for git-driven triggers, or an
// opaque package-repo sync-snapshot token for "package" batches (see
// System::ModuleBuildBatch's class doc) — either way, the first 7 chars are
// a reasonable short identifier.
function shortRef(ref: string): string {
  return ref.slice(0, 7);
}

export const BatchList: React.FC<BatchListProps> = ({ batches, onSelect }) => {
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
                <Badge variant={statusVariant(batch.status)} size="xs">
                  {STATUS_LABELS[batch.status] ?? batch.status}
                </Badge>
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
          </div>
        </li>
      ))}
    </ul>
  );
};

export default BatchList;
