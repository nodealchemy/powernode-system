import React, { useState, useEffect } from 'react';
import { HardDrive } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { FormField } from '@/shared/components/ui/FormField';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderVolume, SystemProviderRegion } from '@system/features/system/types/system.types';

interface VolumeFormModalProps {
  /** Volume to edit (null for create mode) */
  volume: SystemProviderVolume | null;
  /** Whether the modal is open */
  isOpen: boolean;
  /** Callback when modal is closed */
  onClose: () => void;
  /** Callback when volume is saved */
  onVolumeSaved?: (volume: SystemProviderVolume) => void;
}

interface FormData {
  name: string;
  description: string;
  provider_region_id: string;
  volume_type: string;
  size_gb: number;
  iops: number | null;
  throughput: number | null;
  encrypted: boolean;
}

interface FormErrors {
  name?: string;
  size_gb?: string;
  provider_region_id?: string;
}

const volumeTypes = [
  { value: 'gp3', label: 'General Purpose SSD (gp3)', supportsIops: true, supportsThroughput: true },
  { value: 'gp2', label: 'General Purpose SSD (gp2)', supportsIops: false, supportsThroughput: false },
  { value: 'io2', label: 'Provisioned IOPS SSD (io2)', supportsIops: true, supportsThroughput: false },
  { value: 'io1', label: 'Provisioned IOPS SSD (io1)', supportsIops: true, supportsThroughput: false },
  { value: 'st1', label: 'Throughput Optimized HDD', supportsIops: false, supportsThroughput: false },
  { value: 'sc1', label: 'Cold HDD', supportsIops: false, supportsThroughput: false },
  { value: 'standard', label: 'Magnetic (Previous Gen)', supportsIops: false, supportsThroughput: false }
];

/**
 * VolumeFormModal - Modal for creating/editing volumes
 */
export const VolumeFormModal: React.FC<VolumeFormModalProps> = ({
  volume,
  isOpen,
  onClose,
  onVolumeSaved
}) => {
  const { addNotification } = useNotifications();
  const isEditMode = !!volume;

  // State
  const [submitting, setSubmitting] = useState(false);
  const [regions, setRegions] = useState<SystemProviderRegion[]>([]);
  const [loadingRegions, setLoadingRegions] = useState(true);
  const [formData, setFormData] = useState<FormData>({
    name: '',
    description: '',
    provider_region_id: '',
    volume_type: 'gp3',
    size_gb: 100,
    iops: null,
    throughput: null,
    encrypted: true
  });
  const [errors, setErrors] = useState<FormErrors>({});

  // Fetch regions
  useEffect(() => {
    const fetchRegions = async () => {
      try {
        // Get all providers and their regions
        const providers = await systemApi.getProviders();
        const allRegions: SystemProviderRegion[] = [];

        for (const provider of providers) {
          const providerRegions = await systemApi.getProviderRegions(provider.id);
          allRegions.push(...providerRegions.map(r => ({
            ...r,
            provider_name: provider.name
          })));
        }

        setRegions(allRegions);
      } catch (error) {
        addNotification({
          type: 'error',
          message: 'Failed to load regions'
        });
      } finally {
        setLoadingRegions(false);
      }
    };

    if (isOpen) {
      fetchRegions();
    }
  }, [isOpen, addNotification]);

  // Initialize form
  useEffect(() => {
    if (isOpen) {
      if (volume) {
        setFormData({
          name: volume.name,
          description: volume.description || '',
          provider_region_id: volume.provider_region_id,
          volume_type: volume.volume_type,
          size_gb: volume.size_gb,
          iops: volume.iops || null,
          throughput: volume.throughput || null,
          encrypted: volume.encrypted
        });
      } else {
        setFormData({
          name: '',
          description: '',
          provider_region_id: '',
          volume_type: 'gp3',
          size_gb: 100,
          iops: null,
          throughput: null,
          encrypted: true
        });
      }
      setErrors({});
    }
  }, [isOpen, volume]);

  // Get selected volume type config
  const selectedType = volumeTypes.find(t => t.value === formData.volume_type);

  // Validate form
  const validate = (): boolean => {
    const newErrors: FormErrors = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Name must be at least 2 characters';
    }

    if (!formData.provider_region_id) {
      newErrors.provider_region_id = 'Region is required';
    }

    if (formData.size_gb < 1) {
      newErrors.size_gb = 'Size must be at least 1 GB';
    } else if (formData.size_gb > 16384) {
      newErrors.size_gb = 'Size cannot exceed 16 TB';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  // Handle field change
  const handleChange = (field: keyof FormData, value: string | number | boolean | null) => {
    setFormData(prev => ({ ...prev, [field]: value }));
    if (errors[field as keyof FormErrors]) {
      setErrors(prev => ({ ...prev, [field]: undefined }));
    }
  };

  // Handle submit
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!validate()) {
      return;
    }

    setSubmitting(true);

    try {
      let savedVolume: SystemProviderVolume;

      const payload = {
        name: formData.name.trim(),
        description: formData.description.trim() || undefined,
        provider_region_id: formData.provider_region_id,
        volume_type: formData.volume_type,
        size_gb: formData.size_gb,
        iops: selectedType?.supportsIops ? formData.iops || undefined : undefined,
        throughput: selectedType?.supportsThroughput ? formData.throughput || undefined : undefined,
        encrypted: formData.encrypted
      };

      if (isEditMode && volume) {
        savedVolume = await systemApi.updateVolume(volume.id, payload);
        addNotification({
          type: 'success',
          message: `Volume "${savedVolume.name}" updated successfully`
        });
      } else {
        savedVolume = await systemApi.createVolume(payload);
        addNotification({
          type: 'success',
          message: `Volume "${savedVolume.name}" created successfully`
        });
      }

      onVolumeSaved?.(savedVolume);
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update volume: ${errorMessage}`
          : `Failed to create volume: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditMode ? 'Edit Volume' : 'Create Volume'}
      icon={<HardDrive className="w-6 h-6" />}
      maxWidth="lg"
    >
          {/* Form */}
          <form onSubmit={handleSubmit}>
            <div className="space-y-4">
              {/* Name */}
              <FormField
                label="Name"
                required
                disabled={submitting}
                value={formData.name}
                onChange={(v) => handleChange('name', v)}
                placeholder="Enter volume name"
                error={errors.name}
              />

              {/* Description */}
              <FormField
                label="Description"
                type="textarea"
                rows={2}
                disabled={submitting}
                value={formData.description}
                onChange={(v) => handleChange('description', v)}
                placeholder="Optional description"
              />

              {/* Region */}
              {loadingRegions ? (
                <div>
                  <label className="block text-sm font-medium text-theme-primary mb-1">
                    Region <span className="text-theme-error-fg">*</span>
                  </label>
                  <div className="flex items-center justify-center py-2">
                    <LoadingSpinner size="sm" />
                  </div>
                </div>
              ) : (
                <FormField
                  label="Region"
                  type="select"
                  required
                  disabled={submitting || isEditMode}
                  value={formData.provider_region_id}
                  onChange={(v) => handleChange('provider_region_id', v)}
                  error={errors.provider_region_id}
                  options={[
                    { value: '', label: 'Select a region' },
                    ...regions.map((region) => {
                      const providerName = (region as SystemProviderRegion & { provider_name?: string })
                        .provider_name;
                      return {
                        value: region.id,
                        label: `${providerName ? `${providerName} - ` : ''}${region.name} (${region.region_code})`,
                      };
                    }),
                  ]}
                />
              )}

              {/* Volume Type */}
              <FormField
                label="Volume Type"
                type="select"
                disabled={submitting || isEditMode}
                value={formData.volume_type}
                onChange={(v) => handleChange('volume_type', v)}
                options={volumeTypes.map((type) => ({ value: type.value, label: type.label }))}
              />

              {/* Size */}
              <FormField
                label="Size (GB)"
                type="number"
                required
                min={1}
                max={16384}
                disabled={submitting}
                value={String(formData.size_gb)}
                onChange={(v) => handleChange('size_gb', parseInt(v) || 0)}
                error={errors.size_gb}
              />

              {/* IOPS (if supported) */}
              {selectedType?.supportsIops && (
                <FormField
                  label="IOPS (optional)"
                  type="number"
                  min={100}
                  max={64000}
                  disabled={submitting}
                  value={formData.iops ? String(formData.iops) : ''}
                  onChange={(v) => handleChange('iops', v ? parseInt(v) : null)}
                  placeholder="e.g., 3000"
                  helpText="Provisioned IOPS (100-64000)"
                />
              )}

              {/* Throughput (if supported) */}
              {selectedType?.supportsThroughput && (
                <FormField
                  label="Throughput (MB/s) (optional)"
                  type="number"
                  min={125}
                  max={1000}
                  disabled={submitting}
                  value={formData.throughput ? String(formData.throughput) : ''}
                  onChange={(v) => handleChange('throughput', v ? parseInt(v) : null)}
                  placeholder="e.g., 125"
                  helpText="Throughput in MB/s (125-1000)"
                />
              )}

              {/* Encrypted */}
              <div>
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={formData.encrypted}
                    onChange={(e) => handleChange('encrypted', e.target.checked)}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
                    disabled={submitting || isEditMode}
                  />
                  <span className="text-sm text-theme-primary">Encrypt volume</span>
                </label>
                <p className="mt-1 text-xs text-theme-tertiary ml-6">
                  Enable encryption at rest for this volume
                </p>
              </div>
            </div>

            {/* Footer */}
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
                  isEditMode ? 'Update Volume' : 'Create Volume'
                )}
              </Button>
            </div>
          </form>
    </Modal>
  );
};

export default VolumeFormModal;
