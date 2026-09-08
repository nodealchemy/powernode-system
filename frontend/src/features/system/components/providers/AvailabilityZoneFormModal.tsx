import React, { useState, useEffect } from 'react';
import { Layers } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderAvailabilityZone } from '@system/features/system/types/system.types';

type ZoneStatus = 'available' | 'impaired' | 'unavailable';

interface AvailabilityZoneFormModalProps {
  /** Provider that owns the region */
  providerId: string;
  /** Region this zone belongs to */
  regionId: string;
  /** Zone to edit (null for create mode) */
  zone: SystemProviderAvailabilityZone | null;
  isOpen: boolean;
  onClose: () => void;
  onSaved?: () => void;
  /** See InstanceTypeFormModal — set when the provider has a cloud connection. */
  manualOverride?: boolean;
}

interface FormData {
  name: string;
  zone_code: string;
  status: ZoneStatus;
  enabled: boolean;
}

interface FormErrors {
  name?: string;
  zone_code?: string;
}

const EMPTY: FormData = {
  name: '',
  zone_code: '',
  status: 'available',
  enabled: true
};

const STATUS_OPTIONS: ZoneStatus[] = ['available', 'impaired', 'unavailable'];

/**
 * AvailabilityZoneFormModal - create/edit an availability zone under a region.
 * Matches `providers/:provider_id/regions/:region_id/availability_zones`.
 */
export const AvailabilityZoneFormModal: React.FC<AvailabilityZoneFormModalProps> = ({
  providerId,
  regionId,
  zone,
  isOpen,
  onClose,
  onSaved,
  manualOverride = false
}) => {
  const { addNotification } = useNotifications();
  const isEditMode = !!zone;

  const [submitting, setSubmitting] = useState(false);
  const [formData, setFormData] = useState<FormData>(EMPTY);
  const [errors, setErrors] = useState<FormErrors>({});

  useEffect(() => {
    if (!isOpen) return;
    if (zone) {
      setFormData({
        name: zone.name,
        zone_code: zone.zone_code || '',
        status: zone.status,
        enabled: zone.enabled
      });
    } else {
      setFormData(EMPTY);
    }
    setErrors({});
  }, [isOpen, zone]);

  const validate = (): boolean => {
    const newErrors: FormErrors = {};
    if (!formData.name.trim()) newErrors.name = 'Name is required';
    if (!formData.zone_code.trim()) newErrors.zone_code = 'Zone code is required';
    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
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
      const payload = {
        name: formData.name.trim(),
        zone_code: formData.zone_code.trim(),
        status: formData.status,
        enabled: formData.enabled
      };

      if (isEditMode && zone) {
        await systemApi.updateProviderAvailabilityZone(providerId, regionId, zone.id, payload);
        addNotification({
          type: 'success',
          message: `Availability zone "${payload.name}" updated successfully`
        });
      } else {
        await systemApi.createProviderAvailabilityZone(providerId, regionId, payload);
        addNotification({
          type: 'success',
          message: `Availability zone "${payload.name}" created successfully`
        });
      }

      onSaved?.();
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update availability zone: ${errorMessage}`
          : `Failed to create availability zone: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <span className="flex items-center gap-3">
          {isEditMode ? 'Edit Availability Zone' : 'Add Availability Zone'}
          {manualOverride && (
            <Badge variant="warning" size="xs">Manual override</Badge>
          )}
        </span>
      }
      icon={<Layers className="w-6 h-6" />}
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
                id="zone-name"
                required
                value={formData.name}
                onChange={(v) => handleChange('name', v)}
                placeholder="Enter zone name"
                error={errors.name}
                disabled={submitting}
              />

              <FormField
                label="Zone Code"
                id="zone-code"
                required
                value={formData.zone_code}
                onChange={(v) => handleChange('zone_code', v)}
                placeholder="e.g., us-east-1a"
                className="font-mono"
                error={errors.zone_code}
                disabled={submitting}
              />

              <FormField
                label="Status"
                id="zone-status"
                type="select"
                value={formData.status}
                onChange={(v) => handleChange('status', v)}
                disabled={submitting}
                options={STATUS_OPTIONS.map(option => ({ value: option, label: option }))}
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
                  isEditMode ? 'Update Zone' : 'Add Zone'
                )}
              </Button>
            </div>
          </form>
    </Modal>
  );
};

export default AvailabilityZoneFormModal;
