import React, { useState, useEffect } from 'react';
import { X, Package, AlertCircle, FileUp, Lock, Power } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeModule, SystemNodePlatform, SystemNodeModuleCategory } from '@system/features/system/types/system.types';

interface ModuleFormModalProps {
  isOpen: boolean;
  onClose: () => void;
  onModuleSaved?: (module: SystemNodeModule) => void;
  editModule?: SystemNodeModule | null;
}

// Newline-joined glob lines are the operator-friendly shape for the
// five spec fields. The platform's encode_specs callback base64-encodes
// each line on save, so we send strings; the API also accepts arrays
// for programmatic clients.
type SpecField = 'mask' | 'file_spec' | 'package_spec' | 'dependency_spec' | 'protected_spec';

const SPEC_FIELDS: SpecField[] = ['mask', 'file_spec', 'package_spec', 'dependency_spec', 'protected_spec'];

const SPEC_LABELS: Record<SpecField, { title: string; help: string }> = {
  file_spec: {
    title: 'File spec',
    help: 'Paths this module owns and ships in its blob (rsync-glob lines, one per line).',
  },
  mask: {
    title: 'Mask (local exclude)',
    help: 'Paths to exclude from THIS module\'s blob during build (e.g. /var/cache/apt/**). Local rsync filter; does not affect neighbor modules.',
  },
  protected_spec: {
    title: 'Protected spec (claim)',
    help: 'Paths I claim as sensitive. The build pipeline folds these into every neighbor\'s effective_mask, so no other module ships them. Use for /etc/shadow, /etc/ssh/ssh_host_*_key, /etc/sudoers — anything where an overlay-mount override would be a security regression.',
  },
  package_spec: {
    title: 'Package spec',
    help: 'Debian packages installed into the build chroot (one per line).',
  },
  dependency_spec: {
    title: 'Dependency spec',
    help: 'Build-time dependencies between modules (rare; usually empty).',
  },
};

/**
 * ModuleFormModal — create or edit a node module.
 *
 * Includes the full spec surface (mask, file_spec, package_spec,
 * dependency_spec, protected_spec) plus lifecycle controls (init_*,
 * reboot_required, lock_spec). Manifest YAML can be pasted directly
 * via the "Import manifest" button on existing modules.
 */
export const ModuleFormModal: React.FC<ModuleFormModalProps> = ({
  isOpen,
  onClose,
  onModuleSaved,
  editModule
}) => {
  const { addNotification } = useNotifications();

  const blankSpecs: Record<SpecField, string> = {
    mask: '',
    file_spec: '',
    package_spec: '',
    dependency_spec: '',
    protected_spec: '',
  };

  const [formData, setFormData] = useState({
    name: '',
    description: '',
    variety: 'config' as 'config' | 'instance' | 'subscription',
    node_platform_id: '',
    category_id: '',
    priority: 0,
    enabled: true,
    public: false,
    init_start: '',
    init_stop: '',
    init_restart: '',
    reboot_required: false,
    lock_spec: false,
    ...blankSpecs,
  });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);
  const [platforms, setPlatforms] = useState<SystemNodePlatform[]>([]);
  const [categories, setCategories] = useState<SystemNodeModuleCategory[]>([]);
  const [loadingOptions, setLoadingOptions] = useState(true);
  const [showManifestImport, setShowManifestImport] = useState(false);
  const [manifestYaml, setManifestYaml] = useState('');
  const [importing, setImporting] = useState(false);

  const isEditMode = !!editModule;

  useEffect(() => {
    const fetchOptions = async () => {
      try {
        const [platformsData, categoriesData] = await Promise.all([
          systemApi.getPlatforms(),
          systemApi.getModuleCategories()
        ]);
        setPlatforms(platformsData);
        setCategories(categoriesData);
      } catch {
        addNotification({
          type: 'error',
          message: 'Failed to load form options'
        });
      } finally {
        setLoadingOptions(false);
      }
    };

    if (isOpen) {
      fetchOptions();
    }
  }, [isOpen, addNotification]);

  useEffect(() => {
    if (isOpen) {
      if (editModule) {
        // *_text fields are pre-decoded newline-joined strings from the API.
        // Strip trailing newlines so the textarea doesn't always show a
        // blank trailing row on edit.
        const stripTrailing = (s?: string) => (s ?? '').replace(/\n+$/, '');
        setFormData({
          name: editModule.name,
          description: editModule.description || '',
          variety: editModule.variety,
          node_platform_id: editModule.node_platform_id || '',
          category_id: editModule.category_id || '',
          priority: editModule.priority || 0,
          enabled: editModule.enabled,
          public: editModule.public,
          init_start: editModule.init_start || '',
          init_stop: editModule.init_stop || '',
          init_restart: editModule.init_restart || '',
          reboot_required: editModule.reboot_required ?? false,
          lock_spec: editModule.lock_spec ?? false,
          mask:            stripTrailing(editModule.mask_text),
          file_spec:       stripTrailing(editModule.file_spec_text),
          package_spec:    stripTrailing(editModule.package_spec_text),
          dependency_spec: stripTrailing(editModule.dependency_spec_text),
          protected_spec:  stripTrailing(editModule.protected_spec_text),
        });
      } else {
        setFormData({
          name: '',
          description: '',
          variety: 'config',
          node_platform_id: '',
          category_id: '',
          priority: 0,
          enabled: true,
          public: false,
          init_start: '',
          init_stop: '',
          init_restart: '',
          reboot_required: false,
          lock_spec: false,
          ...blankSpecs,
        });
      }
      setErrors({});
      setShowManifestImport(false);
      setManifestYaml('');
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen, editModule]);

  const handleChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>
  ) => {
    const { name, value, type } = e.target;
    const newValue = type === 'checkbox' ? (e.target as HTMLInputElement).checked : value;
    setFormData(prev => ({ ...prev, [name]: newValue }));
    if (errors[name]) {
      setErrors(prev => {
        const next = { ...prev };
        delete next[name];
        return next;
      });
    }
  };

  const validateForm = (): boolean => {
    const newErrors: Record<string, string> = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Name must be at least 2 characters';
    }

    if (!formData.variety) {
      newErrors.variety = 'Type is required';
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
        variety: formData.variety,
        node_platform_id: formData.node_platform_id || undefined,
        category_id: formData.category_id || undefined,
        priority: formData.priority,
        enabled: formData.enabled,
        public: formData.public,
        // Spec fields as newline-joined strings — backend's encode_specs
        // callback handles base64 encoding on save.
        mask:            formData.mask,
        file_spec:       formData.file_spec,
        package_spec:    formData.package_spec,
        dependency_spec: formData.dependency_spec,
        protected_spec:  formData.protected_spec,
        // Lifecycle / lock
        init_start:      formData.init_start || undefined,
        init_stop:       formData.init_stop || undefined,
        init_restart:    formData.init_restart || undefined,
        reboot_required: formData.reboot_required,
        lock_spec:       formData.lock_spec,
      };

      let result: SystemNodeModule;

      if (isEditMode && editModule) {
        result = await systemApi.updateModule(editModule.id, submitData);
        addNotification({
          type: 'success',
          message: `Module "${result.name}" updated successfully`
        });
      } else {
        result = await systemApi.createModule(submitData);
        addNotification({
          type: 'success',
          message: `Module "${result.name}" created successfully`
        });
      }

      onModuleSaved?.(result);
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update module: ${errorMessage}`
          : `Failed to create module: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  const handleManifestImport = async () => {
    if (!editModule || !manifestYaml.trim()) return;

    setImporting(true);
    try {
      const result = await systemApi.importManifest(editModule.id, manifestYaml);
      addNotification({
        type: 'success',
        message: `Manifest imported. ${result.resolved_dependencies.length} dependency reference(s) processed.`
      });
      // Hydrate the form with the imported values.
      const stripTrailing = (s?: string) => (s ?? '').replace(/\n+$/, '');
      setFormData(prev => ({
        ...prev,
        description:     result.node_module.description || prev.description,
        init_start:      result.node_module.init_start || '',
        init_stop:       result.node_module.init_stop || '',
        init_restart:    result.node_module.init_restart || '',
        reboot_required: result.node_module.reboot_required ?? prev.reboot_required,
        mask:            stripTrailing(result.node_module.mask_text),
        file_spec:       stripTrailing(result.node_module.file_spec_text),
        package_spec:    stripTrailing(result.node_module.package_spec_text),
        dependency_spec: stripTrailing(result.node_module.dependency_spec_text),
        protected_spec:  stripTrailing(result.node_module.protected_spec_text),
      }));
      setShowManifestImport(false);
      setManifestYaml('');
      onModuleSaved?.(result.node_module);
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Import failed';
      addNotification({
        type: 'error',
        message: `Manifest import failed: ${errorMessage}`
      });
    } finally {
      setImporting(false);
    }
  };

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto">
      <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={onClose} />

      <div className="flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-3xl bg-theme-surface rounded-lg shadow-xl">
          <div className="flex items-center justify-between p-4 border-b border-theme">
            <div className="flex items-center gap-3">
              <Package className="w-6 h-6 text-theme-accent" />
              <h2 className="text-lg font-semibold text-theme-primary">
                {isEditMode ? 'Edit Module' : 'Create Module'}
              </h2>
            </div>
            <div className="flex items-center gap-2">
              {isEditMode && (
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  onClick={() => setShowManifestImport(prev => !prev)}
                  title="Paste a manifest.yaml to populate the spec fields"
                >
                  <FileUp className="w-4 h-4" />
                  Import manifest
                </Button>
              )}
              <Button variant="ghost" size="sm" onClick={onClose}>
                <X className="w-5 h-5" />
              </Button>
            </div>
          </div>

          {showManifestImport && (
            <div className="p-4 border-b border-theme bg-theme-background-elevated">
              <label htmlFor="manifest_yaml" className="block text-sm font-medium text-theme-primary mb-1">
                Paste manifest.yaml
              </label>
              <p className="text-xs text-theme-secondary mb-2">
                The server validates schema_version + name match, parses the spec fields,
                resolves dependencies by gitea_repo_full_name or plain name, and writes
                everything onto this module. The form below will repopulate from the
                imported values; you can adjust before saving.
              </p>
              <textarea
                id="manifest_yaml"
                value={manifestYaml}
                onChange={(e) => setManifestYaml(e.target.value)}
                rows={10}
                placeholder={`schema_version: 1\nname: ${editModule?.name ?? 'my-module'}\nfile_spec:\n  - "/etc/foo/**"\nprotected_spec:\n  - "/etc/foo/secret"\n...`}
                className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary font-mono text-sm placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
              />
              <div className="flex justify-end gap-2 mt-2">
                <Button type="button" variant="outline" size="sm" onClick={() => setShowManifestImport(false)}>
                  Cancel
                </Button>
                <Button
                  type="button"
                  variant="primary"
                  size="sm"
                  onClick={handleManifestImport}
                  disabled={importing || !manifestYaml.trim()}
                >
                  {importing ? <LoadingSpinner size="sm" /> : 'Import'}
                </Button>
              </div>
            </div>
          )}

          <form onSubmit={handleSubmit}>
            <div className="p-4 space-y-6 max-h-[70vh] overflow-y-auto">
              {/* Basic Info */}
              <div className="space-y-4">
                <h3 className="text-sm font-medium text-theme-primary">Basic Information</h3>
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <div>
                    <label htmlFor="name" className="block text-sm font-medium text-theme-primary mb-1">
                      Name <span className="text-theme-error">*</span>
                    </label>
                    <input
                      type="text"
                      id="name"
                      name="name"
                      value={formData.name}
                      onChange={handleChange}
                      placeholder="e.g., nginx-config"
                      className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
                        errors.name ? 'border-theme-error' : 'border-theme'
                      }`}
                    />
                    {errors.name && (
                      <p className="mt-1 text-sm text-theme-error flex items-center gap-1">
                        <AlertCircle className="w-4 h-4" />
                        {errors.name}
                      </p>
                    )}
                  </div>

                  <div>
                    <label htmlFor="variety" className="block text-sm font-medium text-theme-primary mb-1">
                      Type <span className="text-theme-error">*</span>
                    </label>
                    <select
                      id="variety"
                      name="variety"
                      value={formData.variety}
                      onChange={handleChange}
                      className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus ${
                        errors.variety ? 'border-theme-error' : 'border-theme'
                      }`}
                    >
                      <option value="config">Config</option>
                      <option value="instance">Instance</option>
                      <option value="subscription">Subscription</option>
                    </select>
                  </div>
                </div>

                <div>
                  <label htmlFor="description" className="block text-sm font-medium text-theme-primary mb-1">
                    Description
                  </label>
                  <textarea
                    id="description"
                    name="description"
                    value={formData.description}
                    onChange={handleChange}
                    placeholder="Module description"
                    rows={2}
                    className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus resize-none"
                  />
                </div>
              </div>

              {/* Classification */}
              <div className="space-y-4">
                <h3 className="text-sm font-medium text-theme-primary">Classification</h3>
                <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
                  <div>
                    <label htmlFor="node_platform_id" className="block text-sm font-medium text-theme-primary mb-1">
                      Platform
                    </label>
                    {loadingOptions ? (
                      <div className="flex items-center justify-center py-2">
                        <LoadingSpinner size="sm" />
                      </div>
                    ) : (
                      <select
                        id="node_platform_id"
                        name="node_platform_id"
                        value={formData.node_platform_id}
                        onChange={handleChange}
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus"
                      >
                        <option value="">Select platform (optional)</option>
                        {platforms.map((platform) => (
                          <option key={platform.id} value={platform.id}>{platform.name}</option>
                        ))}
                      </select>
                    )}
                  </div>

                  <div>
                    <label htmlFor="category_id" className="block text-sm font-medium text-theme-primary mb-1">
                      Category
                    </label>
                    {loadingOptions ? (
                      <div className="flex items-center justify-center py-2">
                        <LoadingSpinner size="sm" />
                      </div>
                    ) : (
                      <select
                        id="category_id"
                        name="category_id"
                        value={formData.category_id}
                        onChange={handleChange}
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus"
                      >
                        <option value="">Select category (optional)</option>
                        {categories.map((category) => (
                          <option key={category.id} value={category.id}>
                            {'—'.repeat(category.depth)} {category.name}
                          </option>
                        ))}
                      </select>
                    )}
                  </div>

                  <div>
                    <label htmlFor="priority" className="block text-sm font-medium text-theme-primary mb-1">
                      Priority
                    </label>
                    <input
                      type="number"
                      id="priority"
                      name="priority"
                      value={formData.priority}
                      onChange={handleChange}
                      min={0}
                      className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus"
                    />
                  </div>
                </div>
              </div>

              {/* Spec fields (one textarea per field, newline-separated globs) */}
              <div className="space-y-4">
                <h3 className="text-sm font-medium text-theme-primary">Specifications</h3>
                <p className="text-xs text-theme-secondary">
                  One rsync-glob line per row. The platform stores these base64-encoded
                  internally; the form decodes / encodes for you.
                </p>

                {SPEC_FIELDS.map((field) => (
                  <div key={field}>
                    <label htmlFor={field} className="block text-sm font-medium text-theme-primary mb-1">
                      {SPEC_LABELS[field].title}
                    </label>
                    <p className="text-xs text-theme-secondary mb-1">{SPEC_LABELS[field].help}</p>
                    <textarea
                      id={field}
                      name={field}
                      value={formData[field]}
                      onChange={handleChange}
                      rows={field === 'file_spec' || field === 'protected_spec' ? 5 : 3}
                      placeholder={
                        field === 'file_spec' ? '/etc/foo/**\n/usr/bin/foo' :
                        field === 'mask' ? '/var/cache/apt/**\n/usr/share/doc/**' :
                        field === 'protected_spec' ? '/etc/secret\n/etc/policy/**' :
                        field === 'package_spec' ? 'foo\nfoo-extras' :
                        ''
                      }
                      className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus resize-y font-mono text-sm"
                    />
                  </div>
                ))}
              </div>

              {/* Lifecycle */}
              <div className="space-y-4">
                <h3 className="text-sm font-medium text-theme-primary">Lifecycle</h3>
                <p className="text-xs text-theme-secondary">
                  Commands the on-node powernode-agent executes when this module is
                  attached, detached, or hot-reloaded. Each is run as a subprocess
                  (NEVER eval&apos;d).
                </p>
                <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
                  <div>
                    <label htmlFor="init_start" className="block text-sm text-theme-secondary mb-1">init_start</label>
                    <input
                      type="text"
                      id="init_start"
                      name="init_start"
                      value={formData.init_start}
                      onChange={handleChange}
                      placeholder="systemctl start foo"
                      className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary font-mono text-sm focus:outline-none focus:border-theme-focus"
                    />
                  </div>
                  <div>
                    <label htmlFor="init_stop" className="block text-sm text-theme-secondary mb-1">init_stop</label>
                    <input
                      type="text"
                      id="init_stop"
                      name="init_stop"
                      value={formData.init_stop}
                      onChange={handleChange}
                      placeholder="systemctl stop foo"
                      className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary font-mono text-sm focus:outline-none focus:border-theme-focus"
                    />
                  </div>
                  <div>
                    <label htmlFor="init_restart" className="block text-sm text-theme-secondary mb-1">init_restart</label>
                    <input
                      type="text"
                      id="init_restart"
                      name="init_restart"
                      value={formData.init_restart}
                      onChange={handleChange}
                      placeholder="systemctl reload foo"
                      className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary font-mono text-sm focus:outline-none focus:border-theme-focus"
                    />
                  </div>
                </div>

                <div className="flex flex-col sm:flex-row sm:items-center gap-4">
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="checkbox"
                      name="reboot_required"
                      checked={formData.reboot_required}
                      onChange={handleChange}
                      className="w-4 h-4 rounded border-theme bg-theme-background text-theme-accent focus:ring-theme-focus"
                    />
                    <Power className="w-4 h-4 text-theme-secondary" />
                    <span className="text-sm text-theme-primary">Reboot required on attach/detach</span>
                  </label>

                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="checkbox"
                      name="lock_spec"
                      checked={formData.lock_spec}
                      onChange={handleChange}
                      className="w-4 h-4 rounded border-theme bg-theme-background text-theme-accent focus:ring-theme-focus"
                    />
                    <Lock className="w-4 h-4 text-theme-secondary" />
                    <span className="text-sm text-theme-primary">Lock module (prevent further spec edits)</span>
                  </label>
                </div>
              </div>

              {/* Visibility */}
              <div className="space-y-2">
                <h3 className="text-sm font-medium text-theme-primary">Visibility</h3>
                <div className="flex flex-col sm:flex-row sm:items-center gap-4">
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="checkbox"
                      name="enabled"
                      checked={formData.enabled}
                      onChange={handleChange}
                      className="w-4 h-4 rounded border-theme bg-theme-background text-theme-accent focus:ring-theme-focus"
                    />
                    <span className="text-sm text-theme-primary">Enabled</span>
                  </label>

                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="checkbox"
                      name="public"
                      checked={formData.public}
                      onChange={handleChange}
                      className="w-4 h-4 rounded border-theme bg-theme-background text-theme-accent focus:ring-theme-focus"
                    />
                    <span className="text-sm text-theme-primary">Public</span>
                  </label>
                </div>
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
                  isEditMode ? 'Update Module' : 'Create Module'
                )}
              </Button>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
};

export default ModuleFormModal;
