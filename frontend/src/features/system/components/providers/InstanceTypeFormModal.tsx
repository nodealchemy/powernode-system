import React, { useState, useEffect } from 'react';
import { Cpu, AlertCircle } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderInstanceType } from '@system/features/system/types/system.types';

interface InstanceTypeFormModalProps {
  /** Provider that owns this instance type */
  providerId: string;
  /** Instance type to edit (null for create mode) */
  instanceType: SystemProviderInstanceType | null;
  isOpen: boolean;
  onClose: () => void;
  onSaved?: () => void;
  /**
   * True when the provider has a cloud connection, i.e. its catalog is
   * normally populated by sync_catalog. Writing one by hand is then an
   * override that the next sync may reconcile, and the operator is told so.
   */
  manualOverride?: boolean;
}

interface FormData {
  name: string;
  instance_type_code: string;
  description: string;
  vcpus: string;
  memory_mb: string;
  storage_gb: string;
  hourly_price: string;
  enabled: boolean;
}

interface FormErrors {
  name?: string;
  instance_type_code?: string;
  vcpus?: string;
  memory_mb?: string;
  storage_gb?: string;
  hourly_price?: string;
}

const EMPTY: FormData = {
  name: '',
  instance_type_code: '',
  description: '',
  vcpus: '',
  memory_mb: '',
  storage_gb: '',
  hourly_price: '',
  enabled: true
};

/**
 * Parse an optional numeric field.
 *
 * A blank value means different things on the two paths, and conflating them
 * silently discards an edit. On CREATE, omit the key (`undefined`) so the
 * column keeps its default — a blank vcpus must not be recorded as a zero-CPU
 * instance type. On UPDATE, an omitted key leaves the existing value in place,
 * so blanking a populated field has to send an explicit `null` to clear it;
 * otherwise the operator clears the box, is told the update succeeded, and the
 * old value is still there.
 */
function optionalNumber(raw: string, clearWhenBlank: boolean): number | null | undefined {
  const trimmed = raw.trim();
  if (!trimmed) return clearWhenBlank ? null : undefined;
  const parsed = Number(trimmed);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function numericFieldError(raw: string, label: string): string | undefined {
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  const parsed = Number(trimmed);
  if (!Number.isFinite(parsed)) return `${label} must be a number`;
  if (parsed < 0) return `${label} cannot be negative`;
  return undefined;
}

/**
 * InstanceTypeFormModal - create/edit a provider instance type.
 *
 * Instance types are provider-scoped (not region-scoped), matching
 * `providers/:provider_id/instance_types`.
 */
export const InstanceTypeFormModal: React.FC<InstanceTypeFormModalProps> = ({
  providerId,
  instanceType,
  isOpen,
  onClose,
  onSaved,
  manualOverride = false
}) => {
  const { addNotification } = useNotifications();
  const isEditMode = !!instanceType;

  const [submitting, setSubmitting] = useState(false);
  const [formData, setFormData] = useState<FormData>(EMPTY);
  const [errors, setErrors] = useState<FormErrors>({});

  useEffect(() => {
    if (!isOpen) return;
    if (instanceType) {
      setFormData({
        name: instanceType.name,
        instance_type_code: instanceType.instance_type_code || '',
        description: instanceType.description || '',
        vcpus: instanceType.vcpus != null ? String(instanceType.vcpus) : '',
        memory_mb: instanceType.memory_mb != null ? String(instanceType.memory_mb) : '',
        storage_gb: instanceType.storage_gb != null ? String(instanceType.storage_gb) : '',
        hourly_price:
          instanceType.hourly_price != null ? String(instanceType.hourly_price) : '',
        enabled: instanceType.enabled
      });
    } else {
      setFormData(EMPTY);
    }
    setErrors({});
  }, [isOpen, instanceType]);

  const validate = (): boolean => {
    const newErrors: FormErrors = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    }
    if (!formData.instance_type_code.trim()) {
      newErrors.instance_type_code = 'Instance type code is required';
    }
    newErrors.vcpus = numericFieldError(formData.vcpus, 'vCPUs');
    newErrors.memory_mb = numericFieldError(formData.memory_mb, 'Memory');
    newErrors.storage_gb = numericFieldError(formData.storage_gb, 'Storage');
    newErrors.hourly_price = numericFieldError(formData.hourly_price, 'Hourly price');

    const cleaned = Object.fromEntries(
      Object.entries(newErrors).filter(([, v]) => v !== undefined)
    ) as FormErrors;
    setErrors(cleaned);
    return Object.keys(cleaned).length === 0;
  };

  const handleChange = (field: keyof FormData, value: string | boolean) => {
    setFormData(prev => ({ ...prev, [field]: value }));
    if (errors[field as keyof FormErrors]) {
      setErrors(prev => ({ ...prev, [field]: undefined }));
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validate()) return;

    setSubmitting(true);
    try {
      const clearBlanks = isEditMode;
      const payload = {
        name: formData.name.trim(),
        instance_type_code: formData.instance_type_code.trim(),
        description: formData.description.trim() || (clearBlanks ? null : undefined),
        vcpus: optionalNumber(formData.vcpus, clearBlanks),
        memory_mb: optionalNumber(formData.memory_mb, clearBlanks),
        storage_gb: optionalNumber(formData.storage_gb, clearBlanks),
        hourly_price: optionalNumber(formData.hourly_price, clearBlanks),
        enabled: formData.enabled
      };

      if (isEditMode && instanceType) {
        await systemApi.updateProviderInstanceType(providerId, instanceType.id, payload);
        addNotification({
          type: 'success',
          message: `Instance type "${payload.name}" updated successfully`
        });
      } else {
        await systemApi.createProviderInstanceType(providerId, payload);
        addNotification({
          type: 'success',
          message: `Instance type "${payload.name}" created successfully`
        });
      }

      onSaved?.();
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update instance type: ${errorMessage}`
          : `Failed to create instance type: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  const numericField = (
    field: 'vcpus' | 'memory_mb' | 'storage_gb' | 'hourly_price',
    label: string,
    placeholder: string
  ) => (
    <div>
      <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor={`instance-type-${field}`}>
        {label}
      </label>
      <input
        id={`instance-type-${field}`}
        type="text"
        inputMode="decimal"
        value={formData[field]}
        onChange={(e) => handleChange(field, e.target.value)}
        placeholder={placeholder}
        className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary font-mono placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
          errors[field] ? 'border-theme-error-border' : 'border-theme'
        }`}
        disabled={submitting}
      />
      {errors[field] && (
        <p className="mt-1 text-sm text-theme-error-fg flex items-center gap-1">
          <AlertCircle className="w-4 h-4" />
          {errors[field]}
        </p>
      )}
    </div>
  );

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <span className="flex items-center gap-3">
          {isEditMode ? 'Edit Instance Type' : 'Add Instance Type'}
          {manualOverride && (
            <Badge variant="warning" size="xs">Manual override</Badge>
          )}
        </span>
      }
      icon={<Cpu className="w-6 h-6" />}
      maxWidth="lg"
    >

          <form onSubmit={handleSubmit}>
            <div className="p-4 space-y-4 max-h-[60vh] overflow-y-auto">
              {manualOverride && (
                <p className="text-xs text-theme-warning-fg bg-theme-background rounded-lg p-3 border border-theme">
                  This provider has a cloud connection, so its catalog is normally
                  populated by Sync catalog. A hand-written entry is a manual
                  override and a later sync may reconcile it.
                </p>
              )}

              <div>
                <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor="instance-type-name">
                  Name <span className="text-theme-error-fg">*</span>
                </label>
                <input
                  id="instance-type-name"
                  type="text"
                  value={formData.name}
                  onChange={(e) => handleChange('name', e.target.value)}
                  placeholder="Enter instance type name"
                  className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
                    errors.name ? 'border-theme-error-border' : 'border-theme'
                  }`}
                  disabled={submitting}
                />
                {errors.name && (
                  <p className="mt-1 text-sm text-theme-error-fg flex items-center gap-1">
                    <AlertCircle className="w-4 h-4" />
                    {errors.name}
                  </p>
                )}
              </div>

              <div>
                <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor="instance-type-code">
                  Instance Type Code <span className="text-theme-error-fg">*</span>
                </label>
                <input
                  id="instance-type-code"
                  type="text"
                  value={formData.instance_type_code}
                  onChange={(e) => handleChange('instance_type_code', e.target.value)}
                  placeholder="e.g., m5.large"
                  className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary font-mono placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
                    errors.instance_type_code ? 'border-theme-error-border' : 'border-theme'
                  }`}
                  disabled={submitting}
                />
                {errors.instance_type_code && (
                  <p className="mt-1 text-sm text-theme-error-fg flex items-center gap-1">
                    <AlertCircle className="w-4 h-4" />
                    {errors.instance_type_code}
                  </p>
                )}
              </div>

              <div className="grid grid-cols-2 gap-4">
                {numericField('vcpus', 'vCPUs', '4')}
                {numericField('memory_mb', 'Memory (MB)', '16384')}
                {numericField('storage_gb', 'Storage (GB)', '100')}
                {numericField('hourly_price', 'Hourly Price', '0.096')}
              </div>

              <div>
                <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor="instance-type-description">
                  Description
                </label>
                <textarea
                  id="instance-type-description"
                  value={formData.description}
                  onChange={(e) => handleChange('description', e.target.value)}
                  placeholder="Optional description"
                  rows={2}
                  className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus resize-none"
                  disabled={submitting}
                />
              </div>

              <label className="flex items-center gap-2 text-sm text-theme-primary">
                <input
                  type="checkbox"
                  checked={formData.enabled}
                  onChange={(e) => handleChange('enabled', e.target.checked)}
                  disabled={submitting}
                />
                Enabled
              </label>
            </div>

            <div className="flex justify-end gap-3 p-4 border-t border-theme">
              <Button type="button" variant="outline" onClick={onClose} disabled={submitting}>
                Cancel
              </Button>
              <Button type="submit" variant="primary" disabled={submitting}>
                {submitting ? (
                  <>
                    <LoadingSpinner size="sm" className="mr-2" />
                    {isEditMode ? 'Updating...' : 'Creating...'}
                  </>
                ) : (
                  isEditMode ? 'Update Instance Type' : 'Add Instance Type'
                )}
              </Button>
            </div>
          </form>
    </Modal>
  );
};

export default InstanceTypeFormModal;
