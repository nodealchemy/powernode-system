import React from 'react';
import { Boxes } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { EntityLink } from '@/shared/components/entity';
import { StatusBadge } from '@system/features/system/components/shared/StatusBadge';
import { lifecyclePillClasses, type InstancePoolSummary } from './instancePoolsApi';

// =============================================================================
// Pool Detail modal
// =============================================================================

export interface PoolDetailModalProps {
  pool: InstancePoolSummary | null;
  onClose: () => void;
}

export const PoolDetailModal: React.FC<PoolDetailModalProps> = ({
  pool,
  onClose,
}) => {
  if (!pool) return null;
  const lastReplenished = pool.last_replenished_at
    ? new Date(pool.last_replenished_at).toLocaleString()
    : 'never';

  return (
    <Modal
      isOpen={!!pool}
      onClose={onClose}
      title={pool.name}
      subtitle={`${pool.lifecycle_class} pool — ${pool.status}`}
      icon={<Boxes className="w-6 h-6" />}
      size="lg"
      footer={
        <div className="flex items-center justify-end gap-3">
          <Button variant="ghost" onClick={onClose}>
            Close
          </Button>
        </div>
      }
    >
      <div className="space-y-5">
        <section>
          <h3 className="text-sm font-medium text-theme-primary mb-2">
            Status
          </h3>
          <div className="flex flex-wrap gap-2">
            <StatusBadge status={pool.status} size="xs" />
            <span
              className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${lifecyclePillClasses(
                pool.lifecycle_class,
              )}`}
            >
              {pool.lifecycle_class}
            </span>
          </div>
          {pool.description && (
            <p className="mt-2 text-sm text-theme-secondary">
              {pool.description}
            </p>
          )}
          {(pool.node_template_id || pool.node_template_name) && (
            <p className="mt-2 text-sm text-theme-secondary">
              Template:{' '}
              <EntityLink
                type="node_template"
                id={pool.node_template_id}
                label={pool.node_template_name ?? pool.node_template_id}
              />
            </p>
          )}
        </section>

        <section>
          <h3 className="text-sm font-medium text-theme-primary mb-2">
            Sizing
          </h3>
          <div className="grid grid-cols-3 gap-3 text-sm">
            <div className="p-3 bg-theme-background-secondary rounded-lg">
              <div className="text-xs text-theme-tertiary">min</div>
              <div className="font-mono text-theme-primary">
                {pool.min_size}
              </div>
            </div>
            <div className="p-3 bg-theme-background-secondary rounded-lg">
              <div className="text-xs text-theme-tertiary">target</div>
              <div className="font-mono text-theme-primary">
                {pool.target_size}
              </div>
            </div>
            <div className="p-3 bg-theme-background-secondary rounded-lg">
              <div className="text-xs text-theme-tertiary">max</div>
              <div className="font-mono text-theme-primary">
                {pool.max_size}
              </div>
            </div>
          </div>
          {pool.deficit > 0 && (
            <div className="mt-2 text-xs text-theme-warning-fg">
              Reaper will provision {pool.deficit} additional instance(s) on
              the next tick.
            </div>
          )}
        </section>

        <section>
          <h3 className="text-sm font-medium text-theme-primary mb-2">
            Members
          </h3>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm">
            <div className="p-3 bg-theme-success-bg rounded-lg">
              <div className="text-xs text-theme-success-fg">ready</div>
              <div className="font-mono text-theme-primary">
                {pool.ready_count}
              </div>
            </div>
            <div className="p-3 bg-theme-info-bg rounded-lg">
              <div className="text-xs text-theme-info-fg">warming</div>
              <div className="font-mono text-theme-primary">
                {pool.warming_count}
              </div>
            </div>
            <div className="p-3 bg-theme-interactive-primary/10 rounded-lg">
              <div className="text-xs text-theme-interactive-primary">
                claimed
              </div>
              <div className="font-mono text-theme-primary">
                {pool.claimed_count}
              </div>
            </div>
            <div className="p-3 bg-theme-danger-bg rounded-lg">
              <div className="text-xs text-theme-danger-fg">errored</div>
              <div className="font-mono text-theme-primary">
                {pool.errored_count}
              </div>
            </div>
          </div>
        </section>

        <section>
          <h3 className="text-sm font-medium text-theme-primary mb-2">
            History
          </h3>
          <div className="text-sm text-theme-secondary">
            Last replenished:{' '}
            <span className="text-theme-primary font-mono">
              {lastReplenished}
            </span>
          </div>
        </section>
      </div>
    </Modal>
  );
};

export default PoolDetailModal;
