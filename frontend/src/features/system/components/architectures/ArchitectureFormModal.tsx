import React, { useEffect, useState } from 'react';
import { Cpu, Lock } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { FormField } from '@/shared/components/ui/FormField';
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
  // Free-form textarea content; one alias per line or comma-separated.
  // The backend normalizes to a lowercase deduplicated string array.
  aliases_text: string;
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
  aliases_text: '',
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
        // Render the persisted array as one alias per line — easier to scan
        // than comma-separated when the list grows.
        aliases_text: Array(editArchitecture.aliases ?? []).flat().join('\n'),
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
    setField(name, type === 'checkbox' ? (e.target as HTMLInputElement).checked : value);
  };

  // FormField reports a value, the checkboxes still report an event; both land
  // here so the clear-the-error behaviour cannot drift between them.
  const setField = (name: string, value: string | boolean) => {
    setFormData((prev) => ({ ...prev, [name]: value }));
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
      // Split on comma or newline, trim, drop blanks. Backend
      // also normalizes (lowercase + dedupe) — this keeps the wire
      // payload predictable.
      const aliases = formData.aliases_text
        .split(/[,\n]/)
        .map((s) => s.trim())
        .filter(Boolean);

      const payload = {
        name: formData.name,
        family: formData.family,
        apt_name: formData.apt_name.trim() || undefined,
        rpm_name: formData.rpm_name.trim() || undefined,
        display_name: formData.display_name.trim() || undefined,
        description: formData.description.trim() || undefined,
        kernel_options: formData.kernel_options.trim() || undefined,
        aliases,
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

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditMode ? (isCanonical ? 'Architecture (canonical)' : 'Edit Architecture') : 'Create Architecture'}
      icon={<Cpu className="w-6 h-6" />}
      maxWidth="lg"
    >
          {isCanonical && (
            <div className="mb-4 p-3 rounded border border-theme bg-theme-background-secondary text-sm text-theme-secondary flex items-start gap-2">
              <Lock className="w-4 h-4 mt-0.5 flex-shrink-0 text-theme-info-fg" />
              <span>
                This is a seeded canonical architecture — read-only via the API. Evolve via a database migration.
              </span>
            </div>
          )}

          {!canManage && !isCanonical && (
            <div className="mx-4 mt-4 p-3 rounded border border-theme bg-theme-background-secondary text-sm text-theme-secondary flex items-start gap-2">
              <Lock className="w-4 h-4 mt-0.5 flex-shrink-0 text-theme-warning-fg" />
              <span>
                You don't have <code>system.architectures.manage</code> — opening in read-only mode.
              </span>
            </div>
          )}

          <form onSubmit={handleSubmit}>
            <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
              <FormField
                label="Name"
                id="name"
                required
                disabled={isReadOnly}
                value={formData.name}
                onChange={(v) => setField('name', v)}
                placeholder="e.g., loongarch64"
                error={errors.name}
              />

              <div className="grid grid-cols-2 gap-3">
                <FormField
                  label="Family"
                  id="family"
                  type="select"
                  required
                  disabled={isReadOnly}
                  value={formData.family}
                  onChange={(v) => setField('family', v)}
                  error={errors.family}
                  options={FAMILY_CHOICES.map((c) => ({ value: c.value, label: c.label }))}
                />

                <FormField
                  label="Display name"
                  id="display_name"
                  disabled={isReadOnly}
                  value={formData.display_name}
                  onChange={(v) => setField('display_name', v)}
                  placeholder="Human-friendly label"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <FormField
                  label="apt name"
                  id="apt_name"
                  className="font-mono text-sm"
                  disabled={isReadOnly}
                  value={formData.apt_name}
                  onChange={(v) => setField('apt_name', v)}
                  placeholder="e.g., amd64"
                />
                <FormField
                  label="rpm name"
                  id="rpm_name"
                  className="font-mono text-sm"
                  disabled={isReadOnly}
                  value={formData.rpm_name}
                  onChange={(v) => setField('rpm_name', v)}
                  placeholder="e.g., x86_64"
                />
              </div>

              <FormField
                label="Description"
                id="description"
                type="textarea"
                rows={3}
                disabled={isReadOnly}
                value={formData.description}
                onChange={(v) => setField('description', v)}
                placeholder="Architecture description"
              />

              <FormField
                label="Kernel Options"
                id="kernel_options"
                className="font-mono text-sm"
                disabled={isReadOnly}
                value={formData.kernel_options}
                onChange={(v) => setField('kernel_options', v)}
                placeholder="e.g., console=tty0 console=ttyS0,115200"
                helpText="Optional kernel command line parameters"
              />

              <div>
                <FormField
                  label="Aliases"
                  id="aliases_text"
                  type="textarea"
                  rows={3}
                  className="font-mono text-sm"
                  disabled={isReadOnly}
                  value={formData.aliases_text}
                  onChange={(v) => setField('aliases_text', v)}
                  placeholder={`amd64-graviton\nx86_64-v3\naarch64-pacbti`}
                />
                <p className="mt-1 text-xs text-theme-secondary">
                  One alias per line (or comma-separated). Vendor-specific tags that should resolve to this architecture — e.g. <code>amd64-graviton</code>, <code>x86_64-v3</code>. Saved lowercased and deduplicated.
                </p>
              </div>

              <div className="flex flex-col sm:flex-row sm:items-center gap-4">
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="enabled"
                    checked={formData.enabled}
                    onChange={handleChange}
                    disabled={isReadOnly}
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
                    disabled={isReadOnly}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
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
    </Modal>
  );
};

export default ArchitectureFormModal;
