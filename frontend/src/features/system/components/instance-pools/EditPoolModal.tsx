import React, { useCallback, useEffect, useState } from 'react';
import { Boxes } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { EntityLink } from '@/shared/components/entity';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { pendingApprovalNotice } from '@system/features/system/utils/pendingApproval';
import {
  instancePoolsApi,
  isPendingApproval,
  type InstancePoolSummary,
} from './instancePoolsApi';

// =============================================================================
// Edit Pool modal — mirrors CreatePoolModal as the edit form. Only the fields
// the controller's `update_params` permits are editable (description, sizing,
// status). Name, node template, and lifecycle_class are immutable post-create
// (not in the permit list), so they render as read-only context.
// =============================================================================

export interface EditPoolModalProps {
  pool: InstancePoolSummary | null;
  onClose: () => void;
  onUpdated: (pool: InstancePoolSummary) => void;
}

interface EditFormState {
  description: string;
  target_size: number;
  min_size: number;
  max_size: number;
  status: InstancePoolSummary['status'];
}

interface EditFormErrors {
  sizing?: string;
}

export const EditPoolModal: React.FC<EditPoolModalProps> = ({
  pool,
  onClose,
  onUpdated,
}) => {
  const { addNotification } = useNotifications();
  const [form, setForm] = useState<EditFormState | null>(null);
  const [errors, setErrors] = useState<EditFormErrors>({});
  const [submitting, setSubmitting] = useState(false);

  // Seed the form from the pool whenever a new pool is selected for editing.
  useEffect(() => {
    if (!pool) {
      setForm(null);
      return;
    }
    setErrors({});
    setForm({
      description: pool.description ?? '',
      target_size: pool.target_size,
      min_size: pool.min_size,
      max_size: pool.max_size,
      status: pool.status,
    });
  }, [pool]);

  const handleChange = useCallback(
    <K extends keyof EditFormState>(field: K, value: EditFormState[K]) => {
      setForm((prev) => (prev ? { ...prev, [field]: value } : prev));
    },
    [],
  );

  const validate = useCallback((): boolean => {
    if (!form) return false;
    const e: EditFormErrors = {};
    if (
      form.min_size < 0 ||
      form.target_size < form.min_size ||
      form.max_size < form.target_size
    ) {
      e.sizing = 'Sizing must satisfy 0 ≤ min ≤ target ≤ max';
    }
    setErrors(e);
    return Object.keys(e).length === 0;
  }, [form]);

  const handleSubmit = useCallback(
    async (event: React.FormEvent) => {
      event.preventDefault();
      if (!pool || !form) return;
      if (!validate()) return;
      setSubmitting(true);
      try {
        const updated = await instancePoolsApi.update(pool.id, {
          description: form.description.trim() || undefined,
          target_size: form.target_size,
          min_size: form.min_size,
          max_size: form.max_size,
          status: form.status,
        });
        // The form always sends target_size, max_size AND status, so both
        // gated transitions are reachable from this one submit. Nothing has
        // been written on the pending branch — never a success toast, and
        // never an upsert of a body that carries no pool.
        if (isPendingApproval(updated)) {
          addNotification(
            pendingApprovalNotice(`updating pool "${pool.name}"`, updated),
          );
          onClose();
          return;
        }
        onUpdated(updated);
      } catch (err) {
        addNotification({
          type: 'error',
          message:
            err instanceof Error ? err.message : 'Failed to update pool',
        });
      } finally {
        setSubmitting(false);
      }
    },
    [pool, form, validate, onUpdated, onClose, addNotification],
  );

  return (
    <Modal
      isOpen={!!pool}
      onClose={() => (submitting ? null : onClose())}
      title={pool ? `Edit ${pool.name}` : 'Edit instance pool'}
      subtitle="Adjust sizing, status, and description"
      icon={<Boxes className="w-6 h-6" />}
      size="lg"
      footer={
        <div className="flex items-center justify-end gap-3">
          <Button variant="ghost" onClick={onClose} disabled={submitting}>
            Cancel
          </Button>
          <Button
            variant="primary"
            onClick={handleSubmit}
            disabled={submitting || !form}
          >
            {submitting ? 'Saving...' : 'Save Changes'}
          </Button>
        </div>
      }
    >
      {pool && form && (
        <form onSubmit={handleSubmit} className="space-y-5">
          {/* Read-only context — name, template, and lifecycle_class are
              immutable post-create. */}
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                Name
              </label>
              <p className="px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-secondary text-sm">
                {pool.name}
              </p>
            </div>
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                Template
              </label>
              <p className="px-3 py-2 rounded-lg border border-theme bg-theme-background text-sm">
                {pool.node_template_id || pool.node_template_name ? (
                  <EntityLink
                    type="node_template"
                    id={pool.node_template_id}
                    label={pool.node_template_name ?? pool.node_template_id}
                  />
                ) : (
                  <span className="text-theme-secondary">—</span>
                )}
              </p>
            </div>
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                Lifecycle class
              </label>
              <p className="px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-secondary text-sm">
                {pool.lifecycle_class}
              </p>
            </div>
          </div>

          <FormField
            label="Description"
            id="edit-pool-description"
            type="textarea"
            rows={2}
            value={form.description}
            onChange={(v) => handleChange('description', v)}
            placeholder="Optional — what's this pool for?"
            disabled={submitting}
          />

          <div className="grid grid-cols-3 gap-3">
            <FormField
              label="Min size"
              id="edit-pool-min"
              type="number"
              min={0}
              value={String(form.min_size)}
              onChange={(v) => handleChange('min_size', Number(v))}
              disabled={submitting}
            />
            <FormField
              label="Target size"
              id="edit-pool-target"
              type="number"
              required
              min={0}
              value={String(form.target_size)}
              onChange={(v) => handleChange('target_size', Number(v))}
              disabled={submitting}
            />
            <FormField
              label="Max size"
              id="edit-pool-max"
              type="number"
              min={0}
              value={String(form.max_size)}
              onChange={(v) => handleChange('max_size', Number(v))}
              disabled={submitting}
            />
          </div>
          {errors.sizing && (
            <p className="text-sm text-theme-danger-fg">{errors.sizing}</p>
          )}

          <FormField
            label="Status"
            id="edit-pool-status"
            type="select"
            value={form.status}
            onChange={(v) => handleChange('status', v as InstancePoolSummary['status'])}
            disabled={submitting}
            options={[
              { value: 'active', label: 'active' },
              { value: 'paused', label: 'paused' },
              { value: 'draining', label: 'draining' },
              { value: 'archived', label: 'archived' },
            ]}
          />
        </form>
      )}
    </Modal>
  );
};

export default EditPoolModal;
