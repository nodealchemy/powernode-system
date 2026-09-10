import React from 'react';
import {
  Boxes,
  RefreshCw,
  Droplet,
  Recycle,
  Trash2,
  Pencil,
  ChevronDown,
  ChevronRight,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { EntityLink } from '@/shared/components/entity';
import { StatusBadge } from '@system/features/system/components/shared/StatusBadge';
import { lifecyclePillClasses, type InstancePoolSummary } from './instancePoolsApi';

export interface InstancePoolCardProps {
  pool: InstancePoolSummary;
  expanded: boolean;
  isActioning: boolean;
  canControl: boolean;
  onToggleExpand: (id: string) => void;
  onView: (pool: InstancePoolSummary) => void;
  onEdit: (pool: InstancePoolSummary) => void;
  onReplenish: (pool: InstancePoolSummary) => void;
  onDrain: (pool: InstancePoolSummary) => void;
  onRecycleStale: (pool: InstancePoolSummary) => void;
  onDelete: (pool: InstancePoolSummary) => void;
}

/** Mobile card for one instance pool. */
export const InstancePoolCard: React.FC<InstancePoolCardProps> = ({
  pool,
  expanded,
  isActioning,
  canControl,
  onToggleExpand,
  onView,
  onEdit,
  onReplenish,
  onDrain,
  onRecycleStale,
  onDelete,
}) => {
  return (
    <div className="p-4" data-testid={`pool-card-${pool.id}`}>
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-start gap-2 flex-1 min-w-0">
          <button
            type="button"
            onClick={() => onToggleExpand(pool.id)}
            className="p-1 -ml-1 mt-0.5 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
            title={expanded ? 'Collapse details' : 'Expand details'}
            aria-label={
              expanded
                ? `Collapse ${pool.name} details`
                : `Expand ${pool.name} details`
            }
          >
            {expanded ? (
              <ChevronDown className="w-4 h-4" />
            ) : (
              <ChevronRight className="w-4 h-4" />
            )}
          </button>
          <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 mb-1">
            <Boxes className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
            <button
              type="button"
              onClick={() => onView(pool)}
              className="font-medium text-theme-primary hover:text-theme-link truncate text-left"
            >
              {pool.name}
            </button>
          </div>
          <div className="flex items-center gap-2 mt-1">
            <StatusBadge status={pool.status} size="xs" />
            <span
              className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${lifecyclePillClasses(
                pool.lifecycle_class,
              )}`}
            >
              {pool.lifecycle_class}
            </span>
          </div>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2 text-xs text-theme-secondary mb-3">
        <div>
          <span className="text-theme-tertiary">target:</span>{' '}
          <span className="text-theme-primary font-medium">
            {pool.target_size}
          </span>
        </div>
        <div>
          <span className="text-theme-tertiary">range:</span>{' '}
          {pool.min_size}–{pool.max_size}
        </div>
        <div>
          <span className="text-theme-tertiary">ready:</span>{' '}
          <span className="text-theme-success-fg">
            {pool.ready_count}
          </span>
        </div>
        <div>
          <span className="text-theme-tertiary">warming:</span>{' '}
          {pool.warming_count}
        </div>
        <div>
          <span className="text-theme-tertiary">claimed:</span>{' '}
          {pool.claimed_count}
        </div>
        {pool.errored_count > 0 && (
          <div>
            <span className="text-theme-tertiary">errored:</span>{' '}
            <span className="text-theme-danger-fg">
              {pool.errored_count}
            </span>
          </div>
        )}
      </div>

      {canControl && (
        <div className="flex flex-wrap items-center gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() => onEdit(pool)}
            disabled={isActioning || pool.status === 'archived'}
            aria-label={`Edit ${pool.name}`}
          >
            <Pencil className="w-4 h-4 mr-1" />
            Edit
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => onReplenish(pool)}
            /* Active-only, same reason as the table-row button. */
            disabled={isActioning || pool.status !== 'active'}
            aria-label={`Replenish ${pool.name}`}
          >
            <RefreshCw
              className={`w-4 h-4 mr-1 ${
                isActioning ? 'animate-spin' : ''
              }`}
            />
            Replenish
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => onDrain(pool)}
            disabled={
              isActioning ||
              pool.status === 'draining' ||
              pool.status === 'archived'
            }
            aria-label={`Drain ${pool.name}`}
          >
            <Droplet className="w-4 h-4 mr-1" />
            Drain
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => onRecycleStale(pool)}
            /* Archived-only exclusion, same as the table-row button. */
            disabled={isActioning || pool.status === 'archived'}
            aria-label={`Recycle stale members of ${pool.name}`}
          >
            <Recycle className="w-4 h-4 mr-1" />
            Recycle stale
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() => onDelete(pool)}
            disabled={isActioning || pool.status === 'archived'}
            aria-label={`Delete ${pool.name}`}
          >
            <Trash2 className="w-4 h-4 mr-1" />
            Delete
          </Button>
        </div>
      )}

      {expanded && (
        <div className="mt-3 pt-3 border-t border-theme grid grid-cols-2 gap-3 text-sm">
          {pool.description && (
            <div className="col-span-2">
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Description
              </label>
              <p className="text-theme-primary">
                {pool.description}
              </p>
            </div>
          )}
          <div>
            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
              Status
            </label>
            <p className="text-theme-primary">{pool.status}</p>
          </div>
          <div>
            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
              Lifecycle class
            </label>
            <p className="text-theme-primary">
              {pool.lifecycle_class}
            </p>
          </div>
          <div className="col-span-2">
            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
              Template
            </label>
            <p className="text-theme-primary">
              {pool.node_template_id || pool.node_template_name ? (
                <EntityLink
                  type="node_template"
                  id={pool.node_template_id}
                  label={
                    pool.node_template_name ?? pool.node_template_id
                  }
                />
              ) : (
                '—'
              )}
            </p>
          </div>
          <div>
            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
              Sizing (min/target/max)
            </label>
            <p className="text-theme-primary font-mono text-xs">
              {pool.min_size} / {pool.target_size} / {pool.max_size}
            </p>
          </div>
          <div>
            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
              Deficit
            </label>
            <p
              className={
                pool.deficit > 0
                  ? 'text-theme-warning-fg'
                  : 'text-theme-primary'
              }
            >
              {pool.deficit}
            </p>
          </div>
          <div className="col-span-2">
            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
              Last replenished
            </label>
            <p className="text-theme-primary text-xs">
              {pool.last_replenished_at
                ? new Date(
                    pool.last_replenished_at,
                  ).toLocaleString()
                : 'never'}
            </p>
          </div>
          <div className="col-span-2">
            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
              Pool ID
            </label>
            <p
              className="text-theme-primary font-mono text-xs truncate"
              title={pool.id}
            >
              {pool.id}
            </p>
          </div>
        </div>
      )}
    </div>
  );
};

export default InstancePoolCard;
