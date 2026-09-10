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

export interface InstancePoolRowProps {
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

/** Desktop table row (+ expandable detail row) for one instance pool. */
export const InstancePoolRow: React.FC<InstancePoolRowProps> = ({
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
    <React.Fragment>
      <tr
        className="hover:bg-theme-surface-hover transition-colors duration-200"
        data-testid={`pool-row-${pool.id}`}
      >
        <td className="py-3 px-2 align-middle">
          <button
            type="button"
            onClick={() => onToggleExpand(pool.id)}
            className="p-1 text-theme-secondary hover:text-theme-primary rounded transition-colors"
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
        </td>
        <td className="py-3 px-4">
          <div className="flex items-center gap-2">
            <Boxes className="w-4 h-4 text-theme-tertiary flex-shrink-0" />
            <button
              type="button"
              onClick={() => onView(pool)}
              className="font-medium text-theme-primary hover:text-theme-link text-left"
            >
              {pool.name}
            </button>
          </div>
        </td>
        <td className="py-3 px-4">
          <StatusBadge status={pool.status} size="xs" />
        </td>
        <td className="py-3 px-4">
          <span
            className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${lifecyclePillClasses(
              pool.lifecycle_class,
            )}`}
          >
            {pool.lifecycle_class}
          </span>
        </td>
        <td className="py-3 px-4 text-sm text-theme-secondary">
          <div className="font-mono">
            <span className="text-theme-primary font-medium">
              {pool.target_size}
            </span>
            <span className="text-theme-tertiary"> target</span>
            <span className="text-theme-tertiary"> · </span>
            <span>{pool.min_size}</span>
            <span className="text-theme-tertiary">–</span>
            <span>{pool.max_size}</span>
          </div>
          {pool.deficit > 0 && (
            <div className="text-xs text-theme-warning-fg mt-0.5">
              deficit: {pool.deficit}
            </div>
          )}
        </td>
        <td className="py-3 px-4 text-sm text-theme-secondary">
          <div className="font-mono">
            <span className="text-theme-success-fg">
              {pool.ready_count} ready
            </span>
            <span className="text-theme-tertiary"> · </span>
            <span>{pool.warming_count} warming</span>
            <span className="text-theme-tertiary"> · </span>
            <span>{pool.claimed_count} claimed</span>
          </div>
          {pool.errored_count > 0 && (
            <div className="text-xs text-theme-danger-fg mt-0.5">
              {pool.errored_count} errored
            </div>
          )}
        </td>
        <td className="py-3 px-4">
          <div className="flex items-center justify-end gap-2">
            {canControl && (
              <Button
                variant="outline"
                size="sm"
                onClick={() => onEdit(pool)}
                disabled={isActioning || pool.status === 'archived'}
                title="Edit pool"
                aria-label={`Edit ${pool.name}`}
              >
                <Pencil className="w-4 h-4" />
              </Button>
            )}
            {canControl && (
              <Button
                variant="outline"
                size="sm"
                onClick={() => onReplenish(pool)}
                /* Replenish is refused for every status but
                   'active' (InstancePoolService#replenish!), so
                   offering it on a paused/draining/archived pool
                   is an action that can only ever toast an
                   error. IMP-cb2da06a384b. */
                disabled={isActioning || pool.status !== 'active'}
                title="Replenish pool"
                aria-label={`Replenish ${pool.name}`}
              >
                <RefreshCw
                  className={`w-4 h-4 ${
                    isActioning ? 'animate-spin' : ''
                  }`}
                />
              </Button>
            )}
            {canControl && (
              <Button
                variant="outline"
                size="sm"
                onClick={() => onDrain(pool)}
                disabled={
                  isActioning ||
                  pool.status === 'draining' ||
                  pool.status === 'archived'
                }
                title="Drain pool"
                aria-label={`Drain ${pool.name}`}
              >
                <Droplet className="w-4 h-4" />
              </Button>
            )}
            {canControl && (
              <Button
                variant="outline"
                size="sm"
                onClick={() => onRecycleStale(pool)}
                /* An archived pool has nothing left to sweep;
                   every other status can hold stale members. */
                disabled={isActioning || pool.status === 'archived'}
                title="Recycle stale members"
                aria-label={`Recycle stale members of ${pool.name}`}
              >
                <Recycle className="w-4 h-4" />
              </Button>
            )}
            {canControl && (
              <Button
                variant="outline"
                size="sm"
                onClick={() => onDelete(pool)}
                disabled={isActioning || pool.status === 'archived'}
                title="Delete pool"
                aria-label={`Delete ${pool.name}`}
              >
                <Trash2 className="w-4 h-4" />
              </Button>
            )}
          </div>
        </td>
      </tr>
      {expanded && (
        <tr className="bg-theme-background border-b border-theme">
          <td />
          <td colSpan={6} className="py-3 px-4">
            <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
              {pool.description && (
                <div className="col-span-full">
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
              <div>
                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                  Template
                </label>
                <p className="text-theme-primary">
                  {pool.node_template_id ||
                  pool.node_template_name ? (
                    <EntityLink
                      type="node_template"
                      id={pool.node_template_id}
                      label={
                        pool.node_template_name ??
                        pool.node_template_id
                      }
                    />
                  ) : (
                    '—'
                  )}
                </p>
              </div>
              <div>
                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                  Sizing (min / target / max)
                </label>
                <p className="text-theme-primary font-mono text-xs">
                  {pool.min_size} / {pool.target_size} /{' '}
                  {pool.max_size}
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
              <div>
                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                  Members (ready / warming / claimed / errored)
                </label>
                <p className="text-theme-primary font-mono text-xs">
                  <span className="text-theme-success-fg">
                    {pool.ready_count}
                  </span>{' '}
                  / {pool.warming_count} / {pool.claimed_count} /{' '}
                  <span
                    className={
                      pool.errored_count > 0
                        ? 'text-theme-danger-fg'
                        : undefined
                    }
                  >
                    {pool.errored_count}
                  </span>
                </p>
              </div>
              <div>
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
              <div>
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
          </td>
        </tr>
      )}
    </React.Fragment>
  );
};

export default InstancePoolRow;
