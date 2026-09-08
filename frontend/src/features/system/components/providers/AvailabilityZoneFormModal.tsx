import React, { useState, useEffect } from 'react';
import { X, Layers, AlertCircle } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
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

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-[60] overflow-y-auto">
      <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={onClose} />

      <div className="flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-lg bg-theme-surface rounded-lg shadow-xl">
          <div className="flex items-center justify-between p-4 border-b border-theme">
            <div className="flex items-center gap-3">
              <Layers className="w-6 h-6 text-theme-info-fg" />
              <h2 className="text-lg font-semibold text-theme-primary">
                {isEditMode ? 'Edit Availability Zone' : 'Add Availability Zone'}
              </h2>
              {manualOverride && (
                <Badge variant="warning" size="xs">Manual override</Badge>
              )}
            </div>
            <Button variant="ghost" size="sm" onClick={onClose}>
              <X className="w-5 h-5" />
            </Button>
          </div>

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
                <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor="zone-name">
                  Name <span className="text-theme-error-fg">*</span>
                </label>
                <input
                  id="zone-name"
                  type="text"
                  value={formData.name}
                  onChange={(e) => handleChange('name', e.target.value)}
                  placeholder="Enter zone name"
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
                <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor="zone-code">
                  Zone Code <span className="text-theme-error-fg">*</span>
                </label>
                <input
                  id="zone-code"
                  type="text"
                  value={formData.zone_code}
                  onChange={(e) => handleChange('zone_code', e.target.value)}
                  placeholder="e.g., us-east-1a"
                  className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary font-mono placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
                    errors.zone_code ? 'border-theme-error-border' : 'border-theme'
                  }`}
                  disabled={submitting}
                />
                {errors.zone_code && (
                  <p className="mt-1 text-sm text-theme-error-fg flex items-center gap-1">
                    <AlertCircle className="w-4 h-4" />
                    {errors.zone_code}
                  </p>
                )}
              </div>

              <div>
                <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor="zone-status">
                  Status
                </label>
                <select
                  id="zone-status"
                  value={formData.status}
                  onChange={(e) => handleChange('status', e.target.value)}
                  className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus"
                  disabled={submitting}
                >
                  {STATUS_OPTIONS.map(option => (
                    <option key={option} value={option}>{option}</option>
                  ))}
                </select>
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
                  isEditMode ? 'Update Zone' : 'Add Zone'
                )}
              </Button>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
};

export default AvailabilityZoneFormModal;
