import React, { useCallback, useEffect, useState } from 'react';
import { Boxes } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { logger } from '@/shared/utils/logger';
import { pendingApprovalNotice } from '@system/features/system/utils/pendingApproval';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';
import {
  instancePoolsApi,
  isPendingApproval,
  type InstancePoolSummary,
} from './instancePoolsApi';

// =============================================================================
// Create Pool modal
// =============================================================================

export interface CreatePoolModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCreated: (pool: InstancePoolSummary) => void;
}

interface CreateFormState {
  name: string;
  description: string;
  node_template_id: string;
  target_size: number;
  min_size: number;
  max_size: number;
  lifecycle_class: 'ephemeral' | 'spot';
}

interface CreateFormErrors {
  name?: string;
  node_template_id?: string;
  sizing?: string;
}

const INITIAL_FORM: CreateFormState = {
  name: '',
  description: '',
  node_template_id: '',
  target_size: 2,
  min_size: 1,
  max_size: 4,
  lifecycle_class: 'ephemeral',
};

export const CreatePoolModal: React.FC<CreatePoolModalProps> = ({
  isOpen,
  onClose,
  onCreated,
}) => {
  const { addNotification } = useNotifications();
  const [form, setForm] = useState<CreateFormState>(INITIAL_FORM);
  const [errors, setErrors] = useState<CreateFormErrors>({});
  const [submitting, setSubmitting] = useState(false);
  const [templates, setTemplates] = useState<SystemNodeTemplate[]>([]);
  const [loadingTemplates, setLoadingTemplates] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setForm(INITIAL_FORM);
    setErrors({});
    setLoadingTemplates(true);
    systemApi
      .getTemplates({ per_page: 200 })
      .then((d) => setTemplates(d.templates.filter((t) => t.enabled)))
      .catch((err) => {
        logger.error('CreatePoolModal: failed to load templates', {
          error: err instanceof Error ? err.message : String(err),
        });
        addNotification({
          type: 'error',
          message: 'Failed to load node templates',
        });
      })
      .finally(() => setLoadingTemplates(false));
  }, [isOpen, addNotification]);

  const handleChange = useCallback(
    <K extends keyof CreateFormState>(
      field: K,
      value: CreateFormState[K],
    ) => {
      setForm((prev) => ({ ...prev, [field]: value }));
    },
    [],
  );

  const validate = useCallback((): boolean => {
    const e: CreateFormErrors = {};
    if (!form.name.trim()) e.name = 'Name is required';
    else if (!/^[a-zA-Z0-9][a-zA-Z0-9\-_.]*$/.test(form.name))
      e.name =
        'Name must start with alphanumeric and contain only letters, numbers, hyphens, underscores, and dots';
    if (!form.node_template_id)
      e.node_template_id = 'Template is required';
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
      if (!validate()) return;
      setSubmitting(true);
      try {
        const created = await instancePoolsApi.create({
          name: form.name.trim(),
          description: form.description.trim() || undefined,
          node_template_id: form.node_template_id,
          target_size: form.target_size,
          min_size: form.min_size,
          max_size: form.max_size,
          lifecycle_class: form.lifecycle_class,
        });
        // No pool exists yet on the pending branch — never a success toast,
        // and never an upsert of a body that carries no pool.
        if (isPendingApproval(created)) {
          addNotification(
            pendingApprovalNotice(
              `creating pool "${form.name.trim()}"`,
              created,
            ),
          );
          onClose();
          return;
        }
        onCreated(created);
      } catch (err) {
        addNotification({
          type: 'error',
          message:
            err instanceof Error ? err.message : 'Failed to create pool',
        });
      } finally {
        setSubmitting(false);
      }
    },
    [form, validate, onCreated, onClose, addNotification],
  );

  return (
    <Modal
      isOpen={isOpen}
      onClose={() => (submitting ? null : onClose())}
      title="Create instance pool"
      subtitle="Pre-warmed NodeInstances ready for instant claim"
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
            disabled={submitting || loadingTemplates}
          >
            {submitting ? 'Creating...' : 'Create Pool'}
          </Button>
        </div>
      }
    >
      <form onSubmit={handleSubmit} className="space-y-5">
        <FormField
          label="Name"
          id="pool-name"
          required
          value={form.name}
          onChange={(v) => handleChange('name', v)}
          placeholder="web-warm-pool"
          disabled={submitting}
          error={errors.name}
        />

        <FormField
          label="Description"
          id="pool-description"
          type="textarea"
          rows={2}
          value={form.description}
          onChange={(v) => handleChange('description', v)}
          placeholder="Optional — what's this pool for?"
          disabled={submitting}
        />

        <FormField
          label="Node template"
          id="pool-template"
          type="select"
          required
          value={form.node_template_id}
          onChange={(v) => handleChange('node_template_id', v)}
          disabled={submitting || loadingTemplates}
          error={errors.node_template_id}
          options={[
            {
              value: '',
              label: loadingTemplates ? 'Loading templates...' : 'Select a template',
            },
            ...templates.map((t) => ({
              value: t.id,
              label: t.node_platform_name
                ? `${t.name} (${t.node_platform_name})`
                : t.name,
            })),
          ]}
        />

        <div className="grid grid-cols-3 gap-3">
          <FormField
            label="Min size"
            id="pool-min"
            type="number"
            min={0}
            value={String(form.min_size)}
            onChange={(v) => handleChange('min_size', Number(v))}
            disabled={submitting}
          />
          <FormField
            label="Target size"
            id="pool-target"
            type="number"
            required
            min={0}
            value={String(form.target_size)}
            onChange={(v) => handleChange('target_size', Number(v))}
            disabled={submitting}
          />
          <FormField
            label="Max size"
            id="pool-max"
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
          label="Lifecycle class"
          id="pool-lifecycle"
          type="select"
          value={form.lifecycle_class}
          onChange={(v) => handleChange('lifecycle_class', v as 'ephemeral' | 'spot')}
          disabled={submitting}
          options={[
            { value: 'ephemeral', label: 'ephemeral — short-lived, predictable cost' },
            { value: 'spot', label: 'spot — interruptible, cost-optimized' },
          ]}
        />
      </form>
    </Modal>
  );
};

export default CreatePoolModal;
