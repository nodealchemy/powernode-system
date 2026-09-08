import React, { useState, useEffect } from 'react';
import { Cpu } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
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

  // Typed as text with a decimal keypad rather than type="number", so a
  // half-entered value is not discarded while the operator is still typing.
  const numericField = (
    field: 'vcpus' | 'memory_mb' | 'storage_gb' | 'hourly_price',
    label: string,
    placeholder: string
  ) => (
    <FormField
      label={label}
      id={`instance-type-${field}`}
      inputMode="decimal"
      value={formData[field]}
      onChange={(v) => handleChange(field, v)}
      placeholder={placeholder}
      className="font-mono"
      error={errors[field]}
      disabled={submitting}
    />
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
            <div className="space-y-4">
              {manualOverride && (
                <p className="text-xs text-theme-warning-fg bg-theme-background rounded-lg p-3 border border-theme">
                  This provider has a cloud connection, so its catalog is normally
                  populated by Sync catalog. A hand-written entry is a manual
                  override and a later sync may reconcile it.
                </p>
              )}

              <FormField
                label="Name"
                id="instance-type-name"
                required
                value={formData.name}
                onChange={(v) => handleChange('name', v)}
                placeholder="Enter instance type name"
                error={errors.name}
                disabled={submitting}
              />

              <FormField
                label="Instance Type Code"
                id="instance-type-code"
                required
                value={formData.instance_type_code}
                onChange={(v) => handleChange('instance_type_code', v)}
                placeholder="e.g., m5.large"
                className="font-mono"
                error={errors.instance_type_code}
                disabled={submitting}
              />

              <div className="grid grid-cols-2 gap-4">
                {numericField('vcpus', 'vCPUs', '4')}
                {numericField('memory_mb', 'Memory (MB)', '16384')}
                {numericField('storage_gb', 'Storage (GB)', '100')}
                {numericField('hourly_price', 'Hourly Price', '0.096')}
              </div>

              <FormField
                label="Description"
                id="instance-type-description"
                type="textarea"
                rows={2}
                value={formData.description}
                onChange={(v) => handleChange('description', v)}
                placeholder="Optional description"
                disabled={submitting}
              />

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
