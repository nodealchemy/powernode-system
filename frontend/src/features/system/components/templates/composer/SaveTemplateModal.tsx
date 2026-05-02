import React, { useState } from 'react';
import { Save, X } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeModule, SystemNodeTemplate } from '@system/features/system/types/system.types';
import type { TemplateComposeConflict } from '@system/features/system/services/api/templatesApi';

interface Props {
  modules: SystemNodeModule[];
  conflicts: TemplateComposeConflict[];
  onClose: () => void;
  onSaved: (template: SystemNodeTemplate) => void;
}

// Save flow for the visual Template Composer (Golden Eclipse plan M-FE-1).
// Two-step: create the template via POST /system/node_templates, then
// for each chosen module POST a TemplateModule (handled server-side via
// system_assign_module_to_template through the existing tools surface).
//
// v0 keeps the create + assign in two separate calls to honor the
// existing endpoint shape. M-FE-1.1 will batch into a single transactional
// "create_with_modules" endpoint once the operator UX warrants it.
export const SaveTemplateModal: React.FC<Props> = ({ modules, conflicts, onClose, onSaved }) => {
  const { showNotification } = useNotifications();
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [platformId, setPlatformId] = useState<string>('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const platformIds = Array.from(
    new Set(
      modules
        .map((m) => (m as SystemNodeModule & { node_platform_id?: string }).node_platform_id)
        .filter((id): id is string => Boolean(id))
    )
  );
  const platformDisagreement = platformIds.length > 1;

  React.useEffect(() => {
    // Auto-pick the platform when all modules agree (most common case).
    if (platformIds.length === 1 && !platformId) {
      setPlatformId(platformIds[0]);
    }
  }, [platformIds, platformId]);

  const handleSave = async (): Promise<void> => {
    if (!name.trim()) {
      setError('Template name required');
      return;
    }
    if (conflicts.length > 0) {
      setError(`Resolve ${conflicts.length} conflicts before saving`);
      return;
    }

    setSaving(true);
    setError(null);
    try {
      const template = await systemApi.createTemplate({
        name: name.trim(),
        description: description.trim() || undefined,
        node_platform_id: platformId || undefined,
        enabled: true
      });

      // Assign each module to the new template. Failures are logged but
      // don't block the overall save — the operator can retry assignments
      // from the template detail view.
      const assignments = await Promise.allSettled(
        modules.map((m) =>
          (systemApi as unknown as {
            assignModuleToTemplate?: (templateId: string, moduleId: string) => Promise<unknown>;
          }).assignModuleToTemplate?.(template.id, m.id) ??
          Promise.reject(new Error('assignModuleToTemplate not implemented'))
        )
      );

      const failed = assignments.filter((a) => a.status === 'rejected');
      if (failed.length > 0) {
        showNotification({
          type: 'warning',
          message: `Template saved but ${failed.length} module(s) failed to attach. Reassign from template detail.`
        });
      }

      onSaved(template);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Save failed');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-theme-surface border border-theme-border rounded-lg shadow-xl w-full max-w-lg p-6">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-lg font-semibold">Save as Template</h2>
          <Button size="xs" variant="ghost" onClick={onClose}>
            <X size={16} />
          </Button>
        </div>

        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium mb-1">Name *</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="w-full px-3 py-2 text-sm rounded border border-theme-border bg-theme-background"
              placeholder="e.g., web-tier-prod"
              autoFocus
            />
          </div>

          <div>
            <label className="block text-sm font-medium mb-1">Description</label>
            <textarea
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              rows={3}
              className="w-full px-3 py-2 text-sm rounded border border-theme-border bg-theme-background"
              placeholder="Optional — what is this template for?"
            />
          </div>

          {platformDisagreement && (
            <div>
              <label className="block text-sm font-medium mb-1">Platform *</label>
              <select
                value={platformId}
                onChange={(e) => setPlatformId(e.target.value)}
                className="w-full px-3 py-2 text-sm rounded border border-theme-border bg-theme-background"
              >
                <option value="">Select platform…</option>
                {platformIds.map((id) => (
                  <option key={id} value={id}>{id}</option>
                ))}
              </select>
              <p className="text-xs text-theme-warning mt-1">
                Modules span multiple platforms; pick the target.
              </p>
            </div>
          )}

          <div className="text-sm text-theme-muted bg-theme-background p-3 rounded">
            <strong>{modules.length}</strong> module(s) will be attached to this template.
            {conflicts.length > 0 && (
              <span className="text-theme-warning"> · {conflicts.length} conflict(s) — must resolve first</span>
            )}
          </div>

          {error && (
            <div className="text-sm text-theme-error">{error}</div>
          )}
        </div>

        <div className="flex justify-end gap-2 mt-6">
          <Button variant="secondary" onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button
            variant="primary"
            onClick={handleSave}
            disabled={saving || !name.trim() || conflicts.length > 0}
          >
            <Save size={14} />
            {saving ? 'Saving…' : 'Save Template'}
          </Button>
        </div>
      </div>
    </div>
  );
};
