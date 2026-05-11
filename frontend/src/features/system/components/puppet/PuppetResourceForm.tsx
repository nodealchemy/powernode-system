import React, { useState, useEffect, useCallback } from 'react';
import { Save, X } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemPuppetResource } from '@system/features/system/types/system.types';

// Mirrors System::PuppetResource::RESOURCE_TYPES on the backend.
const RESOURCE_TYPES = [
  'file', 'package', 'service', 'exec', 'user', 'group',
  'cron', 'mount', 'host', 'notify', 'class', 'define', 'custom'
] as const;

interface PuppetResourceFormProps {
  puppetModuleId: string;
  resource?: SystemPuppetResource | null;
  onSaved: (resource: SystemPuppetResource) => void;
  onCancel: () => void;
}

interface FormState {
  name: string;
  description: string;
  resource_type: string;
  title: string;
  path: string;
  data: string;
  enabled: boolean;
  exported: boolean;
  parameters: string;
  config: string;
}

const blankForm = (): FormState => ({
  name: '',
  description: '',
  resource_type: 'file',
  title: '',
  path: '',
  data: '',
  enabled: true,
  exported: false,
  parameters: '{}',
  config: '{}'
});

const formFromResource = (r: SystemPuppetResource): FormState => ({
  name: r.name,
  description: r.description || '',
  resource_type: r.resource_type,
  title: r.title || '',
  path: r.path || '',
  data: r.data || '',
  enabled: r.enabled,
  exported: r.exported,
  parameters: JSON.stringify(r.parameters || {}, null, 2),
  config: JSON.stringify(r.config || {}, null, 2)
});

/**
 * PuppetResourceForm - Nested form for creating or editing a Puppet resource
 * within a PuppetModule. Designed to render inline inside the module's detail
 * modal (Resources tab) — not a standalone modal.
 *
 * `parameters` and `config` are entered as JSON in `<textarea>`s; we parse on
 * submit and surface validation errors locally without contacting the server.
 */
export const PuppetResourceForm: React.FC<PuppetResourceFormProps> = ({
  puppetModuleId,
  resource,
  onSaved,
  onCancel
}) => {
  const { addNotification } = useNotifications();
  const [form, setForm] = useState<FormState>(() => resource ? formFromResource(resource) : blankForm());
  const [errors, setErrors] = useState<Partial<Record<keyof FormState, string>>>({});
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    setForm(resource ? formFromResource(resource) : blankForm());
    setErrors({});
  }, [resource]);

  const update = useCallback(<K extends keyof FormState>(key: K, value: FormState[K]) => {
    setForm(prev => ({ ...prev, [key]: value }));
    if (errors[key]) {
      setErrors(prev => ({ ...prev, [key]: undefined }));
    }
  }, [errors]);

  const validate = (): { ok: false } | { ok: true; parameters: Record<string, unknown>; config: Record<string, unknown> } => {
    const next: Partial<Record<keyof FormState, string>> = {};

    if (!form.name.trim()) next.name = 'Name is required';
    if (!form.resource_type.trim()) next.resource_type = 'Resource type is required';

    let parsedParameters: Record<string, unknown> = {};
    let parsedConfig: Record<string, unknown> = {};

    try {
      parsedParameters = form.parameters.trim() ? JSON.parse(form.parameters) : {};
      if (typeof parsedParameters !== 'object' || Array.isArray(parsedParameters) || parsedParameters === null) {
        next.parameters = 'Parameters must be a JSON object';
      }
    } catch {
      next.parameters = 'Parameters must be valid JSON';
    }

    try {
      parsedConfig = form.config.trim() ? JSON.parse(form.config) : {};
      if (typeof parsedConfig !== 'object' || Array.isArray(parsedConfig) || parsedConfig === null) {
        next.config = 'Config must be a JSON object';
      }
    } catch {
      next.config = 'Config must be valid JSON';
    }

    if (Object.keys(next).length > 0) {
      setErrors(next);
      return { ok: false };
    }
    return { ok: true, parameters: parsedParameters, config: parsedConfig };
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const validated = validate();
    if (!validated.ok) return;

    setSubmitting(true);
    try {
      const payload = {
        name: form.name.trim(),
        description: form.description.trim() || undefined,
        resource_type: form.resource_type,
        title: form.title.trim() || undefined,
        path: form.path.trim() || undefined,
        data: form.data || undefined,
        enabled: form.enabled,
        exported: form.exported,
        parameters: validated.parameters,
        config: validated.config
      };

      const saved = resource
        ? await systemApi.updatePuppetResource(puppetModuleId, resource.id, payload)
        : await systemApi.createPuppetResource(puppetModuleId, payload);

      addNotification({
        type: 'success',
        message: `Resource ${resource ? 'updated' : 'created'}: ${saved.name}`
      });
      onSaved(saved);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'Failed to save resource';
      addNotification({ type: 'error', message });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <form onSubmit={handleSubmit} className="bg-theme-background rounded-lg p-4 border border-theme space-y-4">
      <div className="flex items-center justify-between">
        <h4 className="font-medium text-theme-primary">
          {resource ? `Edit Resource: ${resource.name}` : 'New Resource'}
        </h4>
        <Button variant="ghost" size="sm" type="button" onClick={onCancel} disabled={submitting}>
          <X className="w-4 h-4" />
        </Button>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div>
          <label className="block text-sm text-theme-secondary mb-1">Name *</label>
          <input
            type="text"
            value={form.name}
            onChange={(e) => update('name', e.target.value)}
            className="w-full px-3 py-2 bg-theme-surface border border-theme rounded text-theme-primary focus:outline-none focus:border-theme-info"
            disabled={submitting}
          />
          {errors.name && <p className="text-xs text-theme-error mt-1">{errors.name}</p>}
        </div>

        <div>
          <label className="block text-sm text-theme-secondary mb-1">Resource Type *</label>
          <select
            value={form.resource_type}
            onChange={(e) => update('resource_type', e.target.value)}
            className="w-full px-3 py-2 bg-theme-surface border border-theme rounded text-theme-primary focus:outline-none focus:border-theme-info"
            disabled={submitting}
          >
            {RESOURCE_TYPES.map((type) => (
              <option key={type} value={type}>{type}</option>
            ))}
          </select>
          {errors.resource_type && <p className="text-xs text-theme-error mt-1">{errors.resource_type}</p>}
        </div>

        <div>
          <label className="block text-sm text-theme-secondary mb-1">Title</label>
          <input
            type="text"
            value={form.title}
            onChange={(e) => update('title', e.target.value)}
            placeholder="(defaults to name if blank)"
            className="w-full px-3 py-2 bg-theme-surface border border-theme rounded text-theme-primary focus:outline-none focus:border-theme-info"
            disabled={submitting}
          />
        </div>

        <div>
          <label className="block text-sm text-theme-secondary mb-1">Path</label>
          <input
            type="text"
            value={form.path}
            onChange={(e) => update('path', e.target.value)}
            placeholder="(e.g., /etc/nginx/nginx.conf)"
            className="w-full px-3 py-2 bg-theme-surface border border-theme rounded text-theme-primary focus:outline-none focus:border-theme-info font-mono text-sm"
            disabled={submitting}
          />
        </div>
      </div>

      <div>
        <label className="block text-sm text-theme-secondary mb-1">Description</label>
        <input
          type="text"
          value={form.description}
          onChange={(e) => update('description', e.target.value)}
          className="w-full px-3 py-2 bg-theme-surface border border-theme rounded text-theme-primary focus:outline-none focus:border-theme-info"
          disabled={submitting}
        />
      </div>

      <div>
        <label className="block text-sm text-theme-secondary mb-1">
          Parameters (Puppet attributes — JSON object)
        </label>
        <textarea
          value={form.parameters}
          onChange={(e) => update('parameters', e.target.value)}
          rows={5}
          className="w-full px-3 py-2 bg-theme-surface border border-theme rounded text-theme-primary focus:outline-none focus:border-theme-info font-mono text-sm"
          placeholder='{"ensure": "present", "owner": "root"}'
          disabled={submitting}
        />
        {errors.parameters && <p className="text-xs text-theme-error mt-1">{errors.parameters}</p>}
      </div>

      <div>
        <label className="block text-sm text-theme-secondary mb-1">
          Config (free-form metadata — JSON object)
        </label>
        <textarea
          value={form.config}
          onChange={(e) => update('config', e.target.value)}
          rows={3}
          className="w-full px-3 py-2 bg-theme-surface border border-theme rounded text-theme-primary focus:outline-none focus:border-theme-info font-mono text-sm"
          placeholder='{}'
          disabled={submitting}
        />
        {errors.config && <p className="text-xs text-theme-error mt-1">{errors.config}</p>}
      </div>

      <div>
        <label className="block text-sm text-theme-secondary mb-1">Data (template body / file contents)</label>
        <textarea
          value={form.data}
          onChange={(e) => update('data', e.target.value)}
          rows={4}
          className="w-full px-3 py-2 bg-theme-surface border border-theme rounded text-theme-primary focus:outline-none focus:border-theme-info font-mono text-sm"
          disabled={submitting}
        />
      </div>

      <div className="flex flex-wrap gap-6">
        <label className="flex items-center gap-2 text-sm text-theme-primary">
          <input
            type="checkbox"
            checked={form.enabled}
            onChange={(e) => update('enabled', e.target.checked)}
            disabled={submitting}
          />
          Enabled
        </label>
        <label className="flex items-center gap-2 text-sm text-theme-primary">
          <input
            type="checkbox"
            checked={form.exported}
            onChange={(e) => update('exported', e.target.checked)}
            disabled={submitting}
          />
          Exported (uses <code className="px-1 bg-theme-surface rounded">@@</code> in Puppet DSL)
        </label>
      </div>

      <div className="flex justify-end gap-2 pt-2 border-t border-theme">
        <Button variant="outline" type="button" onClick={onCancel} disabled={submitting}>
          Cancel
        </Button>
        <Button variant="primary" type="submit" disabled={submitting}>
          {submitting ? <LoadingSpinner size="sm" className="mr-2" /> : <Save className="w-4 h-4 mr-2" />}
          {resource ? 'Update Resource' : 'Create Resource'}
        </Button>
      </div>
    </form>
  );
};

export default PuppetResourceForm;
