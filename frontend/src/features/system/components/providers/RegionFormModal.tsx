import React, { useState, useEffect } from 'react';
import { MapPin } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderRegion } from '@system/features/system/types/system.types';

interface RegionFormModalProps {
  /** Provider ID for this region */
  providerId: string;
  /** Region to edit (null for create mode) */
  region: SystemProviderRegion | null;
  /** Whether the modal is open */
  isOpen: boolean;
  /** Callback when modal is closed */
  onClose: () => void;
  /** Callback when region is saved */
  onRegionSaved?: () => void;
}

interface FormData {
  name: string;
  description: string;
  region_code: string;
  endpoint_url: string;
}

interface FormErrors {
  name?: string;
  region_code?: string;
}

/**
 * RegionFormModal - Modal for creating/editing provider regions
 */
export const RegionFormModal: React.FC<RegionFormModalProps> = ({
  providerId,
  region,
  isOpen,
  onClose,
  onRegionSaved
}) => {
  const { addNotification } = useNotifications();
  const isEditMode = !!region;

  // State
  const [submitting, setSubmitting] = useState(false);
  const [formData, setFormData] = useState<FormData>({
    name: '',
    description: '',
    region_code: '',
    endpoint_url: ''
  });
  const [errors, setErrors] = useState<FormErrors>({});

  // Initialize form
  useEffect(() => {
    if (isOpen) {
      if (region) {
        setFormData({
          name: region.name,
          description: region.description || '',
          region_code: region.region_code || '',
          endpoint_url: region.endpoint_url || ''
        });
      } else {
        setFormData({
          name: '',
          description: '',
          region_code: '',
          endpoint_url: ''
        });
      }
      setErrors({});
    }
  }, [isOpen, region]);

  // Validate form
  const validate = (): boolean => {
    const newErrors: FormErrors = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Name must be at least 2 characters';
    }

    if (!formData.region_code.trim()) {
      newErrors.region_code = 'Region code is required';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  // Handle field change
  const handleChange = (field: keyof FormData, value: string) => {
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
      const payload = {
        name: formData.name.trim(),
        description: formData.description.trim() || undefined,
        region_code: formData.region_code.trim(),
        endpoint_url: formData.endpoint_url.trim() || undefined,
        capabilities: {}
      };

      if (isEditMode && region) {
        await systemApi.updateProviderRegion(providerId, region.id, payload);
        addNotification({
          type: 'success',
          message: `Region "${payload.name}" updated successfully`
        });
      } else {
        await systemApi.createProviderRegion(providerId, payload);
        addNotification({
          type: 'success',
          message: `Region "${payload.name}" created successfully`
        });
      }

      onRegionSaved?.();
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update region: ${errorMessage}`
          : `Failed to create region: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditMode ? 'Edit Region' : 'Add Region'}
      icon={<MapPin className="w-6 h-6" />}
      maxWidth="lg"
    >

          {/* Form */}
          <form onSubmit={handleSubmit}>
            <div className="space-y-4">
              {/* Name */}
              <FormField
                label="Name"
                required
                value={formData.name}
                onChange={(v) => handleChange('name', v)}
                placeholder="Enter region name"
                error={errors.name}
                disabled={submitting}
              />

              {/* Region Code */}
              <FormField
                label="Region Code"
                required
                value={formData.region_code}
                onChange={(v) => handleChange('region_code', v)}
                placeholder="e.g., us-east-1"
                className="font-mono"
                error={errors.region_code}
                disabled={submitting}
              />

              {/* Description */}
              <FormField
                label="Description"
                type="textarea"
                rows={2}
                value={formData.description}
                onChange={(v) => handleChange('description', v)}
                placeholder="Optional description"
                disabled={submitting}
              />

              {/* Endpoint URL */}
              <FormField
                label="Endpoint URL"
                type="url"
                value={formData.endpoint_url}
                onChange={(v) => handleChange('endpoint_url', v)}
                placeholder="https://api.region.example.com"
                className="font-mono"
                helpText="API endpoint for this region (if different from provider default)"
                disabled={submitting}
              />
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
                  isEditMode ? 'Update Region' : 'Add Region'
                )}
              </Button>
            </div>
          </form>
    </Modal>
  );
};

export default RegionFormModal;
