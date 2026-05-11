import React, { useEffect, useState } from 'react';
import { X, Cpu, AlertCircle, Lock } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import type { ArchitectureFamily, SystemNodeArchitecture } from '@system/features/system/types/system.types';

interface ArchitectureFormModalProps {
  isOpen: boolean;
  onClose: () => void;
  onArchitectureSaved?: (architecture: SystemNodeArchitecture) => void;
  editArchitecture?: SystemNodeArchitecture | null;
}

const FAMILY_CHOICES: { value: ArchitectureFamily; label: string }[] = [
  { value: 'x86', label: 'x86' },
  { value: 'arm', label: 'ARM' },
  { value: 'power', label: 'Power' },
  { value: 'z', label: 'IBM Z' },
  { value: 'risc-v', label: 'RISC-V' },
  { value: 'mips', label: 'MIPS' },
  { value: 'other', label: 'Other' },
];

interface FormData {
  name: string;
  apt_name: string;
  rpm_name: string;
  display_name: string;
  family: ArchitectureFamily;
  description: string;
  kernel_options: string;
  enabled: boolean;
  public: boolean;
}

const EMPTY: FormData = {
  name: '',
  apt_name: '',
  rpm_name: '',
  display_name: '',
  family: 'other',
  description: '',
  kernel_options: '',
  enabled: true,
  public: false,
};

/**
 * ArchitectureFormModal — create or edit a custom (non-canonical) architecture.
 *
 * Submit gated by `system.architectures.manage`. Canonical rows can be
 * viewed in read-only mode (the modal renders a "canonical, read-only"
 * banner) but the controller refuses mutations.
 */
export const ArchitectureFormModal: React.FC<ArchitectureFormModalProps> = ({
  isOpen,
  onClose,
  onArchitectureSaved,
  editArchitecture
}) => {
  const { addNotification } = useNotifications();
  const { hasPermission } = usePermissions();
  const canManage = hasPermission('system.architectures.manage');

  const [formData, setFormData] = useState<FormData>(EMPTY);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);

  const isEditMode = !!editArchitecture;
  const isCanonical = isEditMode && editArchitecture?.is_canonical === true;
  const isReadOnly = isCanonical || !canManage;

  useEffect(() => {
    if (!isOpen) return;
    if (editArchitecture) {
      setFormData({
        name: editArchitecture.name,
        apt_name: editArchitecture.apt_name ?? '',
        rpm_name: editArchitecture.rpm_name ?? '',
        display_name: editArchitecture.display_name ?? '',
        family: editArchitecture.family ?? 'other',
        description: editArchitecture.description ?? '',
        kernel_options: editArchitecture.kernel_options ?? '',
        enabled: editArchitecture.enabled,
        public: editArchitecture.public,
      });
    } else {
      setFormData(EMPTY);
    }
    setErrors({});
  }, [isOpen, editArchitecture]);

  const handleChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>
  ) => {
    const { name, value, type } = e.target;
    const newValue = type === 'checkbox' ? (e.target as HTMLInputElement).checked : value;
    setFormData((prev) => ({ ...prev, [name]: newValue }));
    if (errors[name]) {
      setErrors((prev) => {
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
    if (!formData.family) newErrors.family = 'Family is required';

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (isReadOnly) return;
    if (!validateForm()) return;

    setSubmitting(true);
    try {
      const payload = {
        name: formData.name,
        family: formData.family,
        apt_name: formData.apt_name.trim() || undefined,
        rpm_name: formData.rpm_name.trim() || undefined,
        display_name: formData.display_name.trim() || undefined,
        description: formData.description.trim() || undefined,
        kernel_options: formData.kernel_options.trim() || undefined,
        enabled: formData.enabled,
        public: formData.public,
      };

      const result = isEditMode && editArchitecture
        ? await systemApi.updateArchitecture(editArchitecture.id, payload)
        : await systemApi.createArchitecture(payload);

      addNotification({
        type: 'success',
        message: isEditMode
          ? `Architecture "${result.name}" updated successfully`
          : `Architecture "${result.name}" created successfully`,
      });
      onArchitectureSaved?.(result);
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update architecture: ${errorMessage}`
          : `Failed to create architecture: ${errorMessage}`,
      });
    } finally {
      setSubmitting(false);
    }
  };

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto">
      <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={onClose} />

      <div className="flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-lg bg-theme-surface rounded-lg shadow-xl">
          <div className="flex items-center justify-between p-4 border-b border-theme">
            <div className="flex items-center gap-3">
              <Cpu className="w-6 h-6 text-theme-info" />
              <h2 className="text-lg font-semibold text-theme-primary">
                {isEditMode ? (isCanonical ? 'Architecture (canonical)' : 'Edit Architecture') : 'Create Architecture'}
              </h2>
            </div>
            <Button variant="ghost" size="sm" onClick={onClose}>
              <X className="w-5 h-5" />
            </Button>
          </div>

          {isCanonical && (
            <div className="mx-4 mt-4 p-3 rounded border border-theme bg-theme-background-secondary text-sm text-theme-secondary flex items-start gap-2">
              <Lock className="w-4 h-4 mt-0.5 flex-shrink-0 text-theme-info" />
              <span>
                This is a seeded canonical architecture — read-only via the API. Evolve via a database migration.
              </span>
            </div>
          )}

          {!canManage && !isCanonical && (
            <div className="mx-4 mt-4 p-3 rounded border border-theme bg-theme-background-secondary text-sm text-theme-secondary flex items-start gap-2">
              <Lock className="w-4 h-4 mt-0.5 flex-shrink-0 text-theme-warning" />
              <span>
                You don't have <code>system.architectures.manage</code> — opening in read-only mode.
              </span>
            </div>
          )}

          <form onSubmit={handleSubmit}>
            <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
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
                  placeholder="e.g., loongarch64"
                  disabled={isReadOnly}
                  className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus disabled:opacity-60 ${
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

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label htmlFor="family" className="block text-sm font-medium text-theme-primary mb-1">
                    Family <span className="text-theme-error">*</span>
                  </label>
                  <select
                    id="family"
                    name="family"
                    value={formData.family}
                    onChange={handleChange}
                    disabled={isReadOnly}
                    className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus disabled:opacity-60"
                  >
                    {FAMILY_CHOICES.map((c) => (
                      <option key={c.value} value={c.value}>{c.label}</option>
                    ))}
                  </select>
                  {errors.family && (
                    <p className="mt-1 text-sm text-theme-error">{errors.family}</p>
                  )}
                </div>

                <div>
                  <label htmlFor="display_name" className="block text-sm font-medium text-theme-primary mb-1">
                    Display name
                  </label>
                  <input
                    type="text"
                    id="display_name"
                    name="display_name"
                    value={formData.display_name}
                    onChange={handleChange}
                    placeholder="Human-friendly label"
                    disabled={isReadOnly}
                    className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus disabled:opacity-60"
                  />
                </div>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label htmlFor="apt_name" className="block text-sm font-medium text-theme-primary mb-1">
                    apt name
                  </label>
                  <input
                    type="text"
                    id="apt_name"
                    name="apt_name"
                    value={formData.apt_name}
                    onChange={handleChange}
                    placeholder="e.g., amd64"
                    disabled={isReadOnly}
                    className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary font-mono text-sm focus:outline-none focus:border-theme-focus disabled:opacity-60"
                  />
                </div>
                <div>
                  <label htmlFor="rpm_name" className="block text-sm font-medium text-theme-primary mb-1">
                    rpm name
                  </label>
                  <input
                    type="text"
                    id="rpm_name"
                    name="rpm_name"
                    value={formData.rpm_name}
                    onChange={handleChange}
                    placeholder="e.g., x86_64"
                    disabled={isReadOnly}
                    className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary font-mono text-sm focus:outline-none focus:border-theme-focus disabled:opacity-60"
                  />
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
                  placeholder="Architecture description"
                  rows={3}
                  disabled={isReadOnly}
                  className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus resize-none disabled:opacity-60"
                />
              </div>

              <div>
                <label htmlFor="kernel_options" className="block text-sm font-medium text-theme-primary mb-1">
                  Kernel Options
                </label>
                <input
                  type="text"
                  id="kernel_options"
                  name="kernel_options"
                  value={formData.kernel_options}
                  onChange={handleChange}
                  placeholder="e.g., console=tty0 console=ttyS0,115200"
                  disabled={isReadOnly}
                  className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus font-mono text-sm disabled:opacity-60"
                />
                <p className="mt-1 text-xs text-theme-secondary">Optional kernel command line parameters</p>
              </div>

              <div className="flex flex-col sm:flex-row sm:items-center gap-4">
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="enabled"
                    checked={formData.enabled}
                    onChange={handleChange}
                    disabled={isReadOnly}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info focus:ring-theme-focus"
                  />
                  <span className="text-sm text-theme-primary">Enabled</span>
                </label>

                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="public"
                    checked={formData.public}
                    onChange={handleChange}
                    disabled={isReadOnly}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info focus:ring-theme-focus"
                  />
                  <span className="text-sm text-theme-primary">Public</span>
                </label>
              </div>
            </div>

            <div className="flex justify-end gap-3 p-4 border-t border-theme">
              <Button type="button" variant="outline" onClick={onClose}>
                {isReadOnly ? 'Close' : 'Cancel'}
              </Button>
              {!isReadOnly && (
                <Button type="submit" variant="primary" disabled={submitting}>
                  {submitting ? (
                    <>
                      <LoadingSpinner size="sm" className="mr-2" />
                      {isEditMode ? 'Updating...' : 'Creating...'}
                    </>
                  ) : (
                    isEditMode ? 'Update Architecture' : 'Create Architecture'
                  )}
                </Button>
              )}
            </div>
          </form>
        </div>
      </div>
    </div>
  );
};

export default ArchitectureFormModal;
