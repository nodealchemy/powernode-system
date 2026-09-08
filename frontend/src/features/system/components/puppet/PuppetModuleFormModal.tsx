import React, { useState, useEffect } from 'react';
import { Package } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { FormField } from '@/shared/components/ui/FormField';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemPuppetModule } from '@system/features/system/types/system.types';

interface PuppetModuleFormModalProps {
  isOpen: boolean;
  onClose: () => void;
  onModuleSaved?: (module: SystemPuppetModule) => void;
  editModule?: SystemPuppetModule | null;
}

/**
 * PuppetModuleFormModal - Modal for creating or editing Puppet modules
 */
export const PuppetModuleFormModal: React.FC<PuppetModuleFormModalProps> = ({
  isOpen,
  onClose,
  onModuleSaved,
  editModule
}) => {
  const { addNotification } = useNotifications();

  const [formData, setFormData] = useState({
    name: '',
    description: '',
    version: '',
    author: '',
    license: '',
    source_url: '',
    project_url: '',
    forge_name: '',
    enabled: true,
    public: false,
    dependencies: '[]',
    config: '{}',
    metadata: '{}'
  });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);

  const isEditMode = !!editModule;

  useEffect(() => {
    if (isOpen) {
      if (editModule) {
        setFormData({
          name: editModule.name,
          description: editModule.description || '',
          version: editModule.version || '',
          author: editModule.author || '',
          license: editModule.license || '',
          source_url: editModule.source_url || '',
          project_url: editModule.project_url || '',
          forge_name: editModule.forge_name || '',
          enabled: editModule.enabled,
          public: editModule.public,
          dependencies: JSON.stringify(editModule.dependencies || [], null, 2),
          config: JSON.stringify(editModule.config || {}, null, 2),
          metadata: JSON.stringify(editModule.metadata || {}, null, 2)
        });
      } else {
        setFormData({
          name: '',
          description: '',
          version: '',
          author: '',
          license: '',
          source_url: '',
          project_url: '',
          forge_name: '',
          enabled: true,
          public: false,
          dependencies: '[]',
          config: '{}',
          metadata: '{}'
        });
      }
      setErrors({});
    }
  }, [isOpen, editModule]);

  // FormField reports a value, the checkboxes still report an event; both land
  // here so the clear-the-error behaviour cannot drift between them.
  const setField = (name: string, value: string | boolean) => {
    setFormData(prev => ({ ...prev, [name]: value }));
    if (errors[name]) {
      setErrors(prev => {
        const next = { ...prev };
        delete next[name];
        return next;
      });
    }
  };

  const handleChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>
  ) => {
    const { name, value, type } = e.target;
    setField(name, type === 'checkbox' ? (e.target as HTMLInputElement).checked : value);
  };

  const validateJson = (value: string, fieldName: string): boolean => {
    try {
      JSON.parse(value);
      return true;
    } catch {
      setErrors(prev => ({ ...prev, [fieldName]: 'Invalid JSON format' }));
      return false;
    }
  };

  const validateForm = (): boolean => {
    const newErrors: Record<string, string> = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Name must be at least 2 characters';
    }

    // Validate JSON fields
    let jsonValid = true;
    if (!validateJson(formData.dependencies, 'dependencies')) jsonValid = false;
    if (!validateJson(formData.config, 'config')) jsonValid = false;
    if (!validateJson(formData.metadata, 'metadata')) jsonValid = false;

    if (!jsonValid) {
      return false;
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!validateForm()) return;

    setSubmitting(true);

    try {
      const submitData = {
        name: formData.name,
        description: formData.description || undefined,
        version: formData.version || undefined,
        author: formData.author || undefined,
        license: formData.license || undefined,
        source_url: formData.source_url || undefined,
        project_url: formData.project_url || undefined,
        forge_name: formData.forge_name || undefined,
        enabled: formData.enabled,
        public: formData.public,
        dependencies: JSON.parse(formData.dependencies),
        config: JSON.parse(formData.config),
        metadata: JSON.parse(formData.metadata)
      };

      let result: SystemPuppetModule;

      if (isEditMode && editModule) {
        result = await systemApi.updatePuppetModule(editModule.id, submitData);
        addNotification({
          type: 'success',
          message: `Puppet module "${result.name}" updated successfully`
        });
      } else {
        result = await systemApi.createPuppetModule(submitData);
        addNotification({
          type: 'success',
          message: `Puppet module "${result.name}" created successfully`
        });
      }

      onModuleSaved?.(result);
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update Puppet module: ${errorMessage}`
          : `Failed to create Puppet module: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditMode ? 'Edit Puppet Module' : 'Add Puppet Module'}
      icon={<Package className="w-6 h-6" />}
      maxWidth="2xl"
    >
          <form onSubmit={handleSubmit}>
            <div className="space-y-4">
              {/* Name and Version */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <FormField
                  label="Name"
                  id="name"
                  required
                  value={formData.name}
                  onChange={(v) => setField('name', v)}
                  placeholder="e.g., puppetlabs-apache"
                  error={errors.name}
                />

                <FormField
                  label="Version"
                  id="version"
                  value={formData.version}
                  onChange={(v) => setField('version', v)}
                  placeholder="e.g., 1.0.0"
                />
              </div>

              {/* Author and License */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <FormField
                  label="Author"
                  id="author"
                  value={formData.author}
                  onChange={(v) => setField('author', v)}
                  placeholder="e.g., Puppet Labs"
                />

                <FormField
                  label="License"
                  id="license"
                  value={formData.license}
                  onChange={(v) => setField('license', v)}
                  placeholder="e.g., Apache-2.0"
                />
              </div>

              {/* Forge Name */}
              <FormField
                label="Forge Name"
                id="forge_name"
                value={formData.forge_name}
                onChange={(v) => setField('forge_name', v)}
                placeholder="e.g., puppetlabs/apache"
                className="font-mono text-sm"
              />

              {/* Description */}
              <FormField
                label="Description"
                id="description"
                type="textarea"
                rows={2}
                value={formData.description}
                onChange={(v) => setField('description', v)}
                placeholder="Module description"
              />

              {/* URLs */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <FormField
                  label="Source URL"
                  id="source_url"
                  value={formData.source_url}
                  onChange={(v) => setField('source_url', v)}
                  placeholder="https://github.com/..."
                />

                <FormField
                  label="Project URL"
                  id="project_url"
                  value={formData.project_url}
                  onChange={(v) => setField('project_url', v)}
                  placeholder="https://forge.puppet.com/..."
                />
              </div>

              {/* Dependencies */}
              <FormField
                label="Dependencies (JSON Array)"
                id="dependencies"
                type="textarea"
                rows={3}
                value={formData.dependencies}
                onChange={(v) => setField('dependencies', v)}
                placeholder='[{"name": "puppetlabs/stdlib", "version_requirement": ">= 4.0.0"}]'
                className="font-mono text-sm"
                error={errors.dependencies}
              />

              {/* Configuration */}
              <FormField
                label="Configuration (JSON)"
                id="config"
                type="textarea"
                rows={3}
                value={formData.config}
                onChange={(v) => setField('config', v)}
                className="font-mono text-sm"
                error={errors.config}
              />

              {/* Metadata */}
              <FormField
                label="Metadata (JSON)"
                id="metadata"
                type="textarea"
                rows={3}
                value={formData.metadata}
                onChange={(v) => setField('metadata', v)}
                className="font-mono text-sm"
                error={errors.metadata}
              />

              {/* Checkboxes */}
              <div className="flex flex-col sm:flex-row sm:items-center gap-4">
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="enabled"
                    checked={formData.enabled}
                    onChange={handleChange}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
                  />
                  <span className="text-sm text-theme-primary">Enabled</span>
                </label>

                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="public"
                    checked={formData.public}
                    onChange={handleChange}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
                  />
                  <span className="text-sm text-theme-primary">Public</span>
                </label>
              </div>
            </div>

            <div className="flex justify-end gap-3 p-4 border-t border-theme">
              <Button type="button" variant="outline" onClick={onClose}>
                Cancel
              </Button>
              <Button type="submit" variant="primary" disabled={submitting}>
                {submitting ? (
                  <>
                    <LoadingSpinner size="sm" className="mr-2" />
                    {isEditMode ? 'Updating...' : 'Creating...'}
                  </>
                ) : (
                  isEditMode ? 'Update Module' : 'Add Module'
                )}
              </Button>
            </div>
          </form>
    </Modal>
  );
};

export default PuppetModuleFormModal;
